import json
import logging
import os
import time
import urllib.error
import urllib.request

import boto3

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
SLACK_SECRET_NAME = os.environ["SLACK_SECRET_NAME"]
AGENT_RUNTIME_ARN = os.environ["AGENT_RUNTIME_ARN"]
AGENT_QUALIFIER = os.environ["AGENT_QUALIFIER"]

SLACK_TEXT_LIMIT = 3500
SLACK_API_TIMEOUT = 10

logger = logging.getLogger()
logger.setLevel(LOG_LEVEL)

_secrets_client = boto3.client("secretsmanager")
_agentcore = boto3.client("bedrock-agentcore")


def _load_slack_secret() -> dict:
    resp = _secrets_client.get_secret_value(SecretId=SLACK_SECRET_NAME)
    return json.loads(resp["SecretString"])


_slack_secret = _load_slack_secret()


def _slack_call(method: str, payload: dict) -> dict:
    body = json.dumps(payload).encode()
    headers = {
        "Authorization": f"Bearer {_slack_secret['bot_token']}",
        "Content-Type": "application/json; charset=utf-8",
    }
    while True:
        req = urllib.request.Request(
            f"https://slack.com/api/{method}",
            data=body,
            headers=headers,
        )
        try:
            with urllib.request.urlopen(req, timeout=SLACK_API_TIMEOUT) as resp:
                data = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            if e.code == 429:
                retry_after = int(e.headers.get("Retry-After", "1"))
                logger.warning("slack rate limited, sleeping %ss", retry_after)
                time.sleep(retry_after)
                continue
            raise
        if not data.get("ok"):
            if data.get("error") == "ratelimited":
                time.sleep(1)
                continue
            logger.error("slack %s error: %s", method, data)
        return data


def _slack_update(channel: str, ts: str, text: str) -> None:
    _slack_call("chat.update", {"channel": channel, "ts": ts, "text": text})


def _slack_post(channel: str, thread_ts: str, text: str) -> None:
    _slack_call(
        "chat.postMessage",
        {"channel": channel, "thread_ts": thread_ts, "text": text},
    )


def _make_session_id(channel: str, thread_ts: str) -> str:
    # AgentCore requires runtimeSessionId >= 33 chars matching [a-zA-Z0-9_-]+
    raw = f"slack-{channel}-{thread_ts.replace('.', '-')}"
    return raw.ljust(33, "0")


def _invoke_agent(prompt: str, session_id: str, actor_id: str, metadata: dict) -> str:
    payload = {
        "prompt": prompt,
        "actor_id": actor_id,
        "session_id": session_id,
        "metadata": metadata,
    }
    response = _agentcore.invoke_agent_runtime(
        agentRuntimeArn=AGENT_RUNTIME_ARN,
        qualifier=AGENT_QUALIFIER,
        runtimeSessionId=session_id,
        payload=json.dumps(payload).encode(),
    )

    chunks: list[str] = []
    for raw in response["response"].iter_lines():
        if not raw:
            continue
        line = raw.decode() if isinstance(raw, bytes) else raw
        line = line.strip()
        if not line.startswith("data: "):
            continue
        try:
            data = json.loads(line[6:])
        except json.JSONDecodeError:
            continue
        if not isinstance(data, dict):
            continue
        delta = (
            data.get("event", {})
            .get("contentBlockDelta", {})
            .get("delta", {})
            .get("text")
        )
        if delta:
            chunks.append(delta)
    return "".join(chunks).strip()


def _split_text(text: str, limit: int = SLACK_TEXT_LIMIT) -> list[str]:
    if len(text) <= limit:
        return [text]
    parts: list[str] = []
    remaining = text
    while remaining:
        if len(remaining) <= limit:
            parts.append(remaining)
            break
        cut = remaining.rfind("\n", 0, limit)
        if cut <= 0:
            cut = limit
        parts.append(remaining[:cut])
        remaining = remaining[cut:].lstrip("\n")
    return parts


def _post_response(channel: str, thread_ts: str, placeholder_ts: str, full_text: str) -> None:
    text = full_text or "_(エージェントから空のレスポンスが返りました)_"
    parts = _split_text(text)
    _slack_update(channel, placeholder_ts, parts[0])
    for part in parts[1:]:
        _slack_post(channel, thread_ts, part)


def _process_record(record: dict) -> None:
    body = json.loads(record["body"])
    channel = body["channel"]
    thread_ts = body["thread_ts"]
    placeholder_ts = body["placeholder_ts"]
    text = body.get("text") or ""
    user = body.get("user") or "unknown"
    team = body.get("team") or "unknown"

    actor_id = f"{team}:{user}"
    session_id = _make_session_id(channel, thread_ts)
    metadata = {
        "channel_id": channel,
        "slack_user_id": user,
        "team_id": team,
        "thread_ts": thread_ts,
    }

    try:
        answer = _invoke_agent(text, session_id, actor_id, metadata)
    except Exception:
        logger.exception("invoke_agent_runtime failed")
        try:
            _slack_update(
                channel,
                placeholder_ts,
                ":warning: エージェント呼び出しでエラーが発生しました。もう一度お試しください。",
            )
        except Exception:
            logger.exception("failed to update slack with error notice")
        raise

    _post_response(channel, thread_ts, placeholder_ts, answer)


def lambda_handler(event, context):
    failures: list[dict] = []
    for record in event.get("Records", []):
        message_id = record.get("messageId")
        try:
            _process_record(record)
        except Exception:
            logger.exception("record %s failed", message_id)
            failures.append({"itemIdentifier": message_id})
    return {"batchItemFailures": failures}
