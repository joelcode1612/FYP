"""M2V1-keyed BDJ ruleset candidate — RETIRED_NOT_ADOPTED, kept as evidence only.

Version ``BDJ-RULESET-0.3-M2V1-CAND``.

History
-------
Authored 2026-11-17 to re-key the ``BDJ-RULESET-0.2-CAND`` catalogue onto the
live instrument ``M2V1-20261114-1``, because 0.2 names only legacy keys
(``M2-04``/``M2-05``/``M2-12``/``M2-13``/``M2-14``/``M2-16``/``M2-18``/
``M2-O-01``) and therefore hands the model an empty ``rule_catalogue``.

Retired the same day, before any provider call, when the Owner re-affirmed D02
(``docs/cp00_integration/PROJECT1_D02_RULESET_RETIREMENT_DECISION_20261117.md``):
"M2V1 BDJ is contradiction-free by design."

Why it was rejected
-------------------
Only one of the twelve entries had a faithful M2V1 source:
``SERVICE_FORMAT_EXPLICIT_CONFLICT`` over ``M2V1-02`` + ``M2V1-07``. That pair is
exactly the evidence basis of ``M2V1_DELIVERY_WITH_ON_PREMISE_OCCASION``, which
D02 rejected on the ground that a non-seating format can serve an on-premise
occasion off-premise (group orders, product taken elsewhere). Narrowing the
trigger to ``TAKEAWAY`` and excluding ``DELIVERY`` does not escape that
objection: a takeaway counter serves a study-or-work occasion the same way. The
re-key also weakens the evidence basis — the legacy rule required an *explicit*
"takeaway-only" statement, while M2V1 has no text item, so the declaration
becomes the categorical "Primarily takeaway" and the rule fires on a combination
the legacy rule could never have seen.

What was considered, and the mapping that was rejected
------------------------------------------------------
Every row is the 0.2 catalogue entry with the M2V1 key that was proposed for it.
``status`` was copied verbatim and never upgraded.

| rule_id | M2V1 keys | basis for the proposed mapping |
|---|---|---|
| SERVICE_FORMAT_EXPLICIT_CONFLICT | M2V1-02, M2V1-07 | M2V1-02 is the service-format declaration (was M2-05); M2V1-07 is the only premises-visit item (was M2-04's prose role) |
| UNSUPPORTED_PROFIT_GUARANTEE | none | needs free text; no TEXT item |
| UNSUPPORTED_DEMAND_GUARANTEE | none | needs free text; no TEXT item |
| UNVERIFIED_ZERO_COMPETITORS | none | needs free text; no competitor item |
| CLAIMED_CALCULATION_UNVERIFIED | none | M2-04 and M2-14 both absent |
| COST_AND_MARGIN_CALCULATION | none | M2-12/M2-13/M2-14 absent |
| DECLARED_HELD_NOT_VERIFIED | none | M2-16 absent |
| CONFIDENCE_NOT_EVIDENCE | none | M2-18 absent; M2V1-11 is a research position, not a confidence rating |
| FORECAST_NOT_OBSERVATION | none | M2-O-01 absent |
| OPTIONAL_ABSENCE_NOT_FAILURE | M2V1-07 | the only OPTIONAL item; policy, never an issue |
| OVERLOOKED_PLANNING_CONCERNS | none | no source by design |
| BUSINESS_CONCEPT_SUFFICIENCY | none | no source by design |

Eleven of twelve entries therefore have no M2V1 source at all. A rule that can
never fire is not coverage, and the one rule that could fire was rejected.

Consequence, stated plainly
---------------------------
The module is not registered in ``bdj.RULE_MODULES``, so ``load_rules()`` raises
``BDJ_RULE_ADOPTION_REQUIRED`` for this version even with a correct sha256 and a
valid receipt. ``BDJEngine.review`` therefore computes an empty ``allowed`` set
for M2V1 and cloud BDJ cannot contribute a finding on this instrument. That is
the adopted position, not a regression.

The rule code below is deliberately unchanged so the rejected candidate stays
auditable, exactly as ``bdj_m2v1_candidate_rules.py`` was preserved. Its tests
still prove that the rule *would* fire — which is what makes this a decision
rather than an omission.
"""
from __future__ import annotations

# Persisted rule_version column is VARCHAR(32).
RULE_VERSION = "BDJ-RULESET-0.3-M2V1-CAND"
assert len(RULE_VERSION) <= 32

#: False by owner decision (D02 re-affirmed, 2026-11-17). Import-time evidence,
#: not a switch: activation is prevented by absence from ``bdj.RULE_MODULES``.
ADOPTED = False
STATUS = "RETIRED_NOT_ADOPTED"

