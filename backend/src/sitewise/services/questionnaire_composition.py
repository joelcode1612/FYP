"""Shared composition of the Stage 5 questionnaire.

One composition path
--------------------
Before this module there were two ways to think about "the questionnaire": the
Stage 4 preview endpoint assembled the fixed core inline, and Stage 5 had no
composed view at all. Two builders drift. This module is the only place the
document is assembled, and both the Stage 4 preview and the Stage 5 retrieval
route call it.

What "composed" means here
--------------------------
The composed document has exactly two sections and no others:

``A_FIXED_CORE``
    The 13 governed Q01-Q13, populated from the owner's own M2 declarations by
    :mod:`sitewise.cq_successor.preview_catalogue`. Review controls are ``NONE``
    because the fixed core is not individually reviewable -- what it needs is a
    scientific approval recorded elsewhere.

``B_ADDITIONAL``
    Questions generated for an *admitted* objective and individually approved by
    the owner. Review controls are ``PER_ITEM``. An item appears here only when
    every eligibility predicate below holds.

Eligibility is a conjunction, not a preference
----------------------------------------------
A candidate becomes an additional question only when **all** of the following
hold. Each failing predicate is reported with its own reason code, so an empty
Section B can always be explained:

============================  ==========================================
predicate                     failure code
============================  ==========================================
owner decision APPROVE_FOR_REVIEW  ``CANDIDATE_NOT_APPROVED``
``candidate_state`` VALIDATED      ``CANDIDATE_NOT_VALIDATED``
structural/semantic/provenance affirmative ``CANDIDATE_VALIDATION_NOT_PASS``
raised against the current revision ``CANDIDATE_STALE_REVISION``
carries wording                    ``CANDIDATE_WORDING_MISSING``
carries >= 2 usable options        ``CANDIDATE_OPTIONS_UNUSABLE``
============================  ==========================================

"Affirmative" is not one string. The generator records
``STRUCTURALLY_VALID`` / ``UNDER_REVIEW`` / ``SOURCE_BOUND`` and the older
fixtures recorded ``PASS`` three times, so :func:`status_verdicts` maps both
vocabularies and reports which basis satisfied the semantic disposition. See
the vocabulary block below for why the owner's review is the only reachable
semantic basis for a generated candidate.

Authority
---------
Nothing here grants any. Every item and the document itself pin
``fielding_authorized``, ``publication_authorized`` and
``scientifically_accepted`` to False. Publication and customer fielding stay
disabled, and a caller cannot infer otherwise from a composed document.
"""
from __future__ import annotations

from typing import Any, Iterable, Mapping, Sequence

from sqlalchemy import text

from sitewise.cq_successor.preview_catalogue import (
    COMPLETE,
    PARTIAL_UNRESOLVED,
    PopulatedCatalogue,
)
from sitewise.services.questionnaire_validation import validate_composition

CONTRACT_VERSION = 'sitewise-questionnaire-composition/1'

SECTION_FIXED = 'A_FIXED_CORE'
SECTION_ADDITIONAL = 'B_ADDITIONAL'

#: Composition verdicts. ``INVALID`` means the document contradicts itself;
#: it never means "not authorised" -- authority is a separate axis and is
#: always negative here.
VALID = 'VALID'
INVALID = 'INVALID'

#: Additional-section availability, so a reader can tell "no question was ever
#: generated" from "questions exist but none is approved".
ADDITIONAL_NONE_ELIGIBLE = 'NONE_ELIGIBLE'
ADDITIONAL_AVAILABLE = 'AVAILABLE'

# -- requirement codes ------------------------------------------------------
REQ_SLOT_UNRESOLVED = 'FIXED_CORE_SLOT_UNRESOLVED'
REQ_NO_ADDITIONAL = 'NO_ELIGIBLE_ADDITIONAL_QUESTION'
REQ_VALIDATION_FAILED = 'QUESTIONNAIRE_VALIDATION_FAILED'
REQ_NO_ADMITTED_OBJECTIVE = 'NO_ADMITTED_OBJECTIVE'

