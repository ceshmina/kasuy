# AWS 側実装方針書 (Claude Code 向け)

## このドキュメントについて

Slack ↔ AgentCore Runtime 連携の **AWS 側リソース** を Claude Code に実装してもらうための設計指針。

- **エージェント本体 (AgentCore Runtime のコンテナ) は既存** という前提
- 本ドキュメントは **Slack 統合層** (API Gateway + Lambda 群 + SQS + Secrets Manager) に集中
- IaC は **Terraform** を使用
- ランタイムは **Python 3.12** (Lambda)
- リージョンは特に指定がなければ `ap-northeast-1`

Slack App 側の構築手順は `01_slack_app_setup.md` を参照。

---

## アーキテクチャ概要

```
Slack ──[Webhook]──▶ API Gateway (HTTP API)
                         │
                         ▼
                    Receiver Lambda  ──[即時 200]──▶ Slack
                    │                              ("処理中…" 投稿も同期実行)
                    │ enqueue
                    ▼
                    SQS FIFO Queue (MessageGroupId = channel#thread)
                         │
                         ▼
                    Invoker Lambda
                         │ InvokeAgentRuntime
                         ▼
                  AgentCore Runtime (既存)
                         │ レスポンス
                         ▼
                    Invoker Lambda ──▶ chat.update / chat.postMessage ──▶ Slack
```

### 役割分担

| コンポーネント | 役割 | 制約 |
|---|---|---|
| API Gateway (HTTP API) | Slack Webhook の受け口 | URL は固定 (Slack 側に登録) |
| Receiver Lambda | 署名検証・重複排除・即時 200・"処理中…" 投稿・SQS enqueue | **3秒以内に応答必須** |
| SQS FIFO | スレッド単位の順序保証・流量平滑化 | MessageGroupId 設計が肝 |
| Invoker Lambda | AgentCore Runtime 呼び出し・結果を Slack に書き戻し | 実行時間長め (15分まで) |
| Secrets Manager | Slack 認証情報 | Bot Token / Signing Secret |
| DynamoDB (重複排除) | `event_id` の TTL 付き記録 | TTL 1時間 |

---

## ディレクトリ構成 (推奨)

```
infra/
├── terraform/
│   ├── main.tf              # provider, backend
│   ├── variables.tf
│   ├── outputs.tf           # API Gateway URL を出力 (Slack 設定で使う)
│   ├── api_gateway.tf
│   ├── receiver_lambda.tf
│   ├── invoker_lambda.tf
│   ├── sqs.tf
│   ├── dynamodb.tf
│   ├── secrets.tf
│   ├── iam.tf
│   └── env/
│       ├── dev.tfvars
│       └── prod.tfvars
├── lambda/
│   ├── receiver/
│   │   ├── handler.py
│   │   ├── slack_verify.py
│   │   ├── dedup.py
│   │   └── requirements.txt
│   └── invoker/
│       ├── handler.py
│       ├── agentcore_client.py
│       ├── slack_client.py
│       └── requirements.txt
└── docs/
    ├── 01_slack_app_setup.md
    └── 02_aws_implementation_plan.md (this)
```

---

## Terraform 詳細設計

### `variables.tf`

```hcl
variable "env"             { type = string }                         # "dev" | "prod"
variable "region"          { type = string  default = "ap-northeast-1" }
variable "project"         { type = string  default = "agentcore-slack" }

variable "agentcore_runtime_arn" {
  type        = string
  description = "既存 AgentCore Runtime の ARN"
}

variable "agentcore_memory_id" {
  type        = string
  description = "既存 AgentCore Memory の ID (Invoker から actor_id/session_id を渡す先)"
}

variable "slack_secret_name" {
  type    = string
  default = null   # null の場合 "/${project}/${env}/slack" になる
}
```

### `secrets.tf`

