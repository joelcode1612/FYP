"""M2V1-compatible *candidate* BDJ rules. Prepared for owner review, NOT adopted.

Why this is a new ruleset and not a rename
------------------------------------------
``bdj_candidate_rules.RULE_VERSION`` (``BDJ-RULESET-0.2-CAND``) is bound to the
legacy M2 instrument, whose ``M2-04`` is a free-text business description. Its
rules are text heuristics over that description:

  * ``format_conflict``            regex over M2-04 prose vs M2-05 service code
  * ``explicit_unsupported_claims`` regex for "guaranteed profit", "no competitors",
                                   "we calculated break-even"

The live instrument is ``M2V1-20261114-1``. Every answerable item in it is a
coded SINGLE/MULTI/GEO selection; there is **no free-text item at all**. So the
text-based rules cannot be ported by renaming item IDs: with no prose to read,
``_raw_description()`` returns ``None`` and every legacy rule abstains. Renaming
``M2-04`` to ``M2V1-03`` would have produced a ruleset that silently never fires.

Furthermore, most *cross-item contradictions* the legacy ruleset exists to find
are already prevented at write time by ``validate_m2_answer``:

  M2V1-05 primary not in M2V1-04   -> "Answer must match one registered option value"
                                      (rules.source_item derives effective options)
  M2V1-10 topic not in M2V1-09     -> same
  M2V1-08 NONE + concrete source   -> "NONE must be exclusive"
  M2V1-03/04 UNDECIDED + concrete  -> "This response must be selected on its own"
                                      (rules.exclusive)
  M2V1-11 answered while topics=NONE -> "conditional item is not applicable"
                                      (rules.requires_priority)

A rule that can never fire is not coverage; it is a false claim of coverage.
Those classes are therefore documented in ``STRUCTURALLY_PREVENTED`` rather than
implemented.

What this ruleset does instead
------------------------------
Each implemented rule is a *presupposition failure* that the validator permits:
the entrepreneur declares an intention that presupposes a selection they have
simultaneously declared undecided, or a service format that cannot host the
declared occasion. Every rule needs two independently identified items, so each
candidate is a ``SOURCE_CONFLICT`` under the existing admission contract.

Status: ``RETIRED_NOT_ADOPTED``. This module is retained **as evidence only**.

On 2026-11-17 the owner reviewed all four implemented rules against the question
"is this a contradiction, or an undecided planning assumption?" and every one
failed as ``SOURCE_CONFLICT``:

  M2V1_PRODUCT_EMPHASIS_UNDECIDED_PRODUCTS  planning uncertainty - a business may
                                            intend a quality position before
                                            fixing the range; both can be true
  M2V1_PRODUCT_PREFERENCE_UNDECIDED_PRODUCTS research clarification requirement -
                                            the stimulus is undefined, and the
                                            entrepreneur may intend to use the
                                            research to decide the range
  M2V1_SEGMENT_INTEREST_UNDECIDED_GROUPS     same structure: undefined population,
                                            not a logical conflict
  M2V1_DELIVERY_WITH_ON_PREMISE_OCCASION     delivery-only can serve social
                                            occasions off-premise (group orders,
                                            office delivery)

All four are better classified ``INFORMATION_GAP``, which would be a contract and
classification change rather than a rename. The owner declined that change and
retired the ruleset instead, accepting that **M2V1 BDJ is contradiction-free by
design**: genuine cross-item contradictions are prevented at write time, and the
remainder are not contradictions.

Consequence, stated plainly: with this module unregistered, ``BDJEngine.review``
computes an empty ``allowed`` set for M2V1, so cloud BDJ cannot contribute a
finding on this instrument. That is the adopted position, not a regression.

The code below is deliberately unchanged so the historical candidate remains
auditable. It is no longer importable through ``bdj.RULE_MODULES`` and therefore
cannot be activated by any adoption receipt.
"""
from __future__ import annotations

# Persisted rule_version column is VARCHAR(32); keep the identifier short.
RULE_VERSION = "BDJ-M2V1-0.1-CAND"
assert len(RULE_VERSION) <= 32

#: False by owner decision (2026-11-17). Import-time evidence, not a switch:
#: activation is prevented by removing the module from ``bdj.RULE_MODULES``.
ADOPTED = False
STATUS = "RETIRED_NOT_ADOPTED"

# Product-quality emphases presuppose a decided product range.
PRODUCT_EMPHASES = frozenset({"QUALITY", "DISTINCTIVE_CONCEPT"})
# Occasions that presuppose on-premise seating, incompatible with delivery-only.
ON_PREMISE_OCCASIONS = frozenset({"STUDY_WORK", "SOCIAL", "LEISURE"})

