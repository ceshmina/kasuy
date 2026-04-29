import json
import os
import sys
import urllib.request

REGION = "ap-northeast-1"


def iter_local(prompt: str):
    req = urllib.request.Request(
        "http://localhost:8080/invocations",
        data=json.dumps({"prompt": prompt}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as res:
        for line in res:
            yield line


def iter_remote(prompt: str):
    import boto3

    arn = os.environ["AGENT_RUNTIME_ARN"]
    qualifier = os.environ["AGENT_QUALIFIER"]
    client = boto3.client("bedrock-agentcore", region_name=REGION)
    res = client.invoke_agent_runtime(
        agentRuntimeArn=arn,
        qualifier=qualifier,
        payload=json.dumps({"prompt": prompt}).encode(),
    )
    yield from res["response"].iter_lines()


def main() -> None:
    target = sys.argv[1] if len(sys.argv) > 1 else "local"
    prompt = sys.argv[2] if len(sys.argv) > 2 else "Hello"

    if target == "local":
        lines = iter_local(prompt)
    elif target in ("staging", "production"):
        lines = iter_remote(prompt)
    else:
        sys.exit(f"unknown target: {target} (expected local|staging|production)")

    for line in lines:
        if isinstance(line, bytes):
            line = line.decode()
        line = line.strip()
        if not line.startswith("data: "):
            continue
        try:
            data = json.loads(line[6:])
        except json.JSONDecodeError:
            continue
        if not isinstance(data, dict):
            continue
        delta = data.get("event", {}).get("contentBlockDelta", {}).get("delta", {}).get("text")
        if delta:
            print(delta, end="", flush=True)
    print()


if __name__ == "__main__":
    main()