```hcl
resource "aws_secretsmanager_secret" "slack" {
  name        = coalesce(var.slack_secret_name, "/${var.project}/${var.env}/slack")
  description = "Slack bot_token, signing_secret, bot_user_id"
}

# 値は手動投入する運用 (01_slack_app_setup.md 参照)
# 値の変更を Terraform に追跡させない
resource "aws_secretsmanager_secret_version" "slack_placeholder" {
  secret_id     = aws_secretsmanager_secret.slack.id
  secret_string = jsonencode({
    bot_token      = "PLACEHOLDER"
    signing_secret = "PLACEHOLDER"
    bot_user_id    = "PLACEHOLDER"
  })
  lifecycle {
    ignore_changes = [secret_string]
  }
}
```

### `dynamodb.tf` (重複排除テーブル)

```hcl
resource "aws_dynamodb_table" "dedup" {
  name         = "${var.project}-${var.env}-dedup"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}
```

### `sqs.tf` (FIFO キュー)

```hcl
resource "aws_sqs_queue" "agent_jobs_dlq" {
  name                       = "${var.project}-${var.env}-jobs-dlq.fifo"
  fifo_queue                 = true
  message_retention_seconds  = 1209600   # 14 days
}

resource "aws_sqs_queue" "agent_jobs" {
  name                        = "${var.project}-${var.env}-jobs.fifo"
  fifo_queue                  = true
  content_based_deduplication = false   # 自前で MessageDeduplicationId を渡す
  visibility_timeout_seconds  = 960     # Invoker Lambda タイムアウトの 6倍 (再処理を確実に避ける)
  message_retention_seconds   = 14400   # 4 hours

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.agent_jobs_dlq.arn
    maxReceiveCount     = 2
  })
}
```

**FIFO の設計意図**:
- `MessageGroupId = "{channel_id}#{thread_ts}"` にする → 同じスレッドは順序保証、別スレッドは並列
- `MessageDeduplicationId = event_id` にする → SQS レベルの重複排除も二重に効かせる
- visibility_timeout は Lambda のタイムアウト × 6 倍 (AWS推奨の最低3倍より余裕を持つ)

### `api_gateway.tf` (HTTP API)

REST API ではなく HTTP API を使う (安価・低レイテンシ)。

```hcl
resource "aws_apigatewayv2_api" "slack" {
  name          = "${var.project}-${var.env}-slack"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "receiver" {
  api_id                 = aws_apigatewayv2_api.slack.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.receiver.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "slack_events" {
  api_id    = aws_apigatewayv2_api.slack.id
  route_key = "POST /slack/events"
  target    = "integrations/${aws_apigatewayv2_integration.receiver.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.slack.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 50
    throttling_rate_limit  = 20
  }
}

resource "aws_lambda_permission" "apigw_invoke_receiver" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.receiver.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.slack.execution_arn}/*/*"
}
```

`outputs.tf` で URL を出す:

```hcl
output "slack_request_url" {
  value = "${aws_apigatewayv2_api.slack.api_endpoint}/slack/events"
  description = "Slack App の Event Subscriptions Request URL に登録する"
}
```

### `receiver_lambda.tf`

```hcl
data "archive_file" "receiver" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/receiver"
  output_path = "${path.module}/build/receiver.zip"
}

resource "aws_lambda_function" "receiver" {
  function_name    = "${var.project}-${var.env}-receiver"
  role             = aws_iam_role.receiver.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.receiver.output_path
  source_code_hash = data.archive_file.receiver.output_base64sha256
  timeout          = 5            # 3秒以内応答必須なので 5秒で足切り
  memory_size      = 512

  environment {
    variables = {
      SLACK_SECRET_NAME = aws_secretsmanager_secret.slack.name
      DEDUP_TABLE       = aws_dynamodb_table.dedup.name
      JOB_QUEUE_URL     = aws_sqs_queue.agent_jobs.url
      LOG_LEVEL         = "INFO"
    }
  }
}
```

### `invoker_lambda.tf`