# M2V1-02 = "Primarily takeaway": the customer collects and leaves.
NON_SEATING_FORMATS = frozenset({"TAKEAWAY"})
# M2V1-07 occasions that require the customer to remain on the premises.
# Deliberately STUDY_WORK only: it is the one occasion that unambiguously needs a
# seat and a surface. SOCIAL/LEISURE are excluded because a meeting point or a
# walk-up counter can serve them, and excluding them keeps the trigger narrow
# rather than inventing reach the evidence does not support.
STAY_ON_PREMISES_OCCASIONS = frozenset({"STUDY_WORK"})

# Every entry is the legacy catalogue row, with source_keys re-derived against
# M2V1-20261114-1. `status` is copied verbatim and never upgraded.
RULE_CATALOGUE = (
    # M2V1-02 asks "How do you currently plan to serve customers?" and offers
    # TAKEAWAY. M2V1-07 asks "Which customer occasion do you mainly intend your
    # cafe concept to support?" and offers STUDY_WORK. The instrument itself
    # treats M2V1-07 as a premises-visit attribute: its rule makes the item
    # NOT_APPLICABLE only for DELIVERY ("Do not force an in-person visit occasion
    # for a delivery-only concept"). A takeaway counter cannot host a
    # study-or-work visit, so the two answers are the same conflict the legacy
    # rule found between M2-04 prose and M2-05, expressed over the two items that
    # actually carry a service format and a visit occasion in M2V1.
    {"class": "SOURCE_CONFLICT", "rule_id": "SERVICE_FORMAT_EXPLICIT_CONFLICT",
     "status": "IMPLEMENTED_CANDIDATE", "source_keys": ["M2V1-02", "M2V1-07"],
     "m2v1_coverage": "IMPLEMENTED",
     "mapping_basis": "M2V1-02 is the service-format declaration (legacy M2-05); "
                      "M2V1-07 is the only item that states what customers do on "
                      "the premises (legacy M2-04's free-text role)."},
    # Requires a free-text assertion ("guaranteed profit"). No M2V1 item accepts
    # text, so no key exists. M2V1-06 (emphasis) is a concept attribute, not an
    # assertion about outcomes, and mapping to it would fabricate a claim.
    {"class": "UNSUPPORTED_ASSERTION", "rule_id": "UNSUPPORTED_PROFIT_GUARANTEE",
     "status": "IMPLEMENTED_CANDIDATE", "source_keys": [],
     "m2v1_coverage": "NO_M2V1_SOURCE",
     "mapping_basis": "needs free text; M2V1-20261114-1 has no TEXT item."},
    {"class": "UNSUPPORTED_ASSERTION", "rule_id": "UNSUPPORTED_DEMAND_GUARANTEE",
     "status": "IMPLEMENTED_CANDIDATE", "source_keys": [],
     "m2v1_coverage": "NO_M2V1_SOURCE",
     "mapping_basis": "needs free text; M2V1-20261114-1 has no TEXT item."},
    {"class": "UNSUPPORTED_ASSERTION", "rule_id": "UNVERIFIED_ZERO_COMPETITORS",
     "status": "IMPLEMENTED_CANDIDATE", "source_keys": [],
     "m2v1_coverage": "NO_M2V1_SOURCE",
     "mapping_basis": "needs free text; M2V1-20261114-1 has no TEXT item and no "
                      "competitor item."},
    # Legacy cites M2-04 (text) plus M2-14 (self-estimated break-even). Neither
    # exists in M2V1; no financial item does.
    {"class": "FINANCIAL_EVIDENCE", "rule_id": "CLAIMED_CALCULATION_UNVERIFIED",
     "status": "IMPLEMENTED_CANDIDATE", "source_keys": [],
     "m2v1_coverage": "NO_M2V1_SOURCE",
     "mapping_basis": "M2-04 and M2-14 are absent from M2V1-20261114-1."},
    {"class": "FINANCIAL_EVIDENCE", "rule_id": "COST_AND_MARGIN_CALCULATION",
     "status": "NOT_IMPLEMENTED_NOT_AUTHORIZED", "source_keys": [],
     "m2v1_coverage": "NO_M2V1_SOURCE",
     "mapping_basis": "M2-12/M2-13/M2-14 are absent; status unchanged and not "
                      "upgraded."},
    {"class": "SOURCE_STATUS", "rule_id": "DECLARED_HELD_NOT_VERIFIED",
     "status": "EXPLANATORY_NOTICE_NOT_ISSUE", "source_keys": [],
     "m2v1_coverage": "NO_M2V1_SOURCE",
     "mapping_basis": "M2-16 (evidence reportedly held) is absent."},
    {"class": "SOURCE_STATUS", "rule_id": "CONFIDENCE_NOT_EVIDENCE",
     "status": "EXPLANATORY_NOTICE_NOT_ISSUE", "source_keys": [],
     "m2v1_coverage": "NO_M2V1_SOURCE",
     "mapping_basis": "M2-18 (confidence rating) is absent; M2V1-11 is a research "
                      "position, not a confidence rating."},
    {"class": "FORECAST_STATUS", "rule_id": "FORECAST_NOT_OBSERVATION",
     "status": "EXPLANATORY_NOTICE_NOT_ISSUE", "source_keys": [],
     "m2v1_coverage": "NO_M2V1_SOURCE",
     "mapping_basis": "M2-O-01 (expected customers) is absent."},
    # Policy entry, never an issue. M2V1-07 is the instrument's only OPTIONAL
    # item, so it is the only key this policy can name.
    {"class": "OPTIONALITY", "rule_id": "OPTIONAL_ABSENCE_NOT_FAILURE",
     "status": "POLICY_NO_AUTOMATIC_ISSUE", "source_keys": ["M2V1-07"],
     "m2v1_coverage": "POLICY_ONLY",
     "mapping_basis": "M2V1-07 is the only item with requiredness OPTIONAL; its "
                      "absence must never become a finding."},
    {"class": "RELEVANCE", "rule_id": "OVERLOOKED_PLANNING_CONCERNS",
     "status": "INDEPENDENT_RESEARCH_REQUIRED", "source_keys": [],
     "m2v1_coverage": "NO_M2V1_SOURCE",
     "mapping_basis": "no source by design; independent research required."},
    {"class": "SCIENTIFIC_VALIDITY", "rule_id": "BUSINESS_CONCEPT_SUFFICIENCY",
     "status": "INDEPENDENT_RESEARCH_REQUIRED", "source_keys": [],
     "m2v1_coverage": "NO_M2V1_SOURCE",
     "mapping_basis": "no source by design; independent research required."},
)