# -- exclusion codes --------------------------------------------------------
EX_NOT_APPROVED = 'CANDIDATE_NOT_APPROVED'
EX_NOT_VALIDATED = 'CANDIDATE_NOT_VALIDATED'
EX_VALIDATION_NOT_PASS = 'CANDIDATE_VALIDATION_NOT_PASS'
EX_STALE_REVISION = 'CANDIDATE_STALE_REVISION'
EX_WORDING_MISSING = 'CANDIDATE_WORDING_MISSING'
EX_OPTIONS_UNUSABLE = 'CANDIDATE_OPTIONS_UNUSABLE'

_APPROVE = 'APPROVE_FOR_REVIEW'

# -- validation vocabularies ------------------------------------------------
#
# Two vocabularies describe the same three dispositions, and comparing them by
# string equality is how a *generated* candidate silently became ineligible:
#
# ``qg_candidate_adapter`` writes what it actually established --
# ``STRUCTURALLY_VALID`` / ``UNDER_REVIEW`` / ``SOURCE_BOUND`` -- because a
# schema validator cannot claim semantic review. The earlier fixtures wrote
# ``PASS`` in all three columns by hand, so the gate looked satisfied while no
# code path could satisfy it.
#
# Mapping both vocabularies explicitly, once, is the fix. Loosening the gate is
# not: an affirmative verdict is still required for all three dispositions.
STRUCTURAL_AFFIRMATIVE = frozenset({'PASS', 'STRUCTURALLY_VALID'})
PROVENANCE_AFFIRMATIVE = frozenset({'PASS', 'SOURCE_BOUND'})

#: The only value that means an independent validator established semantics.
SEMANTIC_VALIDATOR_PASS = 'PASS'
#: The adapter's honest "not established yet" value.
SEMANTIC_UNDER_REVIEW = 'UNDER_REVIEW'

#: How a Section B item's semantic disposition was satisfied. Reported on the
#: item so a reader can tell an independent validator verdict from the owner's
#: own recorded review, instead of both being flattened into "PASS".
SEMANTIC_BASIS_VALIDATOR = 'VALIDATOR_PASS'
SEMANTIC_BASIS_OWNER_REVIEW = 'OWNER_REVIEW'
SEMANTIC_BASES = (SEMANTIC_BASIS_VALIDATOR, SEMANTIC_BASIS_OWNER_REVIEW)

#: Declarations that populate the fixed core's slots. One query, two items,
#: because both are needed to decide whether the wording is complete.
_DECLARATIONS_SQL = """
    SELECT DISTINCT ON (iv.item_key)
           iv.item_key, ar.answer_state, ar.value_json
      FROM public.m2_answer_revisions ar
      JOIN public.m2_item_versions iv ON iv.id = ar.item_version_id
     WHERE ar.assessment_id = :assessment_id
       AND ar.assessment_revision <= :revision
       AND iv.item_key IN ('M2V2-01', 'M2V2-14')
     ORDER BY iv.item_key, ar.assessment_revision DESC
"""

_CONTEXT_SQL = """
    SELECT context_id, packet_json, packet_hash, concept_version
      FROM public.m2_business_contexts
     WHERE assessment_id = :assessment_id
       AND confirmation_id = :confirmation_id
       AND assessment_revision = :revision
       AND lifecycle_status = 'PERSISTED'
     ORDER BY created_at DESC
     LIMIT 1
"""