```hcl
data "archive_file" "invoker" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/invoker"
  output_path = "${path.module}/build/invoker.zip"
}

resource "aws_lambda_function" "invoker" {
  function_name    = "${var.project}-${var.env}-invoker"
  role             = aws_iam_role.invoker.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.invoker.output_path
  source_code_hash = data.archive_file.invoker.output_base64sha256
  timeout          = 900          # 最大15分。AgentCore はそれ以上かかる場合あるが、長すぎる時は Invoker 側で諦める
  memory_size      = 1024

  environment {
    variables = {
      SLACK_SECRET_NAME      = aws_secretsmanager_secret.slack.name
      AGENTCORE_RUNTIME_ARN  = var.agentcore_runtime_arn
      AGENTCORE_MEMORY_ID    = var.agentcore_memory_id
      LOG_LEVEL              = "INFO"
    }
  }
}

resource "aws_lambda_event_source_mapping" "invoker_sqs" {
  event_source_arn                   = aws_sqs_queue.agent_jobs.arn
  function_name                      = aws_lambda_function.invoker.arn
  batch_size                         = 1     # FIFO + 1件ずつ処理 (順序保証を素直に守る)
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]
}
```

### `iam.tf`

最小権限の例 (抜粋):

```hcl
# Receiver Lambda のロール
resource "aws_iam_role" "receiver" {
  name = "${var.project}-${var.env}-receiver"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "receiver" {
  role = aws_iam_role.receiver.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "logs:*", Resource = "*" },
      { Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = aws_secretsmanager_secret.slack.arn },
      { Effect = "Allow", Action = ["dynamodb:PutItem"], Resource = aws_dynamodb_table.dedup.arn },
      { Effect = "Allow", Action = "sqs:SendMessage", Resource = aws_sqs_queue.agent_jobs.arn },
    ]
  })
}

# Invoker Lambda のロール
resource "aws_iam_role_policy" "invoker" {
  role = aws_iam_role.invoker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "logs:*", Resource = "*" },
      { Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = aws_secretsmanager_secret.slack.arn },
      { Effect = "Allow",
        Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"],
        Resource = aws_sqs_queue.agent_jobs.arn },
      { Effect = "Allow",
        Action = ["bedrock-agentcore:InvokeAgentRuntime"],
        Resource = var.agentcore_runtime_arn },
    ]
  })
}
```

**重要**: Invoker Lambda は AgentCore 呼び出し以外の権限を持たせない (情報漏洩リスクの隔離)。

---

## Lambda 実装方針

### Receiver Lambda (`lambda/receiver/handler.py`)

#### 責務 (この順序で必ず実行)

1. **署名検証** (失敗したら 401)
2. **`url_verification` チャレンジへの応答** (`type == "url_verification"` なら `challenge` を返す)
3. **重複排除** (`event_id` を DynamoDB に PutItem with ConditionExpression、既存なら何もせず 200)
4. **Bot 自身の発言は無視** (`event.bot_id` が存在 / `event.user == bot_user_id`)
5. **`event.thread_ts` の決定**
   - メンション (`app_mention`): `thread_ts` があればそれ、なければ `ts` を使う (新スレッドの起点)
   - リプライ (`message`): `thread_ts` があるもののみ処理 (= ボットがいるスレッドの可能性があるもの)
6. **"処理中…" メッセージを Slack に投稿** (`chat.postMessage`、戻り値の `ts` を保存)
7. **SQS に enqueue** (Slack イベントの payload + 処理中メッセージの ts を含めて)
8. **200 を返す**

#### 実装上の注意

