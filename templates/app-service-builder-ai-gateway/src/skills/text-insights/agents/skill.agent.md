---
name: text-insights
description: Deterministic bounded text and markdown structural analysis over MCP.
trigger:
  type: http_trigger
  args:
    route: text-insights
    methods: ["POST"]
builtin_endpoints:
  mcp: true
---

This Hosted Skill exposes the deterministic `analyze_text` MCP tool over `/runtime/webhooks/mcp`.

Tool contract (`analyze_text`):
- Input: non-empty UTF-8 `text` up to 65,536 characters without NUL or control characters.
- Execution: pure, schema-validated Python structural counting with zero LLM or external network calls.
- Output JSON fields: `characters`, `words`, `lines`, `markdownHeadings`, `questions`, `estimatedTokens`.

Consumers should invoke `analyze_text` directly via MCP `tools/call` for fast, deterministic metrics and use these exact counts to ground or color any user-facing summary without inventing figures.