def _answered(answers: dict[str, dict], key: str) -> dict | None:
    answer = answers.get(key)
    if not answer or answer.get("answer_state") != "ANSWERED":
        return None
    return answer


def _single(answers: dict[str, dict], key: str) -> str | None:
    answer = _answered(answers, key)
    if answer is None:
        return None
    value = answer.get("value_json")
    return value if isinstance(value, str) else None


def _candidate(rule_id: str, sources: list[dict], explanation: str,
               not_proven: str, next_action: str) -> dict:
    return {
        "rule_id": rule_id,
        "rule_version": RULE_VERSION,
        "issue_type": "POTENTIAL_DECLARATION_CONFLICT",
        "source_answer_ids": [str(a["id"]) for a in sources],
        "explanation": explanation,
        "not_proven": not_proven,
        "next_action": next_action,
        "review_state": "CANDIDATE",
    }


def format_conflict(answers: dict[str, dict]) -> dict | None:
    """A non-seating service format declared with a stay-on-premises occasion.

    Abstains unless both answers are ANSWERED and both codes are in the narrow
    sets above. DELIVERY is excluded on purpose: D02 (2026-11-17) recorded that a
    delivery-only format can serve an on-premise occasion off-premise, and this
    ruleset does not re-litigate that finding.
    """
    service = _answered(answers, "M2V1-02")
    occasion = _answered(answers, "M2V1-07")
    if service is None or occasion is None:
        return None
    if _single(answers, "M2V1-02") not in NON_SEATING_FORMATS:
        return None
    if _single(answers, "M2V1-07") not in STAY_ON_PREMISES_OCCASIONS:
        return None
    return _candidate(
        "SERVICE_FORMAT_EXPLICIT_CONFLICT", [service, occasion],
        "M2V1-02 declares a primarily takeaway service format, while M2V1-07 "
        "declares a studying-or-working occasion that requires customers to "
        "remain on the premises.",
        "Neither declaration is independently verified, and the occasion may be "
        "served by customers who take the product elsewhere. This is an "
        "entrepreneur clarification issue, not a finding that the concept fails.",
        "Review M2V1-02 and M2V1-07. Only you can decide whether to save a "
        "correction; M2 is not rewritten.")


def explicit_unsupported_claims(answers: dict[str, dict]) -> list[dict]:
    """Always empty: M2V1 has no free-text item to read an assertion from.

    Kept as a named function so the absence is explicit at the call site rather
    than implied by an omitted import.
    """
    return []


def evaluate_candidate_issues(answers: dict[str, dict]) -> list[dict]:
    """Return only evidence-traceable, conservative candidate issue records."""
    conflict = format_conflict(answers)
    return [conflict] if conflict else []


def interpretation_notices(answers: dict[str, dict]) -> list[dict]:
    """Always empty: every notice in the legacy set keys an absent M2 item.

    M2-12..M2-18 and M2-O-01/M2-O-02 do not exist in M2V1-20261114-1, and no
    M2V1 item is an explanatory notice of the same kind. Inventing a mapping
    would attach a financial or evidence caveat to an answer that does not carry
    that meaning.
    """
    return []