- **3秒制約**: Secrets Manager 呼び出しは Lambda 初期化時 (グローバルスコープ) に1回だけ。HTTP リクエストはコネクション再利用のため `boto3` クライアントもグローバル。
- **Slack 署名**: `v0=` prefix の HMAC-SHA256。タイムスタンプは 5分以内のものだけ受理。

  ```python
  import hmac, hashlib, time

  def verify(signing_secret: str, headers: dict, body: bytes) -> bool:
      ts = headers.get("x-slack-request-timestamp", "")
      sig = headers.get("x-slack-signature", "")
      if abs(time.time() - int(ts)) > 60 * 5:
          return False
      basestring = f"v0:{ts}:".encode() + body
      mine = "v0=" + hmac.new(signing_secret.encode(), basestring, hashlib.sha256).hexdigest()
      return hmac.compare_digest(mine, sig)
  ```

- **重複排除** (DynamoDB):

  ```python
  table.put_item(
      Item={"event_id": event_id, "ttl": int(time.time()) + 3600},
      ConditionExpression="attribute_not_exists(event_id)"
  )
  # ConditionalCheckFailedException → 重複なので 200 返して終了
  ```

- **メンション以外のメッセージのフィルタ**:
  - Slack のチャンネルに Bot がいる場合、すべての発言で `message` イベントが飛んでくる
  - 「Bot がいるスレッド内のリプライ」だけに反応させたい場合、`event.thread_ts` の有無 + そのスレッドの初発言に Bot 自身が登場しているかをキャッシュする (DynamoDB に `thread_ts → bot_involved` を持つ) のが堅牢
  - シンプルに「`thread_ts` がある & `text` に Bot のメンションが含まれる場合のみ」でもよい (ユーザーに毎回メンションさせる)

- **SQS 送信時のパラメータ**:

  ```python
  sqs.send_message(
      QueueUrl=JOB_QUEUE_URL,
      MessageBody=json.dumps({
          "channel": event["channel"],
          "thread_ts": thread_ts,
          "user": event["user"],
          "team": event.get("team"),
          "text": event["text"],
          "placeholder_ts": placeholder_ts,  # "処理中…"投稿の ts
          "event_ts": event["event_ts"],
      }),
      MessageGroupId=f'{event["channel"]}#{thread_ts}',
      MessageDeduplicationId=event_id,
  )
  ```

#### Receiver の擬似コード

```python
def lambda_handler(event, context):
    body = event["body"]  # API Gateway HTTP API は文字列
    headers = {k.lower(): v for k, v in event["headers"].items()}

    # 1. 署名検証
    if not verify(SIGNING_SECRET, headers, body.encode()):
        return {"statusCode": 401, "body": "invalid signature"}

    payload = json.loads(body)

    # 2. URL verification challenge
    if payload.get("type") == "url_verification":
        return {"statusCode": 200, "body": payload["challenge"]}

    # 3. event_id 重複排除
    event_id = payload.get("event_id")
    if not put_dedup(event_id):
        return {"statusCode": 200, "body": ""}

    inner = payload.get("event", {})

    # 4. Bot 自身の発言は無視
    if inner.get("bot_id") or inner.get("user") == BOT_USER_ID:
        return {"statusCode": 200, "body": ""}

    # 5. thread_ts 決定
    thread_ts = inner.get("thread_ts") or inner.get("ts")

    # 5b. リプライの場合、メンションが含まれるかでフィルタ (簡易版)
    if inner["type"] == "message" and f"<@{BOT_USER_ID}>" not in inner.get("text", ""):
        # ※ より堅牢には「このスレッドに過去 Bot が参加したか」で判定
        return {"statusCode": 200, "body": ""}

    # 6. "処理中..." 投稿
    placeholder_ts = post_placeholder(inner["channel"], thread_ts)

    # 7. SQS enqueue
    enqueue_job(inner, thread_ts, placeholder_ts, event_id)

    # 8. 200
    return {"statusCode": 200, "body": ""}
```

---

### Invoker Lambda (`lambda/invoker/handler.py`)

#### 責務