RULE_CATALOGUE = (
    {"class": "SOURCE_CONFLICT", "rule_id": "M2V1_PRODUCT_EMPHASIS_UNDECIDED_PRODUCTS",
     "status": "IMPLEMENTED_CANDIDATE", "source_keys": ["M2V1-03", "M2V1-06"]},
    {"class": "SOURCE_CONFLICT", "rule_id": "M2V1_PRODUCT_PREFERENCE_UNDECIDED_PRODUCTS",
     "status": "IMPLEMENTED_CANDIDATE", "source_keys": ["M2V1-03", "M2V1-09"]},
    {"class": "SOURCE_CONFLICT", "rule_id": "M2V1_SEGMENT_INTEREST_UNDECIDED_GROUPS",
     "status": "IMPLEMENTED_CANDIDATE", "source_keys": ["M2V1-04", "M2V1-09"]},
    {"class": "SOURCE_CONFLICT", "rule_id": "M2V1_DELIVERY_WITH_ON_PREMISE_OCCASION",
     "status": "IMPLEMENTED_CANDIDATE", "source_keys": ["M2V1-02", "M2V1-07"]},
    # Documented as NOT implementable on this instrument. See module docstring.
    {"class": "SOURCE_CONFLICT", "rule_id": "M2V1_PRIMARY_GROUP_NOT_IN_SELECTED_GROUPS",
     "status": "STRUCTURALLY_PREVENTED", "source_keys": ["M2V1-04", "M2V1-05"]},
    {"class": "SOURCE_CONFLICT", "rule_id": "M2V1_PRIORITY_TOPIC_NOT_IN_SELECTED_TOPICS",
     "status": "STRUCTURALLY_PREVENTED", "source_keys": ["M2V1-09", "M2V1-10"]},
    {"class": "UNSUPPORTED_ASSERTION", "rule_id": "M2V1_TEXT_ASSERTION_CLASS",
     "status": "NOT_APPLICABLE_NO_FREE_TEXT", "source_keys": []},
)

# Every legacy rule and why it cannot fire on M2V1-20261114-1.
STRUCTURALLY_PREVENTED = (
    {"rule_id": "M2V1_PRIMARY_GROUP_NOT_IN_SELECTED_GROUPS",
     "prevented_by": "validate_m2_answer SINGLE option membership",
     "mechanism": "M2V1-05 option_values.rules.source_item = M2V1-04 derives "
                  "effective_options from the saved M2V1-04 selection",
     "legacy_analogue": "SERVICE_FORMAT_EXPLICIT_CONFLICT"},
    {"rule_id": "M2V1_PRIORITY_TOPIC_NOT_IN_SELECTED_TOPICS",
     "prevented_by": "validate_m2_answer SINGLE option membership",
     "mechanism": "M2V1-10 option_values.rules.source_item = M2V1-09",
     "legacy_analogue": None},
    {"rule_id": "M2V1_NONE_CO_SELECTED",
     "prevented_by": "validate_m2_answer 'NONE must be exclusive'",
     "mechanism": "M2V1-08/09 rules.exclusive", "legacy_analogue": None},
    {"rule_id": "M2V1_UNDECIDED_CO_SELECTED",
     "prevented_by": "validate_m2_answer 'This response must be selected on its own'",
     "mechanism": "M2V1-03/04 rules.exclusive = ['UNDECIDED']", "legacy_analogue": None},
    {"rule_id": "M2V1_FEEDBACK_SOUGHT_WHILE_INVESTIGATION_DECLINED",
     "prevented_by": "validate_m2_answer conditional applicability",
     "mechanism": "M2V1-11 rules.requires_priority = M2V1-10; applicable=False "
                  "when M2V1-09 == ['NONE']", "legacy_analogue": None},
    {"rule_id": "M2V1_TEXT_ASSERTION_CLASS",
     "prevented_by": "instrument design",
     "mechanism": "no TEXT item exists in M2V1-20261114-1; legacy M2-04 prose "
                  "rules have no source field", "legacy_analogue":
                  "UNSUPPORTED_PROFIT_GUARANTEE / UNSUPPORTED_DEMAND_GUARANTEE / "
                  "UNVERIFIED_ZERO_COMPETITORS / CLAIMED_CALCULATION_UNVERIFIED"},
)


def _answered(answers: dict[str, dict], key: str) -> dict | None:
    answer = answers.get(key)
    if not answer or answer.get("answer_state") != "ANSWERED":
        return None
    return answer


def _selected(answers: dict[str, dict], key: str) -> list[str] | None:
    """Selected codes for a MULTI item, or None when not answered."""
    answer = _answered(answers, key)
    if answer is None:
        return None
    value = answer.get("value_json")
    return list(value) if isinstance(value, list) else None


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


def _pair(answers, first, second):
    a, b = _answered(answers, first), _answered(answers, second)
    return (a, b) if a is not None and b is not None else None


