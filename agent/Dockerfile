FROM --platform=linux/arm64 python:3.13-slim

WORKDIR /app

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY main.py .

RUN useradd -m appuser
USER appuser

EXPOSE 8080

CMD ["uv", "run", "opentelemetry-instrument", "python", "main.py"]
