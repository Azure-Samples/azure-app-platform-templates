"""Hosted Skill entry point for `inventory-search`, on the real
`azurefunctions-agents-runtime` (serverless agents runtime) package.

The runtime discovers `skills/inventory-search.agent.md` (front matter +
instructions), auto-discovers the `@tool`-decorated function in
`tools/inventory_search.py`, and registers the resulting agent's HTTP trigger
plus its `builtin_endpoints.mcp: true` MCP tool endpoint
(`/runtime/webhooks/mcp`) - the same Streamable HTTP transport a real Foundry
Toolbox uses, just pointed at localhost during local dev.
"""

from azure_functions_agents import create_function_app
from openai._client import AsyncOpenAI, WORKLOAD_IDENTITY_API_KEY_PLACEHOLDER

_orig_prepare_request = AsyncOpenAI._prepare_request


async def _strip_placeholder_bearer_auth(self, request):
    await _orig_prepare_request(self, request)
    if request.headers.get("authorization") == f"Bearer {WORKLOAD_IDENTITY_API_KEY_PLACEHOLDER}":
        del request.headers["authorization"]


AsyncOpenAI._prepare_request = _strip_placeholder_bearer_auth

import json
import azure.functions as func
from tools.inventory_search import apply_inventory_restock, evaluate_inventory_health

app = create_function_app()


@app.route(route="inventory/health", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def get_inventory_health(req):
    raw_threshold = req.params.get("threshold")
    threshold_override = int(raw_threshold) if raw_threshold and raw_threshold.isdigit() else None
    report = evaluate_inventory_health(threshold_override=threshold_override)
    return func.HttpResponse(
        body=json.dumps(report),
        status_code=200,
        mimetype="application/json",
    )


@app.route(route="inventory/restock", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
def post_inventory_restock(req):
    try:
        payload = req.get_json()
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    vehicles = payload.get("vehicles")
    if not isinstance(vehicles, list):
        vehicles = None
    result = apply_inventory_restock(
        vehicles,
        order_id=payload.get("orderId"),
        approved_by=payload.get("approvedBy"),
    )
    return func.HttpResponse(
        body=json.dumps(result),
        status_code=200,
        mimetype="application/json",
    )