#: DD-093 Option A. The authoritative context is the one the build receipt
#: names, not simply the newest row.
#:
#: ``m2_business_contexts`` accumulates a row per build, and several can be
#: PERSISTED at the same (assessment, confirmation, revision) — a retry, a
#: contract change, or a deliberate re-build all append. Selecting
#: ``ORDER BY created_at DESC`` therefore makes "current" a function of wall
#: clock rather than of what the workflow actually produced, and a single stray
#: packet silently outranks the one the receipt recorded.
#:
#: ``m2_business_context_builds`` holds one row per confirmation (PRIMARY KEY
#: confirmation_id) and names the ``context_id`` that build produced. That is
#: the receipt, so it is the authority. This join is read-only and never
#: rewrites either table, so every historical context row is preserved.
_CONTEXT_FROM_RECEIPT_SQL = """
    SELECT c.context_id, c.packet_json, c.packet_hash, c.concept_version
      FROM public.m2_business_context_builds b
      JOIN public.m2_business_contexts c
        ON c.context_id = b.context_id
     WHERE b.confirmation_id = :confirmation_id
       AND b.assessment_id = :assessment_id
       AND b.assessment_revision = :revision
       AND b.status = 'PERSISTED'
       AND c.assessment_id = :assessment_id
       AND c.confirmation_id = :confirmation_id
       AND c.assessment_revision = :revision
       AND c.lifecycle_status = 'PERSISTED'
     LIMIT 1
"""


def resolve_current_context(session, *, assessment_id, confirmation_id,
                            revision: int):
    """The context this confirmation's build receipt names.

    Falls back to the newest persisted row **only** when no receipt exists —
    a confirmation built before the receipt table was introduced. The fallback
    is a compatibility path, not an alternative authority, so a receipt always
    wins even when a newer packet exists.
    """
    params = {'assessment_id': str(assessment_id),
              'confirmation_id': str(confirmation_id),
              'revision': revision}
    from_receipt = session.execute(
        text(_CONTEXT_FROM_RECEIPT_SQL), params).mappings().first()
    if from_receipt is not None:
        return from_receipt
    return session.execute(text(_CONTEXT_SQL), params).mappings().first()


def load_declarations(session, *, assessment_id, revision: int,
                      confirmation_id=None) -> dict:
    """Read the owner's declarations and business context for one revision.

    Read-only, owner-scoped by the caller's RLS session. Returns the raw values;
    :func:`sitewise.cq_successor.preview_catalogue.build_slot_values` turns them
    into slot text, so formatting stays in one place.
    """
    params = {'assessment_id': str(assessment_id), 'revision': revision}
    rows = session.execute(text(_DECLARATIONS_SQL), params).mappings().all()
    by_item = {r['item_key']: r for r in rows}

    study_area = None
    area_row = by_item.get('M2V2-01')
    if area_row is not None and area_row['answer_state'] == 'ANSWERED':
        study_area = area_row['value_json']

    priced_offer = None
    offer_row = by_item.get('M2V2-14')
    if offer_row is not None and offer_row['answer_state'] == 'ANSWERED':
        priced_offer = offer_row['value_json']

    context = None
    if confirmation_id is not None:
        context = resolve_current_context(
            session, assessment_id=assessment_id,
            confirmation_id=confirmation_id, revision=revision)

    concept_version = None
    if context is not None:
        packet = context['packet_json'] or {}
        concept = packet.get('concept') if isinstance(packet, dict) else None
        if isinstance(concept, dict):
            concept_version = concept.get('version')
        concept_version = concept_version or context['concept_version']

    return {
        'study_area': study_area,
        'priced_offer': priced_offer,
        'concept_version': concept_version,
        'context': dict(context) if context is not None else None,
    }


def _options(candidate: Mapping) -> list[dict]:
    raw = candidate.get('options') or []
    out: list[dict] = []
    for row in raw:
        if not isinstance(row, Mapping):
            continue
        code = str(row.get('code') or '').strip()
        if not code:
            continue
        out.append({
            'code': code,
            'label': str(row.get('label') or '').strip(),
            'order': row.get('order'),
            'order_source': row.get('order_source'),
        })
    return out


