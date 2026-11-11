"""Pure, deterministic dual-population successor routing policy.

No I/O, no database, no framework imports, no real respondent data.
`ELIGIBLE_TO_SHOW` is a PREVIEW permission only; it is not a display event,
an answer, a cohort membership or a denominator.
"""

import hashlib
import json
from dataclasses import dataclass

from .contracts import (
    CONCEPT_VERSION,
    INSTRUMENT_VERSION,
    M2_CONTEXT_VERSION,
    Q01_AFFILIATIONS,
    Q01_LEGACY_FREQUENCY,
    Q01_SUCCESSOR_NO_CONNECTION,
    Q02_CODES,
    Q04_CODES,
    Q04_NONZERO,
    QUESTION_BANK_VERSION,
    QUESTION_IDS,
    ROUTING_POLICY_VERSION,
    ALLOWED_STATES,
    ConsentSnapshot,
    Principal,
    RoutePreviewRequest,
    RoutePreviewResponse,
    PreviewPermission,
)

JURISDICTIONS = frozenset({"JOHOR", "PENANG", "SELANGOR", "KUALA_LUMPUR"})


class RoutingError(ValueError):
    """A refusal, not an exception in the crash sense."""


@dataclass(frozen=True)
class SyntheticAuthority:
    """Server-side synthetic fixture approvals, never client-supplied.

    Distinct type from any real authorization: this can never be promoted by
    renaming a flag. Every response remains production_fielding_authorized=False.
    """

    approved_concept_stimulus: bool = True
    concept_exposed: bool = True
    menu_bank_approved: bool = False
    exact_offer_approved: bool = False
    future_occasion_bank_approved: bool = False
    defined_price_reference_item: bool = False
    q09_policy_approved: bool = False
    q10_policy_approved: bool = False
    q10_feature_bank_approved: bool = False
    optional_context_enabled: bool = False
    q02_display_policy: str = "ALL"


def classify_q01(codes: tuple[str, ...]) -> str:
    """Preserve legacy codes; new code is a successor candidate, never a recode."""
    if not codes:
        return "PENDING"
    if len(set(codes)) != len(codes):
        return "INVALID_DUPLICATE"
    known = Q01_AFFILIATIONS | Q01_LEGACY_FREQUENCY | {Q01_SUCCESSOR_NO_CONNECTION}
    if any(c not in known for c in codes):
        return "INVALID_CODE"
    affiliations = [c for c in codes if c in Q01_AFFILIATIONS]
    legacy = [c for c in codes if c in Q01_LEGACY_FREQUENCY]
    has_new = Q01_SUCCESSOR_NO_CONNECTION in codes
    if affiliations and legacy:
        return "INVALID_CONFLICT"          # e.g. LIVE + NEVER
    if affiliations and has_new:
        return "INVALID_CONFLICT"
    if affiliations:
        return "CURRENT_CONNECTION"
    if has_new and not legacy:
        return "NO_CURRENT_CONNECTION"
    if has_new and legacy:
        return "HISTORICAL_AMBIGUOUS"      # never silently recoded
    if legacy:
        return "HISTORICAL_AMBIGUOUS" if len(codes) == 1 else "CONNECTION_UNCERTAIN"
    return "CONNECTION_UNCERTAIN"


def _versions_match(request: RoutePreviewRequest) -> str | None:
    expected = {
        "instrument_version": INSTRUMENT_VERSION,
        "routing_policy_version": ROUTING_POLICY_VERSION,
        "question_bank_version": QUESTION_BANK_VERSION,
        "concept_version": CONCEPT_VERSION,
        "m2_context_version": M2_CONTEXT_VERSION,
    }
    for field, value in expected.items():
        if getattr(request, field) != value:
            return f"VERSION_MISMATCH:{field}"
    return None


