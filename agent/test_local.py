import json
import sys
import urllib.request

prompt = sys.argv[1] if len(sys.argv) > 1 else "Hello"

req = urllib.request.Request(
    "http://localhost:8080/invocations",
    data=json.dumps({"prompt": prompt}).encode(),
    headers={"Content-Type": "application/json"},
)

with urllib.request.urlopen(req) as res:
    for line in res:
        line = line.decode().strip()
        if not line.startswith("data: "):
            continue
        try:
            data = json.loads(line[6:])
        except json.JSONDecodeError:
            continue
        if not isinstance(data, dict):
            continue
        # Stream text deltas
        delta = (data.get("event", {}).get("contentBlockDelta", {}).get("delta", {}).get("text"))
        if delta:
            print(delta, end="", flush=True)
    print()