def status_verdicts(candidate: Mapping) -> tuple[bool, str | None, str | None]:
    """``(affirmative, reason_code, semantic_basis)`` for one candidate.

    The candidate row is append-only, so a generator cannot raise its own
    disposition after the fact. The three dispositions therefore have to be read
    in their own vocabularies, and the semantic one has exactly two reachable
    affirmative forms:

    ``VALIDATOR_PASS``
        An independent validator recorded ``PASS``. Nothing in this codebase
        writes that today; it is kept so a real validator can.

    ``OWNER_REVIEW``
        The adapter recorded ``UNDER_REVIEW`` and the owner has since recorded
        ``APPROVE_FOR_REVIEW``. The review row is the only mutable record of the
        semantic judgement, so it is the only reachable basis for a generated
        candidate. It is accepted here *because* ``classify_candidate`` has
        already established the decision, and it is reported as its own basis
        rather than being flattened into ``PASS``.

    Structural and provenance dispositions have no owner-review substitute: a
    document that does not trace to confirmed facts is not made admissible by
    anybody's approval.
    """
    if str(candidate.get('structural_status') or '') not in STRUCTURAL_AFFIRMATIVE:
        return False, EX_VALIDATION_NOT_PASS, None
    if str(candidate.get('provenance_status') or '') not in PROVENANCE_AFFIRMATIVE:
        return False, EX_VALIDATION_NOT_PASS, None
    semantic = str(candidate.get('semantic_status') or '')
    if semantic == SEMANTIC_VALIDATOR_PASS:
        return True, None, SEMANTIC_BASIS_VALIDATOR
    if semantic == SEMANTIC_UNDER_REVIEW:
        review = candidate.get('review') or {}
        if review.get('decision') == _APPROVE:
            return True, None, SEMANTIC_BASIS_OWNER_REVIEW
    return False, EX_VALIDATION_NOT_PASS, None


def classify_candidate(candidate: Mapping, *, revision: int) -> tuple[bool, str | None]:
    """Decide whether one persisted candidate may enter Section B.

    Returns ``(eligible, reason_code)``. The reason code is the *first* failing
    predicate in a fixed order, so the same candidate always reports the same
    reason and a test can assert it exactly.
    """
    review = candidate.get('review') or {}
    if review.get('decision') != _APPROVE:
        return False, EX_NOT_APPROVED
    if str(candidate.get('candidate_state') or '') != 'VALIDATED':
        return False, EX_NOT_VALIDATED
    affirmative, reason, _basis = status_verdicts(candidate)
    if not affirmative:
        return False, reason
    if candidate.get('assessment_revision') != revision:
        # A judgement about a superseded revision is not a judgement about the
        # question the owner is looking at now.
        return False, EX_STALE_REVISION
    if not str(candidate.get('question') or '').strip():
        return False, EX_WORDING_MISSING
    if len(_options(candidate)) < 2:
        return False, EX_OPTIONS_UNUSABLE
    return True, None


def build_additional_item(candidate: Mapping, *, order: int) -> dict:
    """One approved candidate as a Section B item.

    ``item_id`` is the candidate id: the candidate row is the single
    authoritative record of this wording, and a second identifier would let the
    two drift apart.
    """
    review = candidate.get('review') or {}
    _affirmative, _reason, basis = status_verdicts(candidate)
    return {
        'item_id': str(candidate.get('candidate_id')),
        'section': SECTION_ADDITIONAL,
        'display_order': order,
        'source': 'QG_CANDIDATE',
        'stem': str(candidate.get('question') or ''),
        'response_format': candidate.get('response_format'),
        'options': _options(candidate),
        'objective_id': candidate.get('objective_id'),
        'objective_admission_id': candidate.get('objective_admission_id'),
        'measurement_id': candidate.get('measurement_id'),
        'measurement_version': candidate.get('measurement_version'),
        'review_decision': review.get('decision'),
        'review_recorded_at': review.get('recorded_at'),
        # The owner's *intended* answer, entrepreneur-only metadata. It is not a
        # respondent answer, is never written to a customer-response table, and
        # must never be preselected in a respondent-facing questionnaire or read
        # by an EE-01 measurement.
        'owner_intended_option': review.get('expected_option_code'),
        'owner_intended_option_scope': 'ENTREPRENEUR_ONLY_METADATA',
        'candidate_state': candidate.get('candidate_state'),
        'structural_status': candidate.get('structural_status'),
        'semantic_status': candidate.get('semantic_status'),
        'provenance_status': candidate.get('provenance_status'),
        # Which reachable basis satisfied the semantic disposition:
        # VALIDATOR_PASS (an independent validator said PASS) or OWNER_REVIEW
        # (the adapter left it UNDER_REVIEW and the owner recorded the review).
        # Stated rather than flattened into "PASS", so a reader can see how much
        # of the validation actually happened.
        'semantic_basis': basis,
        'execution_mode': candidate.get('execution_mode'),
        'dispatched': candidate.get('dispatched'),
        'unresolved_slots': [],
        # A composed item never carries authority, whatever the candidate said.
        'approval_state': 'NOT_APPROVED',
        'fielding_authorized': False,
        'publication_authorized': False,
        'scientifically_accepted': False,
        'review_controls': 'PER_ITEM',
    }


