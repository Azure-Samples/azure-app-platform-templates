import sys
from pathlib import Path

WORKFLOW_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WORKFLOW_DIR))

from orchestrator_logic import resolve_decision, resolve_replenishment_decision


def test_external_event_decisions_are_replay_stable():
    event = {"decision": " APPROVE "}

    assert resolve_decision(event) == "approve"
    assert resolve_decision(event) == "approve"
    assert resolve_decision({"decision": "decline"}) == "decline"


def test_timer_wins_and_escalates():
    assert resolve_decision({"decision": "approve"}, timed_out=True) == "escalate"


def test_unknown_event_safely_escalates():
    assert resolve_decision({"decision": "later"}) == "escalate"


def test_replenishment_approval_normalization():
    approved = resolve_replenishment_decision(
        {"decision": " Approve ", "approvedBy": "gm@contoso-motors.com", "notes": "Order 4 units"}
    )
    assert approved["decision"] == "approve"
    assert approved["approvedBy"] == "gm@contoso-motors.com"
    assert approved["notes"] == "Order 4 units"

    rejected = resolve_replenishment_decision(
        {"decision": "DECLINE", "rejectedBy": "gm@contoso-motors.com", "notes": "Hold Q4 budget"}
    )
    assert rejected["decision"] == "reject"
    assert rejected["rejectedBy"] == "gm@contoso-motors.com"


def test_replenishment_timeout_and_unknown_decisions():
    expired = resolve_replenishment_decision({"decision": "approve"}, timed_out=True)
    assert expired["decision"] == "expired"

    unknown = resolve_replenishment_decision({"decision": "maybe"})
    assert unknown["decision"] == "reject"

