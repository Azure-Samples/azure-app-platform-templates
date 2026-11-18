"""Durable Functions human-in-the-loop loan approval and inventory replenishment workflows."""

from __future__ import annotations

import json
import os
import urllib.request
from datetime import datetime, timedelta, timezone
from typing import Any

import azure.durable_functions as df
import azure.functions as func

from orchestrator_logic import resolve_decision, resolve_replenishment_decision

DEMO_TIMEOUT_SECONDS = 90
DECISION_EVENT = "LoanApprovalDecision"
REPLENISHMENT_DECISION_EVENT = "InventoryReplenishmentApproval"
REPLENISHMENT_TIMEOUT_HOURS = 24

_REPLENISHMENT_LEDGER: dict[str, dict[str, Any]] = {}

app = df.DFApp(http_auth_level=func.AuthLevel.ANONYMOUS)



@app.function_name(name="LoanApprovalOrchestrator")
@app.orchestration_trigger(context_name="context")
def loan_approval_orchestrator(context: df.DurableOrchestrationContext):
    request = context.get_input() or {}
    yield context.call_activity("PostTeamsAdaptiveCard", request)

    deadline = context.current_utc_datetime + timedelta(seconds=DEMO_TIMEOUT_SECONDS)
    timeout_task = context.create_timer(deadline)
    decision_task = context.wait_for_external_event(DECISION_EVENT)
    winner = yield context.task_any([decision_task, timeout_task])

    if winner == decision_task:
        timeout_task.cancel()
        decision = resolve_decision(decision_task.result)
    else:
        decision = resolve_decision(None, timed_out=True)

    activities = {
        "approve": "ApproveLoan",
        "decline": "DeclineLoan",
        "escalate": "EscalateLoan",
    }
    result = yield context.call_activity(
        activities[decision],
        {"dealId": request.get("dealId"), "decision": decision},
    )
    return result


@app.function_name(name="PostTeamsAdaptiveCard")
@app.activity_trigger(input_name="request")
def post_teams_adaptive_card(request: dict) -> dict:
    """Stub the Connector Namespace call without sending customer data."""
    return {
        "status": "stubbed",
        "dealId": request.get("dealId"),
        "message": "Synthetic approval card would be posted to Teams.",
    }


@app.function_name(name="ApproveLoan")
@app.activity_trigger(input_name="request")
def approve_loan(request: dict) -> dict:
    return {"dealId": request.get("dealId"), "status": "approved"}


@app.function_name(name="DeclineLoan")
@app.activity_trigger(input_name="request")
def decline_loan(request: dict) -> dict:
    return {"dealId": request.get("dealId"), "status": "declined"}


@app.function_name(name="EscalateLoan")
@app.activity_trigger(input_name="request")
def escalate_loan(request: dict) -> dict:
    return {"dealId": request.get("dealId"), "status": "escalated"}


@app.function_name(name="StartLoanApproval")
@app.route(route="loan-approval/start", methods=["POST"])
@app.durable_client_input(client_name="client")
async def start_loan_approval(
    req: func.HttpRequest, client: df.DurableOrchestrationClient
) -> func.HttpResponse:
    payload = req.get_json()
    instance_id = await client.start_new("LoanApprovalOrchestrator", None, payload)
    return client.create_check_status_response(req, instance_id)


@app.function_name(name="SubmitLoanApprovalDecision")
@app.route(route="loan-approval/{instanceId}/decision", methods=["POST"])
@app.durable_client_input(client_name="client")
async def submit_loan_approval_decision(
    req: func.HttpRequest, client: df.DurableOrchestrationClient
) -> func.HttpResponse:
    instance_id = req.route_params["instanceId"]
    decision = resolve_decision(req.get_json())
    await client.raise_event(instance_id, DECISION_EVENT, {"decision": decision})
    return func.HttpResponse(status_code=202)


