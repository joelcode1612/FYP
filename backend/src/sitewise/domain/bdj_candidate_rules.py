"""Conservative, *candidate* BDJ rules and source-status interpretation.

No LLM, network call, customer response, or external evidence access. Only
explicit statements with an exact current M2 answer revision can become an
issue candidate. A missing optional response is never a defect by itself.
This is not a scientifically accepted or complete set of café planning rules.
"""
from __future__ import annotations

import re

# The existing persisted rule_version column is VARCHAR(32) in PostgreSQL.
# Previous candidate identifier was 33 chars; do not reuse it for writes.
RULE_VERSION = "BDJ-RULESET-0.2-CAND"
assert len(RULE_VERSION) <= 32

# Classification register. 'IMPLEMENTED_CANDIDATE' != scientifically accepted.
# Non-automatable categories are left for the existing independent review.
RULE_CATALOGUE = (
    {"class": "SOURCE_CONFLICT", "rule_id": "SERVICE_FORMAT_EXPLICIT_CONFLICT",
     "status": "IMPLEMENTED_CANDIDATE", "source_keys": ["M2-04", "M2-05"]},
    {"class": "UNSUPPORTED_ASSERTION", "rule_id": "UNSUPPORTED_PROFIT_GUARANTEE",
     "status": "IMPLEMENTED_CANDIDATE", "source_keys": ["M2-04"]},
    {"class": "UNSUPPORTED_ASSERTION", "rule_id": "UNSUPPORTED_DEMAND_GUARANTEE",
     "status": "IMPLEMENTED_CANDIDATE", "source_keys": ["M2-04"]},
    {"class": "UNSUPPORTED_ASSERTION", "rule_id": "UNVERIFIED_ZERO_COMPETITORS",
     "status": "IMPLEMENTED_CANDIDATE", "source_keys": ["M2-04"]},
    {"class": "FINANCIAL_EVIDENCE", "rule_id": "CLAIMED_CALCULATION_UNVERIFIED",
     "status": "IMPLEMENTED_CANDIDATE", "source_keys": ["M2-04", "M2-14"]},
    {"class": "FINANCIAL_EVIDENCE", "rule_id": "COST_AND_MARGIN_CALCULATION",
     "status": "NOT_IMPLEMENTED_NOT_AUTHORIZED", "source_keys": ["M2-12", "M2-13", "M2-14"]},
    {"class": "SOURCE_STATUS", "rule_id": "DECLARED_HELD_NOT_VERIFIED",
     "status": "EXPLANATORY_NOTICE_NOT_ISSUE", "source_keys": ["M2-16"]},
    {"class": "SOURCE_STATUS", "rule_id": "CONFIDENCE_NOT_EVIDENCE",
     "status": "EXPLANATORY_NOTICE_NOT_ISSUE", "source_keys": ["M2-18"]},
    {"class": "FORECAST_STATUS", "rule_id": "FORECAST_NOT_OBSERVATION",
     "status": "EXPLANATORY_NOTICE_NOT_ISSUE", "source_keys": ["M2-O-01"]},
    {"class": "OPTIONALITY", "rule_id": "OPTIONAL_ABSENCE_NOT_FAILURE",
     "status": "POLICY_NO_AUTOMATIC_ISSUE", "source_keys": ["M2-04"]},
    {"class": "RELEVANCE", "rule_id": "OVERLOOKED_PLANNING_CONCERNS",
     "status": "INDEPENDENT_RESEARCH_REQUIRED", "source_keys": []},
    {"class": "SCIENTIFIC_VALIDITY", "rule_id": "BUSINESS_CONCEPT_SUFFICIENCY",
     "status": "INDEPENDENT_RESEARCH_REQUIRED", "source_keys": []},
)


def _answered(answers: dict[str, dict], key: str) -> dict | None:
    answer = answers.get(key)
    if not answer or answer.get("answer_state") != "ANSWERED":
        return None
    return answer


def _raw_description(answers: dict[str, dict]) -> tuple[dict | None, str]:
    answer = _answered(answers, "M2-04")
    value = answer.get("value_json") if answer else None
    if not isinstance(value, str) or not value.strip():
        return None, ""
    return answer, " ".join(value.casefold().split())


def _candidate(rule_id: str, issue_type: str, sources: list[dict],
               explanation: str, not_proven: str, next_action: str) -> dict:
    return {
        "rule_id": rule_id,
        "rule_version": RULE_VERSION,
        "issue_type": issue_type,
        "source_answer_ids": [str(a["id"]) for a in sources],
        "explanation": explanation,
        "not_proven": not_proven,
        "next_action": next_action,
        "review_state": "CANDIDATE",
    }


def format_conflict(answers: dict[str, dict]) -> dict | None:
    """Only obvious categorical description conflicts; doubtful ones abstain."""
    desc, service = _raw_description(answers)[0], _answered(answers, "M2-05")
    if desc is None or service is None:
        return None
    code = service.get("value_json")
    if not isinstance(code, str):
        return None
    text = " ".join(desc["value_json"].casefold().split())
    takeaway_only = bool(re.search(r"\b(?:takeaway[- ]only|only takeaway)\b", text))
    dine_only = bool(re.search(r"\b(?:dine[- ]in[- ]only|only dine[- ]in)\b", text))
    # Past, conditional, quoted or negated text is ambiguous and not a direct
    # statement of the current operating plan. Avoid false positive alarms.
    if re.search(r"\b(?:not|no|never|previously|formerly|used to|considered|might|maybe|sometimes|weekends|weekdays|quoted|hypothetical)\b", text):
        return None
    incompatible = (takeaway_only and code == "DINE_IN_FOCUSED") or (
        dine_only and code == "TAKEAWAY_DELIVERY_FOCUSED")
    if not incompatible:
        return None
    return _candidate(
        "SERVICE_FORMAT_EXPLICIT_CONFLICT", "POTENTIAL_DECLARATION_CONFLICT",
        [desc, service],
        "Your description and selected service format appear inconsistent.",
        "Neither format is independently verified; this is an entrepreneur clarification issue.",
        "Review M2-04 and M2-05. Only you can decide whether to save a correction.",
    )