def evaluate_route(
    request: RoutePreviewRequest,
    principal: Principal,
    consent: ConsentSnapshot,
    authority: SyntheticAuthority | None = None,
    server_revision: int = 0,
) -> RoutePreviewResponse:
    auth = authority or SyntheticAuthority()

    states = {qid: ("BLOCKED", "UNSET") for qid in QUESTION_IDS}

    def put(qid: str, state: str, reason: str) -> None:
        assert state in ALLOWED_STATES
        states[qid] = (state, reason)

    def blocked_all(reason: str, route_state: str) -> RoutePreviewResponse:
        for qid in QUESTION_IDS:
            put(qid, "BLOCKED", reason)
        return _build(request, route_state, "BLOCKED", states, ())

    def not_shown_all(reason: str, route_state: str) -> RoutePreviewResponse:
        for qid in QUESTION_IDS:
            put(qid, "NOT_SHOWN", reason)
        return _build(request, route_state, "NOT_SHOWN", states, ())

    # --- fail closed, in order of precedence -----------------------------
    if not principal.authenticated:
        return blocked_all("UNAUTHORIZED", "HELD_UNAUTHORIZED")
    if principal.tenant_id != request.tenant_id:
        return blocked_all("CROSS_TENANT_DENIED", "HELD_UNAUTHORIZED")
    if principal.jurisdiction not in JURISDICTIONS:
        return blocked_all("UNSUPPORTED_JURISDICTION", "HELD_UNAUTHORIZED")
    if consent.withdrawn:
        return not_shown_all("WITHDRAWN", "WITHDRAWN")
    if not consent.consented:
        return blocked_all("CONSENT_REQUIRED", "HELD_UNAUTHORIZED")
    version_error = _versions_match(request)
    if version_error:
        return blocked_all(version_error, "BLOCKED")
    if request.expected_revision != server_revision:
        return blocked_all("STALE_REVISION", "BLOCKED")
    if request.q02_code is not None and request.q02_code not in Q02_CODES:
        return blocked_all("INVALID_Q02_CODE", "VALIDATION_REQUIRED")
    if request.q04_code is not None and request.q04_code not in Q04_CODES:
        return blocked_all("INVALID_Q04_CODE", "VALIDATION_REQUIRED")

    group = classify_q01(tuple(request.q01_codes))
    if group.startswith("INVALID"):
        for qid in QUESTION_IDS[2:]:
            put(qid, "BLOCKED", "Q01_INVALID_REQUIRES_CORRECTION")
        return _build(request, "VALIDATION_REQUIRED", group, states, ())

    # --- both populations proceed ----------------------------------------
    put("Q01", "ELIGIBLE_TO_SHOW", "AREA_AFFILIATION_OR_EXPLICIT_NO_CONNECTION")
    if auth.q02_display_policy == "ALL":
        put("Q02", "ELIGIBLE_TO_SHOW", "FOUR_WEEK_DISTINCT_DAYS_NO_ELIGIBILITY_THRESHOLD")
    elif group in {"CURRENT_CONNECTION", "NO_CURRENT_CONNECTION"}:
        put("Q02", "ELIGIBLE_TO_SHOW", "Q02_ELIGIBLE_ONLY_FIXTURE")
    else:
        put("Q02", "NOT_SHOWN", "Q02_POLICY_ELIGIBLE_ONLY_FIXTURE")

    # Q02 zero days is NEVER a route exit and NEVER a threshold.
    if request.q02_code is None and states["Q02"][0] == "ELIGIBLE_TO_SHOW":
        for qid in QUESTION_IDS[2:]:
            put(qid, "PENDING_DEPENDENCY", "WAIT_FOR_Q02_SCREENING_ANSWER")
        return _build(request, "IN_PROGRESS", group, states, ())

    put("Q04", "ELIGIBLE_TO_SHOW", "ELIGIBLE_FOR_PAST_BEHAVIOR_ITEM")

    concept_ok = auth.approved_concept_stimulus and auth.concept_exposed
    if concept_ok:
        put("Q03", "ELIGIBLE_TO_SHOW", "APPROVED_HYPOTHETICAL_ORIGIN_STIMULUS_FIXTURE")
        put("Q05", "ELIGIBLE_TO_SHOW", "APPROVED_FUTURE_INTENT_STIMULUS_FIXTURE")
    else:
        put("Q03", "NOT_SHOWN", "APPROVED_CONCEPT_STIMULUS_MISSING")
        put("Q05", "NOT_SHOWN", "APPROVED_CONCEPT_STIMULUS_MISSING")

    # Q05 negative/unsure answer is NOT a route exit; it is never read for routing.
    if concept_ok and auth.menu_bank_approved:
        put("Q06", "ELIGIBLE_TO_SHOW", "APPROVED_MENU_FIXTURE")
    else:
        put("Q06", "NOT_SHOWN", "MENU_OR_CONCEPT_STIMULUS_MISSING")

    if auth.exact_offer_approved:
        put("Q07", "ELIGIBLE_TO_SHOW", "APPROVED_EXACT_OFFER_FIXTURE")
    else:
        put("Q07", "NOT_SHOWN", "APPROVED_EXACT_OFFER_MISSING")

    # Q04 ZERO / CANNOT_REMEMBER / refusal withholds Q08 ONLY.
    if request.q04_code is None:
        put("Q08", "PENDING_DEPENDENCY", "WAIT_FOR_Q04_ANSWER")
    elif request.q04_code in Q04_NONZERO:
        put("Q08", "ELIGIBLE_TO_SHOW", "PAST_SUBSTANTIVE_NONZERO_Q04")
    else:
        put("Q08", "NOT_SHOWN", "Q04_NOT_SUBSTANTIVE_NONZERO")

    # Q09/Q10 scientific gates stay DISABLED. No fixture may activate them.
    put("Q09", "NOT_SHOWN", "SCIENTIFIC_GATE_UNAPPROVED")
    put("Q10", "NOT_SHOWN", "SCIENTIFIC_GATE_UNAPPROVED")

    if auth.optional_context_enabled:
        put("Q11", "ELIGIBLE_TO_SHOW", "OPTIONAL_CONTEXT_ENABLED_FIXTURE")
        put("Q12", "ELIGIBLE_TO_SHOW", "OPTIONAL_CONTEXT_ENABLED_FIXTURE")
        if auth.defined_price_reference_item:
            put("Q13", "ELIGIBLE_TO_SHOW", "DEFINED_PRICE_REFERENCE_FIXTURE")
        else:
            put("Q13", "NOT_SHOWN", "DEFINED_PRICE_REFERENCE_MISSING")
    else:
        for qid in ("Q11", "Q12", "Q13"):
            put(qid, "NOT_SHOWN", "OPTIONAL_CONTEXT_DISABLED")

    return _build(request, "IN_PROGRESS", group, states, ())