@app.function_name(name="InventoryReplenishmentOrchestrator")
@app.orchestration_trigger(context_name="context")
def inventory_replenishment_orchestrator(context: df.DurableOrchestrationContext):
    request = context.get_input() or {}
    order = yield context.call_activity("PrepareReplenishmentOrder", request)
    context.set_custom_status(
        {
            "state": "awaiting_human_approval",
            "orderId": order.get("orderId"),
            "requestedBy": order.get("requestedBy"),
            "vehicleCount": order.get("vehicleCount"),
            "estimatedTotalUsd": order.get("estimatedTotalUsd"),
            "vehicles": order.get("vehicles", []),
        }
    )

    deadline = context.current_utc_datetime + timedelta(hours=REPLENISHMENT_TIMEOUT_HOURS)
    timeout_task = context.create_timer(deadline)
    decision_task = context.wait_for_external_event(REPLENISHMENT_DECISION_EVENT)
    winner = yield context.task_any([decision_task, timeout_task])

    if winner == decision_task:
        timeout_task.cancel()
        resolution = resolve_replenishment_decision(decision_task.result)
    else:
        resolution = resolve_replenishment_decision(None, timed_out=True)

    if resolution["decision"] == "approve":
        result = yield context.call_activity(
            "ExecuteInventoryReplenishment",
            {
                **order,
                "approvedBy": resolution.get("approvedBy"),
                "notes": resolution.get("notes"),
            },
        )
    else:
        result = yield context.call_activity(
            "RejectInventoryReplenishment",
            {
                **order,
                "decision": resolution["decision"],
                "rejectedBy": resolution.get("rejectedBy"),
                "notes": resolution.get("notes"),
            },
        )

    context.set_custom_status(result)
    return result


@app.function_name(name="PrepareReplenishmentOrder")
@app.activity_trigger(input_name="request")
def prepare_replenishment_order(request: dict) -> dict:
    order_id = str(request.get("orderId") or f"restock-{int(datetime.now(timezone.utc).timestamp())}")
    vehicles = request.get("vehicles")
    if not isinstance(vehicles, list) or not vehicles:
        vehicles = [
            {
                "vin": "5YJYGDEE4RF901101",
                "year": 2024,
                "make": "Tesla",
                "model": "Model Y",
                "trim": "Long Range AWD (7-Seat)",
                "price": 38900,
                "ev_range_miles": 310,
                "mpg": None,
                "odometer_miles": 9400,
                "powertrain": "EV",
                "features": [
                    "third-row seating",
                    "all-wheel drive",
                    "heated seats",
                    "fast charging",
                    "Apple CarPlay",
                ],
            },
            {
                "vin": "KM8KRDAF8RU901102",
                "year": 2024,
                "make": "Kia",
                "model": "EV9",
                "trim": "Light Long Range",
                "price": 39800,
                "ev_range_miles": 304,
                "mpg": None,
                "odometer_miles": 11200,
                "powertrain": "EV",
                "features": [
                    "third-row seating",
                    "Apple CarPlay",
                    "blind spot monitoring",
                    "fast charging",
                    "lane keep assist",
                ],
            },
        ]
    record = {
        "orderId": order_id,
        "status": "awaiting_human_approval",
        "requestedBy": str(request.get("requestedBy") or "sre-dealership-agent"),
        "reason": str(
            request.get("reason")
            or "Three-Row Family EV inventory (1 unit) is below minimum threshold (3 units)."
        ),
        "category": str(request.get("category") or "three_row_ev"),
        "vehicleCount": len(vehicles),
        "estimatedTotalUsd": sum(int(v.get("price", 0)) for v in vehicles),
        "vehicles": vehicles,
        "createdAt": datetime.now(timezone.utc).isoformat(),
    }
    _REPLENISHMENT_LEDGER[order_id] = record
    return record


