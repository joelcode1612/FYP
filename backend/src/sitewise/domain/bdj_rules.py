"""Narrow documentary-only candidate rules for BDJ issue discovery.

This does not establish scientific validity, business viability or customer demand.
False-positive controls deliberately prefer abstention to guessing.
"""
import re

RULE_VERSION = "BDJ-EXPLICIT-FORMAT-0.1-CANDIDATE"


def format_conflict(answers: dict[str, dict]) -> dict | None:
    desc, service = answers.get("M2-04"), answers.get("M2-05")
    if not desc or not service:
        return None
    if desc["answer_state"] != "ANSWERED" or service["answer_state"] != "ANSWERED":
        return None
    raw = desc["value_json"]
    code = service["value_json"]
    if not isinstance(raw, str) or not isinstance(code, str):
        return None
    text = " ".join(raw.casefold().split())
    # Only unambiguous, first-person direct descriptions qualify for this
    # candidate rule. Ambiguous language belongs to human review, not an alert.
    takeaway_only = bool(re.search(r"\b(?:takeaway[- ]only|only takeaway)\b", text))
    dine_only = bool(re.search(r"\b(?:dine[- ]in[- ]only|only dine[- ]in)\b", text))
    if re.search(r"\b(?:not|no|never)\s+(?:a\s+)?(?:takeaway[- ]only|only takeaway|dine[- ]in[- ]only|only dine[- ]in)\b", text):
        return None
    incompatible = (takeaway_only and code == "DINE_IN_FOCUSED") or (
        dine_only and code == "TAKEAWAY_DELIVERY_FOCUSED"
    )
    if not incompatible:
        return None
    return {
        "rule_id": "SERVICE_FORMAT_EXPLICIT_CONFLICT",
        "rule_version": RULE_VERSION,
        "issue_type": "POTENTIAL_DECLARATION_CONFLICT",
        "source_answer_ids": [str(desc["id"]), str(service["id"])],
        "explanation": "Your description and selected service format appear inconsistent.",
        "not_proven": "Neither format is verified; this is a candidate clarification finding.",
        "next_action": "Review M2-04 and M2-05; do not automatically rewrite either answer.",
        "review_state": "CANDIDATE",
    }