def product_emphasis_undecided(answers: dict[str, dict]) -> dict | None:
    """Emphasising product quality/theme while the product range is undecided."""
    pair = _pair(answers, "M2V1-03", "M2V1-06")
    if not pair:
        return None
    products, emphasis = pair
    if _selected(answers, "M2V1-03") != ["UNDECIDED"]:
        return None
    if _single(answers, "M2V1-06") not in PRODUCT_EMPHASES:
        return None
    return _candidate(
        "M2V1_PRODUCT_EMPHASIS_UNDECIDED_PRODUCTS", [products, emphasis],
        "M2V1-03 declares the product range undecided, while M2V1-06 emphasises "
        "product quality or a distinctive product theme, which presupposes a decided range.",
        "This does not show the concept is unviable, and it does not resolve which "
        "products should be offered.",
        "Decide whether the product range or the emphasis is the current position; "
        "only you can save a correction. M2 is not rewritten.")


def product_preference_undecided(answers: dict[str, dict]) -> dict | None:
    """Wanting to compare 'planned products' while no products are planned."""
    pair = _pair(answers, "M2V1-03", "M2V1-09")
    if not pair:
        return None
    products, topics = pair
    if _selected(answers, "M2V1-03") != ["UNDECIDED"]:
        return None
    if "PRODUCT_PREFERENCE" not in (_selected(answers, "M2V1-09") or []):
        return None
    return _candidate(
        "M2V1_PRODUCT_PREFERENCE_UNDECIDED_PRODUCTS", [products, topics],
        "M2V1-09 asks to investigate preferences between planned products, but M2V1-03 "
        "declares that no product range has been decided.",
        "This does not establish that customer preference research is inappropriate; "
        "it only notes that the stimulus has no defined products yet.",
        "Decide the product range before that preference question can be specified, "
        "or change the investigation topic. M2 is not rewritten.")


def segment_interest_undecided_groups(answers: dict[str, dict]) -> dict | None:
    """Wanting to measure interest among an 'intended group' that is undecided."""
    pair = _pair(answers, "M2V1-04", "M2V1-09")
    if not pair:
        return None
    groups, topics = pair
    if _selected(answers, "M2V1-04") != ["UNDECIDED"]:
        return None
    if "SEGMENT_INTEREST" not in (_selected(answers, "M2V1-09") or []):
        return None
    return _candidate(
        "M2V1_SEGMENT_INTEREST_UNDECIDED_GROUPS", [groups, topics],
        "M2V1-09 asks to investigate interest among the intended customer group, but "
        "M2V1-04 declares that no customer group has been decided.",
        "This does not show that no group would be interested, and it does not "
        "identify a population for measurement.",
        "Decide the intended customer group before that question can be specified. "
        "M2 is not rewritten.")


def delivery_with_on_premise_occasion(answers: dict[str, dict]) -> dict | None:
    """A seating-dependent occasion declared under a delivery-only format.

    Not structurally prevented: ``rules.not_applicable_when`` only *permits*
    NOT_APPLICABLE when M2V1-02 is DELIVERY; it does not forbid ANSWERED.
    """
    pair = _pair(answers, "M2V1-02", "M2V1-07")
    if not pair:
        return None
    service, occasion = pair
    if _single(answers, "M2V1-02") != "DELIVERY":
        return None
    if _single(answers, "M2V1-07") not in ON_PREMISE_OCCASIONS:
        return None
    return _candidate(
        "M2V1_DELIVERY_WITH_ON_PREMISE_OCCASION", [service, occasion],
        "M2V1-02 declares a delivery-only service format, while M2V1-07 declares an "
        "occasion that requires customers to occupy the premises.",
        "This does not show delivery is unsuitable; the occasion may be aspirational "
        "or a later format change may be intended.",
        "Decide whether the service format or the occasion is the current position. "
        "M2 is not rewritten.")


RULES = (product_emphasis_undecided, product_preference_undecided,
         segment_interest_undecided_groups, delivery_with_on_premise_occasion)


def evaluate_candidate_issues(answers: dict[str, dict]) -> list[dict]:
    """Return only evidence-traceable, conservative candidate issue records."""
    return [candidate for rule in RULES if (candidate := rule(answers)) is not None]


def interpretation_notices(answers: dict[str, dict]) -> list[dict]:
    """Caveats for declared M2V1 information; NOT defect findings."""
    notices = []
    labels = (
        ("M2V1-08", "NO_CUSTOMER_INFORMATION_DECLARED",
         "The entrepreneur declares no customer information yet; this is a starting "
         "position, not a finding against the concept."),
        ("M2V1-11", "RESEARCH_POSITION_DECLARED",
         "The stated research position is an entrepreneur intention, not a measurement "
         "requirement or evidence of demand."),
    )
    for key, code, meaning in labels:
        answer = _answered(answers, key)
        if answer is not None:
            notices.append({"notice_id": code, "source_item_key": key,
                            "source_answer_revision_id": str(answer["id"]),
                            "evidence_class": "ENTREPRENEUR_DECLARED",
                            "text": meaning, "finding": False})
    return notices
