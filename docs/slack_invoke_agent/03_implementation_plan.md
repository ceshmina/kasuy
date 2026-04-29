# Slack → AgentCore Runtime 連携 実装プラン

`01_slack_app_setup.md` (Slack 側手順) と `02_aws_implementation_plan.md` (AWS 側設計指針) を本リポジトリの既存構成に合わせて具体化した実装プラン。

## Context

`docs/slack_invoke_agent/` に記載された設計に基づき、Slack から既存の AgentCore Runtime ([agent/main.py](../../agent/main.py)) を呼び出す統合層を AWS に構築する。エージェント本体は既に存在するため、本作業は **Slack 統合層 (API Gateway + Lambda + SQS + Secrets Manager)** の実装に絞る。

既存コードベースとの差分:
- フォルダ構成は docs の `infra/terraform` ではなく既存の `terraform/{common,modules,env}` 構造に準拠する
- AgentCore **Memory は未導入のまま進める**(`runtimeSessionId = thread_ts` のみで Slack スレッド単位のセッション継続を実現)。Lambda → Runtime の payload には将来の Memory 導入に備えて `actor_id` / `session_id` を含めるが、`agent/main.py` 側は当面 `prompt` のみ読む(変更なし)
- 既存 AgentCore Runtime はストリーミング SSE 出力 ([agent/invoke.py:57](../../agent/invoke.py#L57) 参照)。Invoker Lambda はこれを集約して 1 メッセージで `chat.update` する(MVP)

## 決定事項

- **環境**: staging を先行(production は後日同じ手順で別 App として作る)
- **Bot 表示名**: `kasuy`(Slack App `display_information.name` と `bot_user.display_name`)
- **Secrets 投入**: ユーザーが `aws secretsmanager put-secret-value` で直接実行(Terraform は空 Secret を作るだけ)
- **AgentCore Memory**: 今回は導入しない

## Phase 0: Slack 側の手動設定(ユーザー作業 — 並行で進められる)

### 手順(staging 用)

1. **Manifest JSON 作成**(Request URL はダミー `https://example.com/slack/events` で OK。後で書き換える)
   - スコープ: `app_mentions:read`, `chat:write`, `chat:write.public`, `channels:history`, `groups:history`, `im:history`, `mpim:history`, `users:read`, `files:write`, `reactions:write`
   - bot_events: `app_mention`, `message.channels`, `message.groups`, `message.im`, `message.mpim`
2. https://api.slack.com/apps → **Create New App** → **From a manifest** → ワークスペース選択 → 貼り付け → Create
3. **認証情報3点取得**:
   - Signing Secret: Basic Information → App Credentials
   - Bot User OAuth Token (`xoxb-...`): OAuth & Permissions → Install to Workspace
   - Bot User ID (`U...`): Slack 上で Bot プロフィール → Copy member ID
4. **(AWS デプロイ後)** Event Subscriptions → Enable → Request URL に Terraform 出力の URL を入力 → Verified ✓ → Save
5. チャネルに `/invite @kasuy`

## Phase 1: AWS 側の Terraform / Lambda 実装

### ディレクトリ構成(既存に追従)

```
terraform/
  modules/
    slack_integration/        # ← 新規。Slack 統合一式を1モジュールに
      main.tf                 #   secret/dynamo/sqs/apigw/lambdas/iam を内包
      variables.tf            #   agent_runtime_arn, agent_qualifier, env, project, slack_bot_dir, slack_invoker_dir
      outputs.tf              #   slack_request_url, slack_secret_name
  env/staging/main.tf         # ← 既存に module "slack_integration" を追加
  env/staging/outputs.tf      # ← slack_request_url を再エクスポート
  env/staging/terraform.tfvars  # 必要なら slack 関連の上書きを追加(基本不要)

slack_bot/                    # ← 新規。agent/ と並ぶ Lambda コード置き場
  receiver/
    handler.py                # 署名検証 → 重複排除 → "処理中…"投稿 → SQS enqueue
    requirements.txt          # boto3 は Lambda 同梱なので空でも可。標準ライブラリのみで実装する
  invoker/
    handler.py                # SQS 受信 → InvokeAgentRuntime → SSE 集約 → chat.update
    requirements.txt
```

### Terraform モジュール `slack_integration` の中身

すべて 1 モジュールに集約(Slack 統合は staging/production で同型に展開する単位なので、env 側からは 1 module 呼び出しで済む形にする)。

主要リソース:
- `aws_secretsmanager_secret.slack` + `aws_secretsmanager_secret_version` (placeholder, `lifecycle.ignore_changes = [secret_string]`)
- `aws_dynamodb_table.dedup` (PAY_PER_REQUEST, hash_key=`event_id`, TTL on `ttl`)
- `aws_sqs_queue.agent_jobs` (FIFO, visibility_timeout=960) + `agent_jobs_dlq` (FIFO, redrive maxReceiveCount=2)
- `aws_apigatewayv2_api` (HTTP) + `apigatewayv2_integration` + `apigatewayv2_route POST /slack/events` + `apigatewayv2_stage $default` + `aws_lambda_permission`
- `data.archive_file.receiver` / `data.archive_file.invoker` で `slack_bot/{receiver,invoker}/` を zip
- `aws_lambda_function.receiver` (timeout=5, memory=512, runtime=python3.12)
- `aws_lambda_function.invoker` (timeout=900, memory=1024, runtime=python3.12)
- `aws_lambda_event_source_mapping` (SQS → invoker, batch_size=1, ReportBatchItemFailures)
- IAM: receiver/invoker 用に別ロール、最小権限。Invoker は `bedrock-agentcore:InvokeAgentRuntime` を当該 ARN に限定

env 側の変更([terraform/env/staging/main.tf](../../terraform/env/staging/main.tf)):
```hcl
module "slack_integration" {
  source = "../../modules/slack_integration"

  project_name        = var.project_name
  environment         = var.environment
  agent_runtime_arn   = module.agent_runtime.agent_runtime_arn
  agent_qualifier     = module.agent_runtime.endpoint_name
  receiver_source_dir = "${path.module}/../../../slack_bot/receiver"
  invoker_source_dir  = "${path.module}/../../../slack_bot/invoker"

  tags = { Project = var.project_name, Environment = var.environment }
}
```

[terraform/env/staging/outputs.tf](../../terraform/env/staging/outputs.tf) に追加:
```hcl
output "slack_request_url"  { value = module.slack_integration.slack_request_url }
output "slack_secret_name"  { value = module.slack_integration.slack_secret_name }
```

### Receiver Lambda (`slack_bot/receiver/handler.py`) 実装方針

実行順序(失敗時も常に 200 を返す方針 — Slack のリトライ嵐を防ぐ):
1. **署名検証** (`v0=` HMAC-SHA256, タイムスタンプ ±5分以内) → 失敗は 401
2. **`url_verification` チャレンジ**: `payload.type == "url_verification"` なら `challenge` を返す
3. **重複排除**: DynamoDB `PutItem` with `ConditionExpression="attribute_not_exists(event_id)"`、TTL=now+3600。既存なら 200 で終了
4. **Bot 自身の発言を除外**: `event.bot_id` 存在 or `event.user == BOT_USER_ID` なら 200 で終了
5. **`thread_ts` 決定**: メンションは `thread_ts || ts`、`message` イベントは `thread_ts` 必須かつテキストに `<@BOT_USER_ID>` を含むケースのみ通す(MVP の簡易フィルタ)
6. **"処理中…" 投稿**: `chat.postMessage` で thread に placeholder 投稿し、戻り値の `ts` を保存
7. **SQS enqueue**: `MessageGroupId = "{channel}#{thread_ts}"`, `MessageDeduplicationId = event_id`
8. 200 を返す

実装ポイント:
- **3秒制約**: Secrets Manager 値・boto3 クライアントはグローバルスコープで初期化(コールドスタート以降キャッシュ)
- 標準ライブラリのみで Slack API 呼び出し(`urllib.request`)。Lambda の依存パッケージ追加を避ける

### Invoker Lambda (`slack_bot/invoker/handler.py`) 実装方針

1. SQS メッセージから `channel`, `thread_ts`, `user`, `team`, `text`, `placeholder_ts` を取り出す
2. `bedrock-agentcore.invoke_agent_runtime` を呼ぶ:
   - `agentRuntimeArn = AGENT_RUNTIME_ARN` (env)
   - `qualifier = AGENT_QUALIFIER` (env、`endpoint_name` を渡す)
   - `runtimeSessionId = thread_ts`
   - `payload = {"prompt": text, "actor_id": f"{team}:{user}", "session_id": thread_ts, "metadata": {"channel_id": channel, "slack_user_id": user, "team_id": team}}`
3. **SSE ストリーム集約**: `response["response"]` を `iter_lines()` で読み、[agent/invoke.py:49-58](../../agent/invoke.py#L49-L58) と同じく `data: {...}` 行から `event.contentBlockDelta.delta.text` を抜いて連結
4. `chat.update(channel, ts=placeholder_ts, text=full_text)` で書き戻し
5. **長文分割**: 連結結果が ~3500 文字を超えたら、最初の塊を `chat.update`、残りを `chat.postMessage` で thread に追加投稿
6. **エラー時**: SQS 再処理を活かしたい場合は `batchItemFailures` を返す。タイムアウト/不可逆エラーは Slack に「エラーが発生しました」を出して諦める
7. Slack rate limit (`429` + `Retry-After`) を受けたら指定秒数待機して再送

実装ポイント:
- Secrets Manager ・ boto3 クライアントはグローバル初期化
- SSE 行のうち JSON parse 不能なものや `delta.text` が無いイベント (e.g. tool 呼び出し) は無視
- urllib で Slack API を叩く(slack_sdk は使わない)

## Phase 2: Slack 側 URL 有効化(ユーザー作業)

1. `make apply-staging` 完了後、`terraform output -raw slack_request_url` を確認
2. `aws secretsmanager put-secret-value --secret-id <slack_secret_name> --secret-string '{"bot_token":"xoxb-...","signing_secret":"...","bot_user_id":"U..."}' --region ap-northeast-1 --profile apkas-staging.admin`
3. Slack App → Event Subscriptions → Enable → Request URL に貼って Verified ✓
4. チャネルに `/invite @kasuy`

## 検証手順

1. **Terraform**: `make plan-staging` で差分が想定通り → `make apply-staging`
2. **URL Verification**: Receiver Lambda の CloudWatch Logs に `url_verification` 受信が出る
3. **メンション応答**: チャネルで `@kasuy こんにちは` → 数秒後に応答が出る
4. **スレッド継続**: Bot 応答に対して同スレッドで返信 → 文脈を踏まえた応答が出る (= `runtimeSessionId` が機能)
5. **重複排除**: 同じイベントを2回送らせる(Slack の自動リトライ動作 or 手動再送) → 応答は1回
6. **Bot 自己発言の無視**: Bot の発言を契機に message イベントが来てもループしない
7. **CloudWatch Metrics**:
   - Receiver Duration P99 < 2.5s
   - SQS DLQ メッセージ数 = 0
   - Invoker Errors = 0(正常時)

## 主な変更ファイル

新規:
- `terraform/modules/slack_integration/main.tf`
- `terraform/modules/slack_integration/variables.tf`
- `terraform/modules/slack_integration/outputs.tf`
- `slack_bot/receiver/handler.py`
- `slack_bot/invoker/handler.py`

変更:
- `terraform/env/staging/main.tf` — `module "slack_integration"` 追加
- `terraform/env/staging/outputs.tf` — `slack_request_url`, `slack_secret_name` 追加

production 展開は本プランの完了後、`terraform/env/production/` 側で同様に追加する(別 Slack App での運用)。

## 既知の制約(MVP として許容)

- ストリーミング応答なし(完了後 1 回投稿)。長応答時の体感は処理中メッセージ + 完了置換でカバー
- 添付ファイル(画像 / PDF)受信なし
- Block Kit インタラクション無効化済み
- マルチワークスペース未対応(単一 Slack ワークスペース前提)
- AgentCore Memory 未導入(payload には actor_id/session_id を含めるので、後日 agent 側を改修すれば差し込める)
