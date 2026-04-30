import hashlib
import hmac
import json
import logging
import os
import time
import urllib.error
import urllib.request

import boto3
from botocore.exceptions import ClientError

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
SLACK_SECRET_NAME = os.environ["SLACK_SECRET_NAME"]
DEDUP_TABLE = os.environ["DEDUP_TABLE"]
JOB_QUEUE_URL = os.environ["JOB_QUEUE_URL"]

DEDUP_TTL_SECONDS = 3600
TIMESTAMP_TOLERANCE_SECONDS = 60 * 5

logger = logging.getLogger()
logger.setLevel(LOG_LEVEL)

_secrets_client = boto3.client("secretsmanager")
_dynamodb = boto3.resource("dynamodb")
_sqs = boto3.client("sqs")
_dedup_table = _dynamodb.Table(DEDUP_TABLE)


def _load_slack_secret() -> dict:
    resp = _secrets_client.get_secret_value(SecretId=SLACK_SECRET_NAME)
    return json.loads(resp["SecretString"])


_slack_secret = _load_slack_secret()


def _ok(body: str = "") -> dict:
    return {"statusCode": 200, "body": body}


def _verify_signature(headers: dict, body: bytes) -> bool:
    ts = headers.get("x-slack-request-timestamp", "")
    sig = headers.get("x-slack-signature", "")
    if not ts or not sig:
        return False
    try:
        ts_int = int(ts)
    except ValueError:
        return False
    if abs(time.time() - ts_int) > TIMESTAMP_TOLERANCE_SECONDS:
        return False
    basestring = b"v0:" + ts.encode() + b":" + body
    mine = "v0=" + hmac.new(
        _slack_secret["signing_secret"].encode(),
        basestring,
        hashlib.sha256,
    ).hexdigest()
    return hmac.compare_digest(mine, sig)


def _put_dedup(event_id: str) -> bool:
    try:
        _dedup_table.put_item(
            Item={"event_id": event_id, "ttl": int(time.time()) + DEDUP_TTL_SECONDS},
            ConditionExpression="attribute_not_exists(event_id)",
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def _slack_post_message(channel: str, thread_ts: str, text: str) -> str | None:
    payload = {"channel": channel, "thread_ts": thread_ts, "text": text}
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {_slack_secret['bot_token']}",
            "Content-Type": "application/json; charset=utf-8",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read())
    except urllib.error.URLError as e:
        logger.error("slack postMessage failed: %s", e)
        return None
    if not data.get("ok"):
        logger.error("slack postMessage error: %s", data)
        return None
    return data.get("ts")


def _enqueue_job(message: dict, message_group_id: str, dedup_id: str) -> None:
    _sqs.send_message(
        QueueUrl=JOB_QUEUE_URL,
        MessageBody=json.dumps(message),
        MessageGroupId=message_group_id,
        MessageDeduplicationId=dedup_id,
    )


def lambda_handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    raw_body = event.get("body") or ""
    body_bytes = raw_body.encode() if isinstance(raw_body, str) else raw_body

    if not _verify_signature(headers, body_bytes):
        logger.warning("invalid signature")
        return {"statusCode": 401, "body": "invalid signature"}

    try:
        payload = json.loads(raw_body)
    except json.JSONDecodeError:
        return _ok()

    if payload.get("type") == "url_verification":
        return {"statusCode": 200, "body": payload.get("challenge", "")}

    event_id = payload.get("event_id")
    if not event_id:
        return _ok()
    if not _put_dedup(event_id):
        logger.info("duplicate event_id=%s", event_id)
        return _ok()

    inner = payload.get("event") or {}
    bot_user_id = _slack_secret.get("bot_user_id")
    if inner.get("bot_id") or inner.get("user") == bot_user_id:
        return _ok()

    inner_type = inner.get("type")
    text = inner.get("text") or ""
    channel = inner.get("channel")
    if not channel:
        return _ok()

    if inner_type != "app_mention":
        return _ok()
    thread_ts = inner.get("thread_ts") or inner.get("ts")

    placeholder_ts = _slack_post_message(channel, thread_ts, "_処理中…_")
    if not placeholder_ts:
        return _ok()

    message = {
        "channel": channel,
        "thread_ts": thread_ts,
        "user": inner.get("user"),
        "team": payload.get("team_id") or inner.get("team"),
        "text": text,
        "placeholder_ts": placeholder_ts,
        "event_ts": inner.get("event_ts"),
        "event_id": event_id,
    }
    _enqueue_job(
        message,
        message_group_id=f"{channel}#{thread_ts}",
        dedup_id=event_id,
    )

    return _ok()
