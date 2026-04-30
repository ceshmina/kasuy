# Slack App 構築手順書

## このドキュメントについて

AgentCore Runtime を Slack から呼び出すための **Slack App 側の構築手順** をまとめる。
AWS 側のリソース構築は別ドキュメント (`02_aws_implementation_plan.md`) で扱う。

## なぜ Terraform で完結できないか

Slack App 自体を Terraform で管理する選択肢はある (例: `yumemi-inc/slackapp`, `change-engine/slack-app` などのサードパーティ Provider)。しかし以下の理由から、**プロダクション利用では Manifest JSON + 手動手順のハイブリッドを推奨**する。

- いずれも **Slack 公式ではない** サードパーティ Provider
- Provider を使うにせよ、事前に **App Configuration Token の発行が手動** (https://api.slack.com/apps から取得)
- Bot Token (`xoxb-...`) の取得・ワークスペースへのインストールは **必ず人間の操作が必要** (OAuth フロー)
- Request URL の検証チャレンジを Slack が送るため、**API Gateway を先に立ててから Slack 側を設定する** という時間的依存がある

このため、本ドキュメントでは以下の方針を取る。

- **Slack App の定義は Manifest JSON でコード化**(再現性確保)
- **インストール・トークン取得・Request URL 設定は手順書化**(人間が実行)
- 取得した Bot Token / Signing Secret は **AWS Secrets Manager に投入**(以降は Terraform 管理)

---

## 構築フロー全体像

```
[1] AWS 側を先に Terraform apply (Request URL を確定させる)
       │
       ▼
[2] Slack App を Manifest から作成
       │
       ▼
[3] ワークスペースにインストール → Bot Token 取得
       │
       ▼
[4] Bot Token / Signing Secret を Secrets Manager に投入
       │
       ▼
[5] Slack App の Event Subscriptions で Request URL を有効化
       │
       ▼
[6] チャネルに Bot を招待して動作確認
```

ポイントは **[1] と [2] の順序**。Slack の Event Subscriptions は Request URL の検証 (URL Verification チャレンジ) を行うため、API Gateway が応答できる状態でないと登録できない。

---

## 事前準備

- Slack ワークスペースの管理権限(または App インストール権限)
- AWS 側の API Gateway エンドポイントが払い出されていること
  - 例: `https://abc123.execute-api.ap-northeast-1.amazonaws.com/prod/slack/events`
- ボット名・表示名の決定

---

## 手順 1: App Manifest を準備する

以下の JSON を `slack-app-manifest.json` として保存する。`<<...>>` 部分を埋めること。

```json
{
  "display_information": {
    "name": "<<BOT_DISPLAY_NAME>>",
    "description": "AgentCore Runtime を呼び出す AI アシスタント",
    "background_color": "#2c2d30"
  },
  "features": {
    "bot_user": {
      "display_name": "<<BOT_DISPLAY_NAME>>",
      "always_online": true
    }
  },
  "oauth_config": {
    "scopes": {
      "bot": [
        "app_mentions:read",
        "chat:write",
        "chat:write.public",
        "channels:history",
        "groups:history",
        "im:history",
        "mpim:history",
        "users:read",
        "files:write",
        "reactions:write"
      ]
    }
  },
  "settings": {
    "event_subscriptions": {
      "request_url": "<<API_GATEWAY_ENDPOINT>>/slack/events",
      "bot_events": [
        "app_mention",
        "message.channels",
        "message.groups",
        "message.im",
        "message.mpim"
      ]
    },
    "interactivity": {
      "is_enabled": false
    },
    "org_deploy_enabled": false,
    "socket_mode_enabled": false,
    "token_rotation_enabled": false
  }
}
```

### スコープの根拠

| スコープ | 用途 |
|---|---|
| `app_mentions:read` | `@bot` メンションのイベントを受け取る |
| `chat:write` | スレッドへの投稿 (回答、"処理中…"プレースホルダ) |
| `chat:write.public` | Bot が招待されていないチャネルでもメンション応答可能にする |
| `channels:history` `groups:history` `im:history` `mpim:history` | スレッド内のリプライ (`message.*` イベント) を取得 |
| `users:read` | 発言ユーザーの表示名取得 (AgentCore Memory に渡したい場合) |
| `files:write` | エージェントが図表など返すケースで添付ファイル送信 |
| `reactions:write` | 受信通知用の絵文字リアクション (オプション、"処理中…"投稿の代替手段) |

### イベントの根拠

- `app_mention`: メンション検知
- `message.channels` / `message.groups` / `message.im` / `message.mpim`: スレッド内のリプライをすべて拾う
  - **重要**: スレッド内リプライをエージェントに継続応答させたい場合、これらが必要
  - 後段で「Bot がいるスレッドだけ処理する」フィルタリングを Lambda 側で行う

---

## 手順 2: App を作成する

1. ブラウザで https://api.slack.com/apps を開く
2. **Create New App** をクリック
3. **From a manifest** を選択
4. インストール先のワークスペースを選択
5. 用意した `slack-app-manifest.json` の内容を貼り付け
6. **Next** → 設定確認 → **Create**

この時点では **Request URL の検証は失敗する** (AWS 側がまだ Slack 署名検証を通せないため、または Secrets が未投入のため)。一旦 Event Subscriptions は無効のままで OK。

---

## 手順 3: 認証情報を取得する

App 作成後、以下の3つを控える。

### Signing Secret

- 左メニュー **Basic Information** → **App Credentials** セクション
- **Signing Secret** の **Show** をクリックしてコピー

### Bot Token (xoxb-...)

- 左メニュー **OAuth & Permissions**
- **Install to Workspace** をクリック (初回)
- 権限確認画面で **Allow**
- インストール完了後、**Bot User OAuth Token** が表示される (`xoxb-` で始まる)
- これをコピー

### App ID / Bot User ID (オプション)

- **Basic Information** で App ID 確認
- Bot User ID は Slack 上で `@bot` のプロフィールから "Copy member ID" で取得可能
- 自身の発言を無視するロジックに使うので控えておくと便利

---

## 手順 4: AWS Secrets Manager に投入

CLI で投入する例:

```bash
aws secretsmanager create-secret \
  --name "/agentcore-slack/prod/slack" \
  --description "Slack credentials for AgentCore bot" \
  --secret-string '{
    "bot_token": "xoxb-XXXX...",
    "signing_secret": "abcd1234...",
    "bot_user_id": "U0XXXXX"
  }' \
  --region ap-northeast-1
```

Terraform で先に空の Secret を作成しておき、値だけ手動投入する運用がおすすめ:

```hcl
# Terraform 側 (詳細は 02_aws_implementation_plan.md)
resource "aws_secretsmanager_secret" "slack" {
  name = "/agentcore-slack/${var.env}/slack"
}
# value は手動投入 → terraform import で state に取り込まない
# (lifecycle { ignore_changes = [...] } で値の変更を無視させる)
```

---

## 手順 5: Request URL を有効化する

1. Slack App 設定画面 → **Event Subscriptions**
2. **Enable Events** を ON
3. **Request URL** に AWS 側エンドポイントを入力
   - 例: `https://abc123.execute-api.ap-northeast-1.amazonaws.com/prod/slack/events`
4. Slack が `url_verification` チャレンジを送信
5. AWS 側 (Receiver Lambda) が `challenge` パラメータをそのまま返せば **Verified ✓** が表示される
6. **Subscribe to bot events** に Manifest と同じイベントが入っていることを確認
7. **Save Changes**

> **トラブル**: Verified にならない場合、Lambda の CloudWatch Logs を確認。多くは「Signing Secret 未投入」「Lambda が3秒以内に応答していない」「`challenge` フィールドの返却を忘れた」のいずれか。

---

## 手順 6: チャネルに Bot を招待する

```
/invite @<<bot_name>>
```

または チャネル設定 → **Integrations** → **Add apps** から追加。

DM だけで使う場合は招待不要 (Bot に直接 DM すれば動く)。

---

## 動作確認

### メンション応答

```
@bot こんにちは
```

### スレッド継続

Bot の返信に対してそのままスレッド内で発言 → エージェントが文脈を維持して応答する。

### 重複応答が起きないか

短時間に複数メッセージを投げて、同じ質問が複数回処理されないことを確認 (Slack のリトライ重複排除が効いているか)。

---

## 運用上の注意点

### Manifest を後から変更したいとき

- App 設定画面 → **App Manifest** から JSON を直接編集可能
- スコープを追加した場合は **再インストール (Reinstall to Workspace)** が必要 → Bot Token も再発行されるので Secrets Manager の値を更新する

### 複数環境 (dev / prod)

- **App は環境ごとに別々に作る** ことを強く推奨
  - 同一 App を使い回すと Request URL が一つしか持てず混線する
  - Manifest JSON は同じものをテンプレ化し、`name` と `request_url` だけ環境ごとに差し替える

### Bot Token のローテーション

- Slack は Token Rotation 機能 (`token_rotation_enabled`) も持つが、Manifest のシンプルさを優先して本構成では無効化
- 必要なら手動で **Reinstall** → Secrets Manager 更新で対応

### ワークスペース横断 (複数組織で使う)

- 単一ワークスペース運用なら本手順で十分
- 複数ワークスペース対応する場合は **OAuth インストールフロー** の実装と、`team_id` ごとの Token 保管が別途必要 (DynamoDB 推奨)。本構成のスコープ外。

---

## チェックリスト

- [ ] AWS 側の API Gateway / Receiver Lambda がデプロイ済み
- [ ] Manifest JSON で Slack App を作成
- [ ] Bot User OAuth Token (`xoxb-...`) を取得
- [ ] Signing Secret を取得
- [ ] Bot User ID を控えた
- [ ] Secrets Manager に3つの値を投入
- [ ] Event Subscriptions の Request URL が **Verified ✓**
- [ ] チャネルに Bot を招待
- [ ] メンションで応答が返る
- [ ] スレッド内リプライで文脈が維持される
