FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim
ARG UV_DEFAULT_INDEX="https://pypi.org/simple"
ENV UV_DEFAULT_INDEX=${UV_DEFAULT_INDEX}
RUN groupadd --gid 10001 appuser && useradd --uid 10001 --gid appuser --create-home appuser

WORKDIR /app/src/tools/document-validation
COPY src/tools/document-validation/pyproject.toml ./pyproject.toml
RUN uv sync --no-dev
COPY src/tools/document-validation/main.py ./main.py
COPY src/tools/document-validation/contract.json ./contract.json
COPY src/policy /app/src/policy
COPY config/document-policy.json /app/config/document-policy.json
RUN chmod -R a+rX,a-w /app

ENV PYTHONUNBUFFERED=1
ENV UV_CACHE_DIR=/tmp/uv-cache
ENV HOME=/home/appuser
USER 10001:10001
EXPOSE 8080
CMD ["uv", "run", "--no-sync", "main.py", "--serve", "--host", "0.0.0.0", "--port", "8080"]