def _fixed_item(populated_question, order: int) -> dict:
    body = populated_question.as_dict()
    return {
        'item_id': body['question_id'],
        'section': SECTION_FIXED,
        'display_order': order,
        'source': 'GOVERNED_CORE',
        'stem': body['populated_stem'],
        'stem_template': body['stem_template'],
        'response_format': body['response_type'],
        'options': [{'code': code, 'label': ''} for code in body['codes']],
        'construct': body['construct'],
        'question_class': body['question_class'],
        'measurement_status': body['measurement_status'],
        'approval_state': body['approval_state'],
        'authority_to_activate': body['authority_to_activate'],
        'population_status': body['population_status'],
        'unresolved_slots': body['unresolved_slots'],
        'fielding_authorized': False,
        'publication_authorized': False,
        'scientifically_accepted': False,
        'review_controls': 'NONE',
    }


def _sort_key(candidate: Mapping) -> tuple:
    """Deterministic order: objective, then creation, then id."""
    return (
        str(candidate.get('objective_id') or ''),
        str(candidate.get('created_at') or ''),
        str(candidate.get('candidate_id') or ''),
    )


def compose(*, populated: PopulatedCatalogue,
            candidates: Iterable[Mapping],
            assessment_id: str,
            confirmation_id: str | None,
            revision: int,
            declarations: Mapping | None = None,
            admitted_objective_count: int | None = None) -> dict:
    """Assemble the composed questionnaire. Pure: no I/O, no clock.

    ``candidates`` is every persisted candidate for the assessment; the
    eligibility filter happens here so that exclusions are reported rather than
    silently dropped.
    """
    fixed_items = [
        _fixed_item(q, order)
        for order, q in enumerate(populated.questions, start=1)
    ]

    additional_items: list[dict] = []
    excluded: list[dict] = []
    for candidate in sorted(candidates, key=_sort_key):
        eligible, reason = classify_candidate(candidate, revision=revision)
        if eligible:
            additional_items.append(
                build_additional_item(
                    candidate,
                    order=len(fixed_items) + len(additional_items) + 1,
                )
            )
        else:
            excluded.append({
                'candidate_id': str(candidate.get('candidate_id')),
                'objective_id': candidate.get('objective_id'),
                'reason': reason,
                'assessment_revision': candidate.get('assessment_revision'),
            })

    items = fixed_items + additional_items

    # -- unresolved requirements -------------------------------------------
    unresolved: list[dict] = []
    for item in fixed_items:
        for slot in item['unresolved_slots']:
            if not slot.get('required'):
                continue
            unresolved.append({
                'code': REQ_SLOT_UNRESOLVED,
                'scope': SECTION_FIXED,
                'item_id': item['item_id'],
                'slot': slot.get('slot'),
                'source': slot.get('source'),
                'required': True,
                'blocking': True,
                'detail': (
                    f'{item["item_id"]} cannot be fielded until '
                    f'{slot.get("source")} is declared.'
                ),
            })

    if not additional_items:
        # Section B being empty is *reported*, never *blocking*. There are two
        # legitimate questionnaire paths: Path A is the 13 governed core
        # templates on their own, Path B adds eligible approved additional
        # questions. Treating an absent optional section as a release blocker
        # made Path A unpublishable, which turned "no additional question was
        # generated" into a universal prerequisite for publication.
        unresolved.append({
            'code': REQ_NO_ADDITIONAL,
            'scope': SECTION_ADDITIONAL,
            'required': False,
            'blocking': False,
            'detail': (
                'No additional question is eligible. Section B is empty, so the '
                'composed questionnaire is the fixed core only (Path A).'
            ),
        })
        if not admitted_objective_count:
            unresolved.append({
                'code': REQ_NO_ADMITTED_OBJECTIVE,
                'scope': SECTION_ADDITIONAL,
                'required': False,
                'blocking': False,
                'detail': (
                    'No research objective has been admitted for this '
                    'confirmation, so no additional question can be generated. '
                    'This does not prevent publishing the fixed core.'
                ),
            })

    validation = validate_composition(
        items=items, excluded=excluded, unresolved=unresolved,
    )
    if validation['status'] != 'PASS':
        unresolved.append({
            'code': REQ_VALIDATION_FAILED,
            'scope': 'DOCUMENT',
            'required': False,
            'blocking': True,
            'detail': 'The composed document failed its own validation: '
                      + ', '.join(validation['failed_checks']),
        })

    fixed_population = (
        PARTIAL_UNRESOLVED
        if any(r['code'] == REQ_SLOT_UNRESOLVED for r in unresolved)
        else COMPLETE
    )

    return {
        'contract_version': CONTRACT_VERSION,
        'assessment_id': str(assessment_id),
        'confirmation_id': str(confirmation_id) if confirmation_id else None,
        'assessment_revision': revision,
        'sections': [
            {
                'key': SECTION_FIXED,
                'title': 'Fixed core questionnaire',
                'review_controls': 'NONE',
                'item_count': len(fixed_items),
                'items': fixed_items,
            },
            {
                'key': SECTION_ADDITIONAL,
                'title': 'Additional question candidates',
                'review_controls': 'PER_ITEM',
                'item_count': len(additional_items),
                'items': additional_items,
            },
        ],
        'items': items,
        'counts': {
            'fixed_core': len(fixed_items),
            'additional': len(additional_items),
            'total': len(items),
            'approved_fixed_core': sum(
                1 for i in fixed_items if i['approval_state'] == 'APPROVED'
            ),
            'approved_additional': sum(
                1 for i in additional_items
                if i['review_decision'] == _APPROVE
            ),
            'excluded_candidates': len(excluded),
        },
        'composition_status': (
            VALID if validation['status'] == 'PASS' else INVALID
        ),
        'population_status': fixed_population,
        'additional_status': (
            ADDITIONAL_AVAILABLE if additional_items else ADDITIONAL_NONE_ELIGIBLE
        ),
        'unresolved_requirements': unresolved,
        'excluded_candidates': excluded,
        'validation': validation,
        'declarations': dict(declarations or {}),
        # Authority is a separate axis from validity, and it is always negative.
        'fielding_authorized': False,
        'publication_authorized': False,
        'scientifically_accepted': False,
        'customer_fielding_enabled': False,
        'report_release_authorized': False,
    }


__all__ = [
    'ADDITIONAL_AVAILABLE',
    'ADDITIONAL_NONE_ELIGIBLE',
    'CONTRACT_VERSION',
    'EX_NOT_APPROVED',
    'EX_NOT_VALIDATED',
    'EX_OPTIONS_UNUSABLE',
    'EX_STALE_REVISION',
    'EX_VALIDATION_NOT_PASS',
    'EX_WORDING_MISSING',
    'INVALID',
    'REQ_NO_ADDITIONAL',
    'REQ_NO_ADMITTED_OBJECTIVE',
    'REQ_SLOT_UNRESOLVED',
    'REQ_VALIDATION_FAILED',
    'PROVENANCE_AFFIRMATIVE',
    'SECTION_ADDITIONAL',
    'SECTION_FIXED',
    'SEMANTIC_BASES',
    'SEMANTIC_BASIS_OWNER_REVIEW',
    'SEMANTIC_BASIS_VALIDATOR',
    'STRUCTURAL_AFFIRMATIVE',
    'VALID',
    'build_additional_item',
    'classify_candidate',
    'compose',
    'status_verdicts',
    'load_declarations',
]
