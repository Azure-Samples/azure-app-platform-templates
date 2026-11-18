"""Replay-safe decision normalization for the loan approval and inventory replenishment orchestrations."""

from __future__ import annotations

from typing import Any

VALID_DECISIONS = {"approve", "decline", "escalate"}
VALID_REPLENISHMENT_DECISIONS = {"approve", "reject", "expired"}


def resolve_decision(event_payload: Any, timed_out: bool = False) -> str:
    """Map an external event or timer result to a supported workflow outcome."""
    if timed_out:
        return "escalate"

    value = (
        event_payload.get("decision")
        if isinstance(event_payload, dict)
        else event_payload
    )
    normalized = str(value or "").strip().lower()
    return normalized if normalized in VALID_DECISIONS else "escalate"


def resolve_replenishment_decision(event_payload: Any, timed_out: bool = False) -> dict[str, Any]:
    """Normalize an external human-approval decision for inventory replenishment."""
    if timed_out:
        return {
            "decision": "expired",
            "approvedBy": None,
            "notes": "Approval window expired before a manager responded.",
        }

    if isinstance(event_payload, dict):
        raw_decision = event_payload.get("decision")
        approved_by = str(
            event_payload.get("approvedBy")
            or event_payload.get("rejectedBy")
            or event_payload.get("approver")
            or "dealership-manager"
        ).strip()
        notes = str(event_payload.get("notes") or "").strip()
    else:
        raw_decision = event_payload
        approved_by = "dealership-manager"
        notes = ""

    normalized = str(raw_decision or "").strip().lower()
    if normalized in {"approved", "yes"}:
        normalized = "approve"
    elif normalized in {"rejected", "decline", "declined", "no"}:
        normalized = "reject"

    if normalized not in {"approve", "reject"}:
        normalized = "reject"

    return {
        "decision": normalized,
        "approvedBy": approved_by if normalized == "approve" else None,
        "rejectedBy": approved_by if normalized == "reject" else None,
        "notes": notes,
    }

