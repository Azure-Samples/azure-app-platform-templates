# MCP Hosted Skill (`text-insights`)

Deterministic Azure Functions MCP Hosted Skill built on `azurefunctions-agents-runtime`.

## Endpoints

- `POST /runtime/webhooks/mcp` — Streamable HTTP MCP server exposing the deterministic `analyze_text` tool (`initialize`, `tools/list`, `tools/call`).
- `POST /api/tools/analyze_text` — Direct HTTP JSON endpoint executing `analyze_text` without model calls.
- `GET /api/health` — Readiness probe returning `{"status": "ok", "skill": "...", "tools": ["analyze_text"], "deterministic": true}`.

## Local Run

```bash
cp local.settings.json.example local.settings.json
uv run func start --port 7071
```
