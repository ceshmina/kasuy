import asyncio
import base64
import json
import logging
import os
import threading
import time

import boto3
import httpx
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from mcp.client.streamable_http import streamablehttp_client
from strands import Agent
from strands.models import BedrockModel
from strands.tools.mcp import MCPClient

EXPECTED_MCP_TOOLS = {"web_search", "web_extract"}

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger("kasuy.agent")

GATEWAY_URL = os.environ.get("GATEWAY_URL")
GATEWAY_CLIENT_SECRET_NAME = os.environ.get("GATEWAY_CLIENT_SECRET_NAME")
AWS_REGION = os.environ.get("AWS_REGION", "ap-northeast-1")


class CognitoTokenProvider:
    """Caches a Cognito client_credentials access_token until just before expiry."""

    def __init__(self, secret_name: str, region: str):
        self._secret_name = secret_name
        self._secrets = boto3.client("secretsmanager", region_name=region)
        self._lock = threading.Lock()
        self._token: str | None = None
        self._expires_at: float = 0.0
        self._creds: dict | None = None

    def _load_creds(self) -> dict:
        if self._creds is None:
            raw = self._secrets.get_secret_value(SecretId=self._secret_name)["SecretString"]
            self._creds = json.loads(raw)
        return self._creds

    def get(self) -> str:
        with self._lock:
            now = time.time()
            if self._token and now < self._expires_at - 60:
                return self._token
            c = self._load_creds()
            basic = base64.b64encode(f"{c['client_id']}:{c['client_secret']}".encode()).decode()
            r = httpx.post(
                c["token_endpoint"],
                headers={
                    "Authorization": f"Basic {basic}",
                    "Content-Type": "application/x-www-form-urlencoded",
                },
                data={"grant_type": "client_credentials", "scope": c["scope"]},
                timeout=10.0,
            )
            r.raise_for_status()
            payload = r.json()
            self._token = payload["access_token"]
            self._expires_at = now + int(payload.get("expires_in", 3600))
            logger.info("refreshed cognito token, expires_in=%s", payload.get("expires_in"))
            return self._token


def _build_tools() -> list:
    if not GATEWAY_URL or not GATEWAY_CLIENT_SECRET_NAME:
        logger.warning("GATEWAY_URL/GATEWAY_CLIENT_SECRET_NAME not set; running without MCP tools")
        return []

    tokens = CognitoTokenProvider(GATEWAY_CLIENT_SECRET_NAME, AWS_REGION)

    def _make_transport():
        return streamablehttp_client(
            GATEWAY_URL,
            headers={"Authorization": f"Bearer {tokens.get()}"},
            timeout=30.0,
        )

    mcp_client = MCPClient(_make_transport)

    # Eagerly fetch the tool list and validate the expected tools are present.
    # Strands' MCPClient caches the first tools/list result for the lifetime of
    # the process; if a transient partial response slips in (e.g. a paginated
    # second page is dropped), the container would silently serve with only
    # web_search until it is recycled. Failing fast here lets AgentCore Runtime
    # rotate the unhealthy container instead.
    loaded = asyncio.run(mcp_client.load_tools())
    tool_names = sorted(t.tool_name for t in loaded)
    suffixes = {name.rsplit("___", 1)[-1] for name in tool_names}
    missing = EXPECTED_MCP_TOOLS - suffixes
    if missing:
        raise RuntimeError(
            f"AgentCore Gateway returned partial tool list: missing={sorted(missing)} got={tool_names}"
        )
    logger.info("loaded MCP tools: %s", tool_names)
    return [mcp_client]


model = BedrockModel(
    model_id="jp.anthropic.claude-sonnet-4-6",
    streaming=True,
)

agent = Agent(
    model=model,
    tools=_build_tools(),
    system_prompt=(
        "You are a helpful assistant. Answer questions clearly and concisely. "
        "Always format your responses using standard Markdown "
        "(headings, bold, italics, lists, links, code blocks, etc.). "
        "When the user asks about recent events, current data, or facts that may have changed, "
        "use the web_search tool to look them up before answering."
    ),
)

app = BedrockAgentCoreApp()


@app.entrypoint
async def handler(request):
    prompt = request.get("prompt", "Hello")
    async for event in agent.stream_async(prompt):
        yield event


if __name__ == "__main__":
    app.run()
