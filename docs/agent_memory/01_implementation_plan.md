# Slack ユーザー単位の長期記憶 実装プラン

エージェント ([agent/main.py](../../agent/main.py)) に **AgentCore Memory** を組み込み、Slack ユーザー単位で長期記憶を蓄積・参照できるようにする。

## Context

- 既存構成: Slack → API GW → Receiver Lambda → SQS → Invoker Lambda → AgentCore Runtime (Strands Agent)。Invoker は既に `actor_id = "{team}:{user}"` と `session_id`(Slack thread ベース)を payload に含めて呼び出している ([slack_bot/invoker/handler.py:212-220](../../slack_bot/invoker/handler.py#L212-L220))。
- 既存の Runtime は payload 中の `prompt` のみ読み、`actor_id` / `session_id` を **無視** している ([agent/main.py:131-144](../../agent/main.py#L131-L144))。
- 今回は **Slack ユーザー単位の長期記憶のみ**を導入し、要約・セマンティック検索・Episodic 等の他の長期戦略は **追加しない**。
- リージョンは `ap-northeast-1`(2026-05 時点で AgentCore Memory の Tokyo リージョン対応済み)。

## 設計の決定事項

### 1. 何を「長期記憶」として残すか

`USER_PREFERENCE` 戦略のみを採用する。以下の理由:
- ユーザーの好み・口調・繰り返し出てくる文脈(言語、敬称、関心領域等)を抽出することで、本質的に「ユーザーごとの長期記憶」になる。
- `SUMMARIZATION` は session 単位で意味が出るが、Slack スレッドは短い・一回性のものが多く、価値が低い。
- `SEMANTIC` (事実抽出)・`EPISODIC` (出来事ログ)は今回のスコープ外。

→ namespace は `/preferences/{actorId}/`(末尾スラッシュ必須でプレフィックス衝突防止)。`{actorId}` は `team_id:user_id` 形式なので、自動的に **Slack ワークスペース×ユーザー単位**で分離される。

### 2. STM の扱い

AgentCore Memory の仕組み上、**LTM だけを使うことはできない**:
- Strands の `AgentCoreMemorySessionManager` は会話イベントをまず STM(events)として書き込む。
- 戦略がそのイベントを **非同期で抽出**して LTM に格納する。
- イベントは `event_expiry_duration` 経過後に自動削除される。

→ `event_expiry_duration = 7`(プロバイダ最小値)を指定して STM の保持期間を最短化する。長期に残るのは LTM の `/preferences/{actorId}/` 配下のみ。

### 3. session_id の扱い

- AgentCore Memory の `session_id` は STM のイベントをグルーピングする粒度。
- LTM (USER_PREFERENCE) は `{actorId}` でしか namespace 分割しないので、session_id が変わっても **同一 actor の好みは累積される**。
- 既存の Slack Invoker が渡す `slack-{channel}-{thread_ts}` 形式 ([slack_bot/invoker/handler.py:110-113](../../slack_bot/invoker/handler.py#L110-L113)) をそのまま使う(33 文字パディング済み、`[a-zA-Z0-9_-]+` パターン適合)。

### 4. メモリリソースの所有者

- Memory リソースは **Runtime と同じ Terraform スタックで管理**する(staging / production それぞれ独立)。
- 戦略 ACTIVE 化後のイベントしか LTM 抽出されないため、初回デプロイ後の最初の数会話は LTM が空のまま動く挙動になる。

### 5. リクエスト経路の責務分担

| レイヤ | 何を渡すか | 何を変えるか |
|---|---|---|
| Slack Invoker | `actor_id`, `session_id`, `prompt`, `metadata`(変更なし) | **変更不要** |
| Agent Runtime (`agent/main.py`) | `actor_id` / `session_id` を payload から取得し `AgentCoreMemorySessionManager` に渡す | **要変更** |
| Terraform `agentcore_runtime` モジュール | `MEMORY_ID` を環境変数で渡す + Memory に対する IAM 権限を付与 | **要変更** |
| Terraform 新規 `agentcore_memory` モジュール | Memory + USER_PREFERENCE 戦略 | **新規作成** |

## Phase 1: Terraform — Memory リソース追加

### 新規モジュール `terraform/modules/agentcore_memory/`

ファイル構成:
- `main.tf`: Memory + USER_PREFERENCE 戦略
- `variables.tf`: `project_name`, `environment`, `event_expiry_days`(default 7), `tags`
- `outputs.tf`: `memory_id`, `memory_arn`, `strategy_id`

`main.tf` の主要リソース:

```hcl
resource "aws_bedrockagentcore_memory" "this" {
  name                  = "${var.project_name}_${var.environment}_user_memory"
  description           = "Per-Slack-user long-term memory for the Kasuy agent"
  event_expiry_duration = var.event_expiry_days   # default 7 (provider minimum)
  tags                  = var.tags
}

resource "aws_bedrockagentcore_memory_strategy" "user_preference" {
  name        = "user-preference"
  memory_id   = aws_bedrockagentcore_memory.this.id
  type        = "USER_PREFERENCE"
  description = "Per-actor user preference learning (actorId = Slack team:user)"
  namespaces  = ["/preferences/{actorId}/"]
}
```

**注意点**:
- 名前に `-` を含めると検証エラーになるケースが過去にあったため、リソース名側は `_` 区切り、戦略の `name` は kebab-case で OK(`name` は別バリデーション)。
- 戦略は ACTIVE まで非同期で時間がかかる。`terraform apply` 後すぐの会話は LTM 抽出が走らない可能性。
- リソース削除で **LTM データは消失**する。production では `lifecycle { prevent_destroy = true }` を検討。

### `terraform/common/main.tf` への組み込み

Runtime 側に `MEMORY_ID` を環境変数で流し込み、Memory に対する IAM 権限を追加する。

```hcl
module "agentcore_memory" {
  source = "../../modules/agentcore_memory"

  project_name = var.project_name
  environment  = var.environment

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

module "agent_runtime" {
  source = "../../modules/agentcore_runtime"
  # ...既存
  environment_variables = merge(var.agent_environment_variables, {
    GATEWAY_URL                = module.agentcore_gateway.gateway_url
    GATEWAY_CLIENT_SECRET_NAME = module.agentcore_gateway.client_secret_name
    AGENT_MEMORY_ID            = module.agentcore_memory.memory_id   # ← 追加
  })
  memory_arn = module.agentcore_memory.memory_arn                    # ← 追加(IAM 用)
  # ...
}
```

### `terraform/modules/agentcore_runtime` の変更

[terraform/modules/agentcore_runtime/main.tf:16-54](../../terraform/modules/agentcore_runtime/main.tf#L16-L54) の `runtime_permissions` ポリシーに Memory 操作権限を追加する。

新規 variable `memory_arn`(任意):

```hcl
variable "memory_arn" {
  type    = string
  default = null
}
```

ポリシー追記(memory_arn が設定されている時のみ):

```hcl
dynamic "statement" {
  for_each = var.memory_arn != null ? [1] : []
  content {
    effect = "Allow"
    actions = [
      "bedrock-agentcore:CreateEvent",
      "bedrock-agentcore:ListEvents",
      "bedrock-agentcore:GetEvent",
      "bedrock-agentcore:RetrieveMemoryRecords",
      "bedrock-agentcore:ListMemoryRecords",
      "bedrock-agentcore:GetMemoryRecord",
    ]
    resources = [
      var.memory_arn,
      "${var.memory_arn}/*",
    ]
  }
}
```

> 実際に必要な action 名は `bedrock-agentcore` のデータプレーン API 命名に依存する。`apply` 前に `aws bedrock-agentcore help` または provider docs で最終確認する(2026-05 時点では上記 6 つで Strands SDK の動作を満たすはず)。

### `terraform/common/outputs.tf` に追加

```hcl
output "agent_memory_id" {
  value = module.agentcore_memory.memory_id
}
```

## Phase 2: Agent コード変更 ([agent/main.py](../../agent/main.py))

### 依存追加

`agent/pyproject.toml` の `dependencies` を変更:

```toml
"bedrock-agentcore>=0.2.0",  # Memory 統合(strands サブモジュール)
```

(既存は `>=0.1.0`。Memory integration が含まれるバージョンに引き上げる。具体的なバージョンは `uv add bedrock-agentcore` 実行時に lockfile で決まる。)

### main.py の構造変更

**現状の構造**: モジュールロード時に `Agent(model=..., tools=..., system_prompt=...)` を 1 回構築し、`@app.entrypoint` の中で `agent.stream_async(prompt)` を呼ぶ。

**変更後**:
- model / tools / system_prompt はモジュールロード時に保持(コールドスタート最適化)。
- `@app.entrypoint` 内で **リクエストごとに** `AgentCoreMemorySessionManager` と `Agent` をビルドする。
- `with` ブロックで session_manager を扱い、確実にフラッシュ・クローズさせる。

骨子:

```python
from bedrock_agentcore.memory.integrations.strands.config import (
    AgentCoreMemoryConfig,
    RetrievalConfig,
)
from bedrock_agentcore.memory.integrations.strands.session_manager import (
    AgentCoreMemorySessionManager,
)

MEMORY_ID = os.environ.get("AGENT_MEMORY_ID")

# モジュールロード時に 1 回だけ構築する不変リソース
_model = BedrockModel(model_id="jp.anthropic.claude-sonnet-4-6", streaming=True)
_tools = _build_tools()
_system_prompt = "You are a helpful assistant. ..."

def _build_session_manager(actor_id: str, session_id: str) -> AgentCoreMemorySessionManager | None:
    if not MEMORY_ID:
        return None
    config = AgentCoreMemoryConfig(
        memory_id=MEMORY_ID,
        actor_id=actor_id,
        session_id=session_id,
        retrieval_config={
            "/preferences/{actorId}/": RetrievalConfig(top_k=5, relevance_score=0.5),
        },
    )
    return AgentCoreMemorySessionManager(config, region_name=AWS_REGION)


@app.entrypoint
async def handler(request):
    session_id = request.get("session_id", "unknown")
    actor_id = request.get("actor_id", "unknown")
    prompt = request.get("prompt", "Hello")
    logger.info("handler start session=%s actor=%s prompt_len=%d",
                session_id, actor_id, len(prompt))

    session_manager = _build_session_manager(actor_id, session_id)
    try:
        if session_manager is not None:
            with session_manager as sm:
                agent = Agent(
                    model=_model, tools=_tools,
                    system_prompt=_system_prompt,
                    session_manager=sm,
                )
                async for event in agent.stream_async(prompt):
                    yield event
        else:
            agent = Agent(
                model=_model, tools=_tools,
                system_prompt=_system_prompt,
            )
            async for event in agent.stream_async(prompt):
                yield event
    except Exception:
        logger.exception("handler failed session=%s", session_id)
        raise
```

**実装上の注意**:
- `AgentCoreMemorySessionManager` は `with` ブロック対応(`__enter__`/`__exit__`)。`batch_size` を未指定(=1)でも `with` を使うことが推奨。
- `MEMORY_ID` 未設定時は **メモリ機能を無効化して動作継続**(ローカル開発・回帰テストのため)。
- Strands は session_manager を渡すと自動的に retrieval を行うので、system_prompt 側で「過去の好みを参照せよ」等の指示を**追加する必要はない**(SDK が context に注入する)。
- ただし、明示的に「ユーザーの好みを尊重して」程度の一文を入れても害はない(任意)。

### system_prompt の微調整(任意)

```
"Use any user preferences or context retrieved from memory to personalize the response. "
"If the user states a preference (language, tone, expertise level), acknowledge it implicitly in future replies."
```

を末尾に追加するとメモリ参照効果がより明示的になる。

## Phase 3: Slack 側

**変更不要**。既に `actor_id = f"{team}:{user}"`、`session_id` ともに正しい形で渡している ([slack_bot/invoker/handler.py:212-213](../../slack_bot/invoker/handler.py#L212-L213))。

## Phase 4: ローカル動作確認

- `make agent-serve-local-staging` 起動時に `AGENT_MEMORY_ID` 環境変数が必要。Makefile に staging/production の terraform output から取得する処理を追加するか、手動で `AGENT_MEMORY_ID=$(...)` を渡せるようにする。

`Makefile` の `agent-serve-local-staging` ターゲットに追記:

```make
agent-serve-local-staging:
	$(eval GW_URL := ...)
	$(eval GW_SECRET := ...)
	$(eval MEM_ID := $(shell cd terraform/env/staging && AWS_PROFILE=apkas-staging.admin terraform output -raw agent_memory_id))
	cd agent && AWS_PROFILE=apkas-staging.admin GATEWAY_URL=$(GW_URL) GATEWAY_CLIENT_SECRET_NAME=$(GW_SECRET) AGENT_MEMORY_ID=$(MEM_ID) uv run main.py
```

production 側も同様。`agent-serve-local`(LocalProfile = staging admin、Memory なし)は `AGENT_MEMORY_ID` を **設定しないまま** にして、メモリ無効モードを維持する選択肢もある。

## 検証手順

1. `make plan-staging` → 新規 `aws_bedrockagentcore_memory` / `aws_bedrockagentcore_memory_strategy` / IAM 追記分が見える。
2. `make apply-staging` → Memory が ACTIVE になるまで CloudWatch / コンソールで待つ(数分)。
3. `make agent-deploy-staging` → 新しいイメージで Runtime を更新(`AGENT_MEMORY_ID` 環境変数が伝わっていることを Runtime 環境変数表示で確認)。
4. **会話 1 回目**(Slack スレッド A): 「私は Python が好き。日本語で答えて」→ 通常応答。LTM 抽出は非同期で数秒〜数十秒後に走る。
5. **会話 2 回目**(別スレッド B、同一ユーザー): 「何でもいいから何か書いて」→ 1 回目で抽出された「Python 好き」「日本語で」が LTM から拾われ、応答に反映されるはず。
6. **別ユーザー**で同じ質問を投げる → 上記 LTM が混ざらないことを確認(actor_id 分離が効いている)。
7. CloudWatch Logs (`/aws/vendedlogs/bedrock-agentcore/runtime/...`) と Memory のイベントログを確認:
   - イベントが書き込まれているか
   - 戦略 ACTIVE 状態か
   - 抽出されたレコードが `/preferences/{actorId}/` 配下に作られているか(`aws bedrock-agentcore list-memory-records` で確認)

## 既知の制約 / 将来検討

- **戦略 ACTIVE 前のイベントは LTM 化されない**。初回デプロイ直後の最初の数会話は LTM の効きが弱い。
- **ユーザーが「忘れて」と言っても自動消去されない**。`/forget` 系のスラッシュコマンドや、Memory レコード手動削除の運用設計は今回スコープ外。
- **`event_expiry_duration = 7` 日**で STM は揮発する。同一スレッドで 1 週間以上空いてから返信が来た場合、STM の文脈は失われる(ただし LTM の好みは残る)。
- **コスト**: USER_PREFERENCE 戦略は抽出時に Bedrock モデルを呼ぶ。会話頻度に比例して Bedrock 課金が発生。
- **将来拡張案**: SUMMARIZATION 戦略を後付けでスレッド要約を残す / SEMANTIC で事実カードを残す / `/forget` 機能 / per-channel メモリ分離。

## 主な変更ファイル(コードはまだ書かない)

新規:
- `terraform/modules/agentcore_memory/main.tf`
- `terraform/modules/agentcore_memory/variables.tf`
- `terraform/modules/agentcore_memory/outputs.tf`

変更:
- `terraform/common/main.tf` — `module "agentcore_memory"` 追加・`agent_runtime` に env / memory_arn 渡し
- `terraform/common/outputs.tf` — `agent_memory_id` 追加
- `terraform/modules/agentcore_runtime/main.tf` — Memory 用 IAM 文を `dynamic` で追加
- `terraform/modules/agentcore_runtime/variables.tf` — `memory_arn` variable 追加
- `agent/main.py` — リクエスト毎に session_manager + Agent を構築する形に変更
- `agent/pyproject.toml` — `bedrock-agentcore` バージョン引き上げ(必要なら)
- `Makefile` — `agent-serve-local-{staging,production}` に `AGENT_MEMORY_ID` 注入
