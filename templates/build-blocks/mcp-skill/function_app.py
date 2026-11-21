"""Deterministic MCP Hosted Skill entry point on azurefunctions-agents-runtime."""

from __future__ import annotations

import json
from pathlib import Path
import re

import azure.functions as func
from azure_functions_agents import create_function_app
from azurefunctions.extensions.http.fastapi import JSONResponse, Request
from openai._client import WORKLOAD_IDENTITY_API_KEY_PLACEHOLDER, AsyncOpenAI

import tools
from tools.analyze_text import TOOL_DESCRIPTION, TOOL_NAME, analyze_text, compute_text_metrics

_orig_prepare_request = AsyncOpenAI._prepare_request


async def _strip_placeholder_bearer_auth(self, request):
    await _orig_prepare_request(self, request)
    if request.headers.get("authorization") == f"Bearer {WORKLOAD_IDENTITY_API_KEY_PLACEHOLDER}":
        del request.headers["authorization"]


AsyncOpenAI._prepare_request = _strip_placeholder_bearer_auth

_SKILL_ROOT = Path(__file__).resolve().parent
_FRONTMATTER_NAME_RE = re.compile(r"^name:\s*([^\r\n#]+)", re.MULTILINE)

_ANALYZE_TEXT_MCP_PROPERTIES = json.dumps(
    [
        {
            "propertyName": "text",
            "propertyType": "string",
            "description": "Bounded UTF-8 text or markdown (1 to 65,536 characters) to analyze.",
            "isRequired": True,
            "isArray": False,
        }
    ]
)


def _resolve_skill_name() -> str:
    agents_dir = _SKILL_ROOT / "agents"
    if agents_dir.is_dir():
        for pattern in ("*.agent.md", "*.agent.md.template"):
            for candidate in sorted(agents_dir.glob(pattern)):
                match = _FRONTMATTER_NAME_RE.search(candidate.read_text(encoding="utf-8"))
                if match:
                    raw = match.group(1).strip().strip("\"'")
                    if raw and raw != "__SKILL_NAME__":
                        return raw
    dir_name = _SKILL_ROOT.name
    if dir_name and dir_name not in ("__SKILL__", "mcp-skill"):
        return dir_name
    return "text-insights"


SKILL_NAME = _resolve_skill_name()
app = create_function_app(_SKILL_ROOT)


@app.function_name(name="mcp_tool_analyze_text")
@app.mcp_tool_trigger(
    arg_name="context",
    tool_name=TOOL_NAME,
    description=TOOL_DESCRIPTION,
    tool_properties=_ANALYZE_TEXT_MCP_PROPERTIES,
)
def mcp_analyze_text(context: str) -> str:
    payload = json.loads(context) if context else {}
    arguments = payload.get("arguments", payload) if isinstance(payload, dict) else {}
    if not isinstance(arguments, dict) or "text" not in arguments:
        raise ValueError("Missing required string argument 'text'.")
    return analyze_text(text=arguments["text"])


@app.route(route="health", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
async def get_skill_health(req: Request) -> JSONResponse:
    return JSONResponse(
        {
            "status": "ok",
            "skill": SKILL_NAME,
            "tools": [TOOL_NAME],
            "deterministic": True,
        }
    )


@app.route(route="tools/analyze_text", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
async def post_analyze_text(req: Request) -> JSONResponse:
    try:
        payload = await req.json()
    except (ValueError, UnicodeDecodeError):
        return JSONResponse({"error": "Request body must be valid JSON."}, status_code=400)
    if not isinstance(payload, dict) or "text" not in payload:
        return JSONResponse({"error": "Request body must include 'text'."}, status_code=400)
    try:
        metrics = compute_text_metrics(payload["text"])
    except ValueError as exc:
        return JSONResponse({"error": str(exc)}, status_code=400)
    return JSONResponse(metrics)