def _contains_assertion(text: str, pattern: str) -> bool:
    """Conservative positive match; negations/attribution/uncertainty abstain.

    This cannot replace linguistic or scientific review of free text.
    """
    if re.search(r"\b(?:don't|do not|cannot|can't|never|not|no)\s+guarantee\b", text):
        return False
    if re.search(r"\b(?:if|might|maybe|could|hypothetical|previously|reported|someone said|people say)\b", text):
        return False
    return bool(re.search(pattern, text))


def explicit_unsupported_claims(answers: dict[str, dict]) -> list[dict]:
    desc, text = _raw_description(answers)
    if desc is None:
        return []
    issues: list[dict] = []
    if _contains_assertion(text, r"\bguarantee(?:d|s)?\s+(?:\w+\s+){0,4}(?:profit|profitable|profitability|business success)\b"):
        issues.append(_candidate(
            "UNSUPPORTED_PROFIT_GUARANTEE", "CLAIM_REQUIRES_VERIFICATION", [desc],
            "The description guarantees financial success, but no validated profit measurement is attached to this M2 declaration.",
            "This does not prove the claim is false or that the business cannot be profitable.",
            "State this as an entrepreneur expectation or provide an independently reviewed financial basis; do not auto-rewrite M2-04.",
        ))
    if _contains_assertion(text, r"\bguarantee(?:d|s)?\s+(?:\w+\s+){0,5}(?:\d+\s+(?:daily\s+)?customers|customer demand|customers will visit|sales)\b"):
        issues.append(_candidate(
            "UNSUPPORTED_DEMAND_GUARANTEE", "CLAIM_REQUIRES_VERIFICATION", [desc],
            "The description guarantees customer activity without a linked verified measurement in this M2 assessment.",
            "The record is a declared expectation, not an observed demand measurement; the claim is not thereby proven false.",
            "Clarify whether this is a target or assumption; do not present it as measured demand.",
        ))
    if _contains_assertion(text, r"\b(?:there are|we have|there is)\s+(?:no|zero)\s+(?:local\s+)?competitors\b"):
        issues.append(_candidate(
            "UNVERIFIED_ZERO_COMPETITORS", "CLAIM_REQUIRES_VERIFICATION", [desc],
            "The description states that no competitors exist, but M2 does not establish a complete verified competitor inventory.",
            "Absence of a verified source does not establish either zero competitors or their presence.",
            "Specify the locality and obtain an independently verified, scope-limited competitor source before making a factual claim.",
        ))
    if _contains_assertion(text, r"\b(?:i|we)\s+(?:have\s+)?calculated\s+(?:our\s+)?break[- ]even\b"):
        supporting = [desc]
        self_estimate = _answered(answers, "M2-14")
        if self_estimate is not None:
            supporting.append(self_estimate)
        issues.append(_candidate(
            "CLAIMED_CALCULATION_UNVERIFIED", "FINANCIAL_METHOD_NOT_ESTABLISHED", supporting,
            "The description says break-even was calculated, but this M2 assessment does not contain a verified calculation contract.",
            "An entrepreneur's M2-14 time estimate is not a computed break-even result; calculations performed elsewhere are not ruled out.",
            "Review the relevant prices, fixed/variable cost inputs, method and provenance separately; retain the entrepreneur's original answer.",
        ))
    return issues


def evaluate_candidate_issues(answers: dict[str, dict]) -> list[dict]:
    """Return only evidence-traceable, conservative candidate issue records."""
    result = []
    conflict = format_conflict(answers)
    if conflict:
        result.append(conflict)
    result.extend(explicit_unsupported_claims(answers))
    return result


def interpretation_notices(answers: dict[str, dict]) -> list[dict]:
    """Caveats for declared M2 information; these are NOT BDJ defect findings."""
    notices: list[dict] = []
    labels = (
        ("M2-12", "CAPITAL_BAND_DECLARATION", "Planned capital is a self-declared range, not verified funding or financial capacity."),
        ("M2-13", "EXPENSE_CATEGORIES_NOT_COSTS", "Expected expense categories are not actual costs, unit contribution margin or financial viability."),
        ("M2-14", "BREAK_EVEN_ESTIMATE_NOT_COMPUTED", "Self-estimated break-even timing is not an independently calculated break-even result."),
        ("M2-16", "DECLARED_HELD_NOT_VERIFIED", "Reportedly held evidence is not a file actually inspected or independently verified by this assessment."),
        ("M2-18", "CONFIDENCE_NOT_EVIDENCE", "The entrepreneur's confidence rating is a perception, not a measurement of demand or evidence quality."),
        ("M2-O-01", "FORECAST_NOT_OBSERVATION", "Expected customers are a forecast or assumption, not actual visits or measured demand."),
        ("M2-O-02", "PLANNED_STAFF_NOT_ACTUAL", "Planned staffing is not a verified employment count."),
    )
    for key, code, meaning in labels:
        answer = _answered(answers, key)
        if answer is not None:
            notices.append({"notice_id": code, "source_item_key": key,
                            "source_answer_revision_id": str(answer["id"]),
                            "evidence_class": "ENTREPRENEUR_DECLARED",
                            "text": meaning, "finding": False})
    return notices
