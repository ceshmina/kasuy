from bedrock_agentcore.runtime import BedrockAgentCoreApp
from strands import Agent
from strands.models import BedrockModel

app = BedrockAgentCoreApp()

model = BedrockModel(
    model_id="jp.anthropic.claude-sonnet-4-6",
    streaming=True,
)

agent = Agent(
    model=model,
    system_prompt="You are a helpful assistant. Answer questions clearly and concisely.",
)


@app.entrypoint
async def handler(request):
    prompt = request.get("prompt", "Hello")
    async for event in agent.stream_async(prompt):
        yield event


if __name__ == "__main__":
    app.run()
