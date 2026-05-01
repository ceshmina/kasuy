import json
import logging
import os
import urllib.error
import urllib.request

import boto3

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

TAVILY_SECRET_NAME = os.environ["TAVILY_SECRET_NAME"]
TAVILY_SEARCH_ENDPOINT = "https://api.tavily.com/search"
TAVILY_EXTRACT_ENDPOINT = "https://api.tavily.com/extract"

_secrets = boto3.client("secretsmanager")
_api_key: str | None = None


def _get_api_key() -> str:
    global _api_key
    if _api_key is None:
        raw = _secrets.get_secret_value(SecretId=TAVILY_SECRET_NAME)["SecretString"]
        _api_key = json.loads(raw)["api_key"]
    return _api_key


def _tavily_post(endpoint: str, payload: dict, timeout: int) -> dict:
    body = json.dumps({"api_key": _get_api_key(), **payload}).encode()
    req = urllib.request.Request(
        endpoint,
        data=body,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Tavily HTTP {e.code}: {detail}") from e


def _tool_web_search(args: dict) -> dict:
    raw = _tavily_post(
        TAVILY_SEARCH_ENDPOINT,
        {
            "query": args["query"],
            "max_results": int(args.get("max_results", 5)),
            "search_depth": args.get("search_depth", "basic"),
            "include_answer": False,
            "include_raw_content": False,
        },
        timeout=20,
    )
    return {
        "results": [
            {
                "title": r.get("title", ""),
                "url": r.get("url", ""),
                "content": r.get("content", ""),
                "score": float(r.get("score", 0.0)),
            }
            for r in raw.get("results", [])
        ]
    }


def _tool_web_extract(args: dict) -> dict:
    raw = _tavily_post(
        TAVILY_EXTRACT_ENDPOINT,
        {
            "urls": args["urls"],
            "extract_depth": args.get("extract_depth", "basic"),
            "include_images": False,
        },
        timeout=60,
    )
    return {
        "results": [
            {
                "url": r.get("url", ""),
                "raw_content": r.get("raw_content", ""),
            }
            for r in raw.get("results", [])
        ],
        "failed_results": [
            {
                "url": r.get("url", ""),
                "error": r.get("error", ""),
            }
            for r in raw.get("failed_results", [])
        ],
    }


TOOLS = {
    "web_search": _tool_web_search,
    "web_extract": _tool_web_extract,
}


def _resolve_tool_name(event: dict, context) -> str:
    custom = getattr(getattr(context, "client_context", None), "custom", None) or {}
    qualified = custom.get("bedrockAgentCoreToolName") or event.get("__tool_name__")
    if not qualified:
        raise ValueError("missing bedrockAgentCoreToolName in client context")
    return qualified.split("___", 1)[1] if "___" in qualified else qualified


def lambda_handler(event, context):
    name = _resolve_tool_name(event, context)
    logger.info("invoking tool: %s", name)
    fn = TOOLS.get(name)
    if fn is None:
        raise ValueError(f"unknown tool: {name}")
    return fn(event)