1. SQS メッセージを1件取り出す
2. **AgentCore Runtime を呼び出す** (`bedrock-agentcore` の `InvokeAgentRuntime`)
   - `session_id = thread_ts` (Slack のスレッドタイムスタンプ)
   - `actor_id = team_id + ":" + user_id` (将来のマルチワークスペース対応も見据えて)
   - 入力 payload に `text`, `channel_id`, `slack_user_id` などを含める
3. レスポンス (テキスト) を Slack の "処理中…" メッセージに `chat.update` で書き戻す
   - レスポンスが長い (3000文字超) 場合は分割して `chat.postMessage` で追加投稿
4. 失敗時は SQS にメッセージを残さず (= 諦めて) Slack に「エラーが発生しました」メッセージを投稿
   - リトライしたい場合は `function_response_types = ["ReportBatchItemFailures"]` で `batchItemFailures` を返す

#### `InvokeAgentRuntime` の呼び出し

```python
import boto3, json, os

agentcore = boto3.client("bedrock-agentcore", region_name=os.environ["AWS_REGION"])

response = agentcore.invoke_agent_runtime(
    agentRuntimeArn=AGENTCORE_RUNTIME_ARN,
    runtimeSessionId=thread_ts,                     # ← Slack thread_ts をそのまま使う
    payload=json.dumps({
        "prompt": text,
        "actor_id": f"{team_id}:{user_id}",
        "session_id": thread_ts,
        "metadata": {
            "channel_id": channel,
            "slack_user_id": user_id,
        },
    }).encode(),
    qualifier="DEFAULT",
)

# response["response"] は StreamingBody (バイナリ)
result = json.loads(response["response"].read())
answer_text = result["text"]   # ← AgentCore 側のレスポンス契約に依存
```

**`runtimeSessionId` と `payload` 内 `session_id` の関係**:
- `runtimeSessionId` は AgentCore Runtime のセッション (= コンテナの状態保持) のキー
- `payload` 内 `actor_id`/`session_id` は **AgentCore Memory** のスコープに使われる
- どちらにも **`thread_ts`** を渡しておくと、Slack スレッド = Runtime セッション = Memory セッション が綺麗に揃う

`actor_id` 側は **Slack User ID** を使う:
- `team_id` 込みで `T123:U456` の形にしておくと、複数ワークスペース展開時にも衝突しない
- AgentCore Memory の長期記憶はこの `actor_id` 単位で蓄積される (= ユーザーごとの好み・履歴)

#### Slack への書き戻し

```python
import urllib.request, urllib.parse

def slack_update(channel: str, ts: str, text: str, bot_token: str):
    req = urllib.request.Request(
        "https://slack.com/api/chat.update",
        data=json.dumps({
            "channel": channel,
            "ts": ts,
            "text": text,
        }).encode(),
        headers={
            "Authorization": f"Bearer {bot_token}",
            "Content-Type": "application/json; charset=utf-8",
        },
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())
```

長文分割 (Slack は1メッセージ約 4000 文字制限):

```python
def post_long(channel, thread_ts, placeholder_ts, full_text, bot_token):
    chunks = split_chunks(full_text, max_len=3500)
    # 最初は placeholder を update
    slack_update(channel, placeholder_ts, chunks[0], bot_token)
    # 残りは新規投稿
    for chunk in chunks[1:]:
        slack_post(channel, thread_ts, chunk, bot_token)
```

#### エラーハンドリング

| 状況 | 対応 |
|---|---|
| AgentCore がタイムアウト | "処理中…" を「タイムアウトしました。もう一度お試しください」に書き換え |
| AgentCore が 500 系で失敗 | エラーメッセージに置換 + CloudWatch にスタックトレース |
| Slack API が rate limit | `Retry-After` ヘッダに従って待機・再送 |
| Bot Token 失効 | Secrets Manager 再取得 → それでもダメなら CloudWatch アラーム |

---

## AgentCore Runtime 側との契約 (Invoker からの呼び出し仕様)

既存の AgentCore Runtime に対して、Invoker は以下の payload で呼ぶ。**この契約を Runtime 側のコードと擦り合わせる**こと。

