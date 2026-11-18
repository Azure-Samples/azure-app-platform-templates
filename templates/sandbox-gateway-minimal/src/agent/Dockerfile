FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim
ARG UV_DEFAULT_INDEX="https://pypi.org/simple"
ENV UV_DEFAULT_INDEX=${UV_DEFAULT_INDEX}
ENV XDG_CACHE_HOME=/opt/app-runtime-cache
RUN groupadd --gid 10001 appuser && useradd --uid 10001 --gid appuser --create-home appuser

WORKDIR /app/src/agent
COPY src/agent/pyproject.toml ./pyproject.toml
RUN uv sync --no-dev
RUN uv run python -m copilot download-runtime

COPY src/agent/main.py ./main.py
COPY src/agent/prompts ./prompts
COPY config /app/config
COPY src/policy /app/src/policy
RUN mkdir -p /var/lib/app-copilot && chown 10001:10001 /var/lib/app-copilot \
    && chmod -R a+rX,a-w /app /opt/app-runtime-cache

ENV COPILOT_HOME=/var/lib/app-copilot
ENV PYTHONUNBUFFERED=1
ENV UV_CACHE_DIR=/tmp/uv-cache
ENV HOME=/home/appuser
USER 10001:10001
EXPOSE 8080
CMD ["uv", "run", "--no-sync", "main.py", "--sandbox-worker", "--host", "0.0.0.0", "--port", "8080"]
