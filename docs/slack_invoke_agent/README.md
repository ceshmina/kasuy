# AgentCore Slack Bot - 構築資料

Slack から AWS Bedrock AgentCore Runtime を呼び出すボットの構築資料。
**エージェント本体 (AgentCore Runtime) は既に存在する前提で、Slack 統合層を構築する**。

## ドキュメント一覧

| ファイル | 内容 | 想定読者 |
|---|---|---|
| `01_slack_app_setup.md` | Slack App の作成・設定手順 (Manifest JSON 込み) | 構築担当者 (人間) |
| `02_aws_implementation_plan.md` | AWS 側 (API Gateway / Lambda / SQS など) の実装方針と Terraform 設計 | Claude Code |

## なぜ Slack 部分は Terraform で完結できないか

- Slack App Manifest を扱うサードパーティ Provider は存在するが、いずれも公式ではない
- App Configuration Token の発行・Bot Token のインストール・Request URL の手動検証は **どのみち人間の操作が必要**
- 環境ごと (dev/prod) に App を分けるのが推奨で、結局頻繁な再構築は発生しない

→ **Slack 側は Manifest JSON でコード化しつつ、構築は手順書ベース。AWS 側のみ Terraform で IaC 化** するのが現実解。

## 推奨構築順序

```
1. Terraform で AWS 側を apply
       │
       ▼ (API Gateway URL が払い出される)
2. Slack App を Manifest から作成
       │
       ▼ (Bot Token / Signing Secret を取得)
3. Secrets Manager に投入
       │
       ▼
4. Slack App の Event Subscriptions を有効化
       │
       ▼
5. チャネルに Bot を招待 → 動作確認
```

## アーキテクチャ要約

```
Slack ─▶ API Gateway ─▶ Receiver Lambda ─▶ SQS FIFO ─▶ Invoker Lambda ─▶ AgentCore Runtime (既存)
   ▲                          │                              │
   └──────────────────────────┴──────────────────────────────┘
                       Slack Web API で書き戻し
```

### Slack ↔ AgentCore のキー対応

| Slack | AgentCore |
|---|---|
| `thread_ts` | `session_id` (会話の境界) |
| `team_id:user_id` | `actor_id` (長期記憶のスコープ) |

## 前提条件

- AWS CLI / Terraform / Python 3.12 がローカルで使える
- AWS アカウントに Bedrock AgentCore の利用権限がある
- AgentCore Runtime が既にデプロイ済み (ARN / Memory ID を控えていること)
- Slack ワークスペースに App 作成権限がある