### リクエスト payload

```json
{
  "prompt": "ユーザーが入力したテキスト",
  "actor_id": "T01ABCD:U02XYZ",
  "session_id": "1714378934.123456",
  "metadata": {
    "channel_id": "C03ABCD",
    "slack_user_id": "U02XYZ",
    "team_id": "T01ABCD"
  }
}
```

### レスポンス契約 (Runtime → Invoker)

```json
{
  "text": "エージェントの最終応答テキスト (Markdown)",
  "blocks": [...],          // optional: Slack Block Kit を返したい場合
  "files": [...]            // optional: 添付ファイルを返したい場合 (URL or base64)
}
```

### Runtime 側で必要な実装 (既存コードで対応する点)

- **入力 payload から `actor_id`, `session_id` を読み取る**
- それを **`AgentCoreMemorySessionManager`** に渡す (Strands Agents 使用時):

  ```python
  from bedrock_agentcore.memory.integrations.strands.session_manager import AgentCoreMemorySessionManager

  config = AgentCoreMemoryConfig(
      memory_id=os.environ["AGENTCORE_MEMORY_ID"],
      actor_id=payload["actor_id"],
      session_id=payload["session_id"],
  )
  with AgentCoreMemorySessionManager(config, region_name="ap-northeast-1") as session_manager:
      agent = Agent(session_manager=session_manager, ...)
      response = agent(payload["prompt"])
  ```

- レスポンスは上記契約 (`{"text": ...}`) に合わせて整形する

---

## 構築・デプロイ手順

### 初回

```bash
# 1. Terraform で AWS 側を構築
cd infra/terraform
terraform init
terraform apply -var-file=env/dev.tfvars

# 2. 出力された slack_request_url を控える
terraform output slack_request_url

# 3. Slack App を作成 (01_slack_app_setup.md 参照)
#    Manifest の <<API_GATEWAY_ENDPOINT>> に上記 URL を入れる

# 4. Bot Token / Signing Secret / Bot User ID を取得し Secrets Manager に投入
aws secretsmanager put-secret-value \
  --secret-id "/agentcore-slack/dev/slack" \
  --secret-string '{"bot_token":"xoxb-...","signing_secret":"...","bot_user_id":"U..."}' \
  --region ap-northeast-1

# 5. Slack App の Event Subscriptions で Request URL を有効化 (URL verification が通る)

# 6. チャネルに Bot を招待 → /invite @bot
```

### Lambda コード更新時

```bash
# zip は Terraform の archive_file で自動生成されるので apply するだけ
terraform apply -var-file=env/dev.tfvars
```

---

## 観測・運用

### CloudWatch Logs

- `/aws/lambda/agentcore-slack-{env}-receiver`
- `/aws/lambda/agentcore-slack-{env}-invoker`
- AgentCore Runtime 側 (既存): `/aws/vendedlogs/bedrock-agentcore/runtime/...`

### CloudWatch Metrics で監視するポイント

| メトリクス | 意味 | アラート閾値の目安 |
|---|---|---|
| Receiver の `Errors` | 署名検証失敗・DDB 障害など | 5分で 5件以上 |
| Receiver の `Duration` (P99) | 3秒以内応答できているか | > 2500ms で警告 |
| SQS `ApproximateAgeOfOldestMessage` | 処理が滞っていないか | > 60秒 で警告 |
| SQS DLQ の `ApproximateNumberOfMessagesVisible` | 処理失敗の累積 | >= 1 で通知 |
| Invoker の `Duration` (P99) | AgentCore 呼び出し時間 | > 10分 で警告 |
| Invoker の `Errors` | AgentCore 呼び出し失敗 | 5分で 3件以上 |

### Bedrock AgentCore Observability