@app.function_name(name="ExecuteInventoryReplenishment")
@app.activity_trigger(input_name="request")
def execute_inventory_replenishment(request: dict) -> dict:
    order_id = str(request.get("orderId") or "restock-order")
    vehicles = request.get("vehicles") or []
    approved_by = str(request.get("approvedBy") or "dealership-manager")
    inventory_restock_url = os.environ.get(
        "INVENTORY_RESTOCK_URL", "http://127.0.0.1:7071/api/inventory/restock"
    )
    restock_response: dict[str, Any] = {}
    try:
        req = urllib.request.Request(
            inventory_restock_url,
            data=json.dumps(
                {
                    "orderId": order_id,
                    "approvedBy": approved_by,
                    "vehicles": vehicles,
                }
            ).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            restock_response = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:
        restock_response = {"warning": f"Inventory skill callback deferred: {exc}"}

    record = {
        **_REPLENISHMENT_LEDGER.get(order_id, {}),
        "orderId": order_id,
        "status": "approved_and_replenished",
        "approvedBy": approved_by,
        "notes": request.get("notes") or "",
        "vehicleCount": len(vehicles),
        "addedVins": [v.get("vin") for v in vehicles if isinstance(v, dict)],
        "inventoryServiceResult": restock_response,
        "completedAt": datetime.now(timezone.utc).isoformat(),
    }
    _REPLENISHMENT_LEDGER[order_id] = record
    return record


@app.function_name(name="RejectInventoryReplenishment")
@app.activity_trigger(input_name="request")
def reject_inventory_replenishment(request: dict) -> dict:
    order_id = str(request.get("orderId") or "restock-order")
    decision = str(request.get("decision") or "reject")
    record = {
        **_REPLENISHMENT_LEDGER.get(order_id, {}),
        "orderId": order_id,
        "status": "expired" if decision == "expired" else "rejected",
        "rejectedBy": request.get("rejectedBy"),
        "notes": request.get("notes") or "",
        "completedAt": datetime.now(timezone.utc).isoformat(),
    }
    _REPLENISHMENT_LEDGER[order_id] = record
    return record


@app.function_name(name="StartInventoryReplenishment")
@app.route(route="inventory/replenish/start", methods=["POST"])
@app.durable_client_input(client_name="client")
async def start_inventory_replenishment(
    req: func.HttpRequest, client: df.DurableOrchestrationClient
) -> func.HttpResponse:
    try:
        payload = req.get_json()
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}

    order = prepare_replenishment_order(payload)
    instance_id = await client.start_new(
        "InventoryReplenishmentOrchestrator", order["orderId"], order
    )
    status_resp = client.create_check_status_response(req, instance_id)
    status_data = json.loads(status_resp.get_body().decode("utf-8"))
    body = {
        "instanceId": instance_id,
        "orderId": order["orderId"],
        "status": "awaiting_human_approval",
        "approvalEventName": REPLENISHMENT_DECISION_EVENT,
        "decisionEndpoint": f"/api/inventory/replenish/{instance_id}/decision",
        "order": order,
        "durableStatusUrls": status_data,
    }
    return func.HttpResponse(
        body=json.dumps(body),
        status_code=202,
        mimetype="application/json",
    )


@app.function_name(name="SubmitInventoryReplenishmentDecision")
@app.route(route="inventory/replenish/{instanceId}/decision", methods=["POST"])
@app.durable_client_input(client_name="client")
async def submit_inventory_replenishment_decision(
    req: func.HttpRequest, client: df.DurableOrchestrationClient
) -> func.HttpResponse:
    instance_id = req.route_params["instanceId"]
    try:
        payload = req.get_json()
    except ValueError:
        payload = {}
    resolution = resolve_replenishment_decision(payload)
    await client.raise_event(instance_id, REPLENISHMENT_DECISION_EVENT, payload)
    if instance_id in _REPLENISHMENT_LEDGER:
        _REPLENISHMENT_LEDGER[instance_id]["latestDecisionSubmitted"] = resolution
    return func.HttpResponse(
        body=json.dumps(
            {
                "instanceId": instance_id,
                "event": REPLENISHMENT_DECISION_EVENT,
                "resolution": resolution,
                "status": "decision_submitted",
            }
        ),
        status_code=202,
        mimetype="application/json",
    )


@app.function_name(name="ListPendingInventoryReplenishments")
@app.route(route="inventory/replenish/pending", methods=["GET"])
async def list_pending_inventory_replenishments(
    req: func.HttpRequest,
) -> func.HttpResponse:
    items = list(_REPLENISHMENT_LEDGER.values())
    return func.HttpResponse(
        body=json.dumps(
            {
                "count": len(items),
                "awaitingApprovalCount": sum(
                    1 for item in items if item.get("status") == "awaiting_human_approval"
                ),
                "orders": items,
            }
        ),
        status_code=200,
        mimetype="application/json",
    )