def _build(
    request: RoutePreviewRequest,
    route_state: str,
    group: str,
    states: dict[str, tuple[str, str]],
    q10_features: tuple[str, ...],
) -> RoutePreviewResponse:
    permissions = [
        PreviewPermission(item_id=qid, state=state, reason=reason)
        for qid, (state, reason) in ((q, states[q]) for q in QUESTION_IDS)
    ]
    next_q = next(
        (q for q in QUESTION_IDS if states[q][0] == "ELIGIBLE_TO_SHOW"),
        None,
    )
    payload = {
        "assessment_id": request.assessment_id,
        "tenant_id": request.tenant_id,
        "q01_codes": sorted(request.q01_codes),
        "q02_code": request.q02_code,
        "q04_code": request.q04_code,
        "q05_code": request.q05_code,
        "expected_revision": request.expected_revision,
        "instrument_version": request.instrument_version,
        "routing_policy_version": request.routing_policy_version,
        "question_bank_version": request.question_bank_version,
        "concept_version": request.concept_version,
        "m2_context_version": request.m2_context_version,
        "group": group,
        "route_state": route_state,
        "decisions": [(p.item_id, p.state, p.reason) for p in permissions],
    }
    packed = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    digest = hashlib.sha256(packed.encode("utf-8")).hexdigest()
    return RoutePreviewResponse(
        assessment_id=request.assessment_id,
        instrument_version=request.instrument_version,
        routing_policy_version=request.routing_policy_version,
        connection_group=group,
        route_state=route_state,
        next_question_id=next_q,
        preview_permissions=permissions,
        q10_feature_ids=q10_features,
        packet_digest=digest,
    )