- AgentCore Runtime / Memory の Trace は CloudWatch GenAI Observability に自動で出る
- Invoker から `runtimeSessionId` を渡すと Trace 内で session が一意に追える
- ユーザーから「この応答おかしい」と言われたら **Slack の `thread_ts`** から AgentCore の Trace を引ける (= 強力なデバッグ手段)

---

## セキュリティ考慮事項

- **Slack 署名検証は必ず実施** (検証なしで API Gateway を公開すると DoS / なりすまし攻撃を受ける)
- **API Gateway に WAF をつける** ことを推奨 (レート制限、地域制限)
- **Secrets Manager の自動ローテーション** は Slack 側非対応なので、Bot Token のローテーションは手動運用
- **AgentCore Runtime に渡す payload に PII を含める場合**、Runtime 側のログマスキング設定を確認すること
- **Bedrock Guardrails** を AgentCore Runtime 側で有効化 (本ドキュメントのスコープ外)

---

## 既知の制約と将来拡張

### 現バージョンの制約

- **Slack ストリーミング応答なし**: AgentCore のレスポンスを完成形で 1 回投稿するのみ。Slack には逐次更新する仕組みがあるが、`chat.update` のレート制限 (1 メッセージあたり ~1 リクエスト/秒) があり、慎重な実装が必要
- **添付ファイル受信なし**: ユーザーが Slack に画像を添付しても無視される。対応する場合 `event.files[].url_private` を Bot Token で取得 → AgentCore に渡すロジックを追加
- **インタラクティブ要素なし**: ボタン・モーダルなどの Block Kit インタラクションは未対応 (`interactivity` は manifest で無効化済み)

### 将来拡張の優先順位

1. **添付ファイル対応**: 画像 / PDF を AgentCore に渡せるように
2. **ストリーミング応答**: 長時間タスクで進捗が見えるように `chat.update` で段階更新
3. **ユーザー単位 OAuth**: Jira / GitHub などをユーザーごとに連携 (AgentCore Identity 利用)
4. **マルチワークスペース対応**: OAuth インストールフロー実装 + DynamoDB で `team_id → bot_token` 管理

---

## チェックリスト (Claude Code 向け実装タスク)

### Terraform
- [ ] `variables.tf`, `main.tf`, `outputs.tf` の骨組み
- [ ] `secrets.tf` (Slack 認証情報、`ignore_changes`)
- [ ] `dynamodb.tf` (重複排除テーブル + TTL)
- [ ] `sqs.tf` (FIFO + DLQ)
- [ ] `api_gateway.tf` (HTTP API + Route + Stage + Permission)
- [ ] `receiver_lambda.tf` (function + archive_file)
- [ ] `invoker_lambda.tf` (function + SQS event source mapping)
- [ ] `iam.tf` (最小権限ポリシー)
- [ ] `env/dev.tfvars`, `env/prod.tfvars`

### Receiver Lambda
- [ ] `handler.py` (上記擬似コードを実装)
- [ ] `slack_verify.py` (HMAC-SHA256 検証)
- [ ] `dedup.py` (DynamoDB 条件付き Put)
- [ ] Secrets Manager のキャッシュ (グローバルスコープ)
- [ ] エラー時も必ず 200 を返す (Slack のリトライ嵐を防ぐ)

### Invoker Lambda
- [ ] `handler.py` (SQS バッチ処理 + ReportBatchItemFailures)
- [ ] `agentcore_client.py` (`InvokeAgentRuntime` ラッパー)
- [ ] `slack_client.py` (`chat.update`, `chat.postMessage`, ファイル添付)
- [ ] 長文分割
- [ ] レート制限ハンドリング (`Retry-After`)
- [ ] エラー時の Slack 通知

### 動作確認
- [ ] `terraform apply` 成功
- [ ] Slack App の Request URL が Verified ✓
- [ ] メンションで応答が返る
- [ ] スレッド内継続が動く (= AgentCore Memory に履歴が積まれる)
- [ ] Bot 自身の発言を拾わない
- [ ] 同じイベントを2回送っても1回しか応答しない
