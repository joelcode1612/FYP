"""Questionnaire-level validation for the composed Stage 5 document.

Why this module exists
----------------------
Validation already existed at two lower levels and at neither of them was the
*composed document* checked:

* ``measurement_validation`` (MV-01..MV-11) validates a single measurement;
* ``objective_admission_validation`` (OA-01..OA-07) validates one admission.

Neither notices a duplicated stem, a colliding option code, a fixed core that
lost a question, or an item that quietly claims authority. Composition therefore
used to be asserted by construction -- "the code builds it, so it must be fine"
-- which is exactly the kind of claim that stops being true the first time
someone changes the builder.

Scope
-----
This module is **pure**: it takes the already-composed items and returns
verdicts. It performs no I/O, reads no clock and calls no model, so every check
is unit-testable and the same inputs always produce the same report.

What it does not do
-------------------
It does not approve, admit, publish or field anything. A document can be
``VALID`` and still be completely unfieldable: validity here means "internally
consistent and honestly labelled", not "authorised". ``QV-08`` exists precisely
to keep that distinction: any item claiming fielding or publication authority
fails validation rather than passing as ready.
"""
from __future__ import annotations

import re
from typing import Iterable, Mapping, Sequence

CONTRACT_VERSION = 'sitewise-questionnaire-validation/1'

PASS = 'PASS'
FAIL = 'FAIL'
NOT_APPLICABLE = 'NOT_APPLICABLE'

#: The fixed core is exactly these thirteen, in this order. Not a subset and not
#: "at least": a document missing Q07 is a different instrument, not a shorter
#: one, and it must not validate as complete.
FIXED_CORE_IDS: tuple[str, ...] = tuple(f'Q{i:02d}' for i in range(1, 14))

#: Response formats this pipeline can render. The first five are the persisted
#: vocabulary from ``m2_qg_candidates_response_format_check``; the snake_case
#: names are the aliases the Stage 4 frontend still uses. Anything else is
#: reported as unsupported rather than coerced into the nearest known shape.
SUPPORTED_RESPONSE_FORMATS = frozenset({
    'SINGLE_CHOICE',
    'BINARY_CHOICE',
    'MULTIPLE_CHOICE',
    'ORDERED_SCALE',
    'NUMERIC_RANGE_OPTIONS',
    'SINGLE_SELECT',
    'MULTI_SELECT',
    'ORDINAL_SINGLE',
    'ordinal_single',
    'nominal_single',
    'multi_select',
})

_NON_WORD = re.compile(r'[^a-z0-9]+')

#: The two reachable ways a Section B item's semantic disposition is satisfied.
#: Declared here rather than imported from the composition service, because the
#: service imports this module -- and a validator that took its permitted values
#: from the builder could not catch the builder widening them.
SEMANTIC_BASES = frozenset({'VALIDATOR_PASS', 'OWNER_REVIEW'})


def normalize_stem(text: object) -> str:
    """Casefold and strip punctuation so two renderings of one stem collide.

    Deliberately blunt: it is used only to *find* duplicates for a human to
    judge. It never decides that two questions are equivalent for reuse (that is
    BD-01, which requires approval this document does not have).
    """
    if not isinstance(text, str):
        return ''
    return _NON_WORD.sub(' ', text.casefold()).strip()


def _check(check_id: str, title: str, status: str, reason: str = '',
           evidence: Mapping | None = None) -> dict:
    return {
        'check_id': check_id,
        'title': title,
        'status': status,
        'reason_code': reason or None,
        'evidence': dict(evidence or {}),
    }


def _items_by_section(items: Sequence[Mapping]) -> dict[str, list[Mapping]]:
    grouped: dict[str, list[Mapping]] = {}
    for item in items:
        grouped.setdefault(str(item.get('section') or ''), []).append(item)
    return grouped


def validate_composition(*, items: Sequence[Mapping],
                         excluded: Iterable[Mapping] = (),
                         unresolved: Iterable[Mapping] = ()) -> dict:
    """Validate the assembled document as a unit.

    ``items`` are the composed items in render order; each carries at least
    ``item_id``, ``section``, ``stem`` and (for additional items) ``options``.
    ``excluded`` are candidates deliberately left out, and ``unresolved`` are
    the declared unresolved requirements. Both are inputs because a document
    that silently drops either is not honestly described.
    """
    items = list(items)
    excluded = list(excluded)
    unresolved = list(unresolved)
    sections = _items_by_section(items)
    fixed = sections.get('A_FIXED_CORE', [])
    additional = sections.get('B_ADDITIONAL', [])
    checks: list[dict] = []

    # -- QV-01: the fixed core is complete and in governed order -------------
    fixed_ids = [str(i.get('item_id')) for i in fixed]
    missing = [qid for qid in FIXED_CORE_IDS if qid not in fixed_ids]
    duplicated = sorted({qid for qid in fixed_ids if fixed_ids.count(qid) > 1})
    if missing or duplicated or fixed_ids != list(FIXED_CORE_IDS):
        checks.append(_check(
            'QV-01', 'Fixed core holds Q01-Q13 in governed order', FAIL,
            'FIXED_CORE_INCOMPLETE_OR_REORDERED',
            {'expected': list(FIXED_CORE_IDS), 'actual': fixed_ids,
             'missing': missing, 'duplicated': duplicated},
        ))
    else:
        checks.append(_check(
            'QV-01', 'Fixed core holds Q01-Q13 in governed order', PASS,
            evidence={'count': len(fixed_ids)},
        ))

    # -- QV-02: item identity is unique across the whole document -----------
    all_ids = [str(i.get('item_id')) for i in items]
    collisions = sorted({i for i in all_ids if all_ids.count(i) > 1})
    checks.append(_check(
        'QV-02', 'Every item id is unique across both sections',
        FAIL if collisions else PASS,
        'DUPLICATE_ITEM_ID' if collisions else '',
        {'duplicates': collisions, 'total_items': len(all_ids)},
    ))

    # -- QV-03: no two items ask the same thing ------------------------------
    #
    # Duplicates are searched across sections too: an additional question that
    # repeats a governed core stem would double-measure one construct while
    # looking like two data points.
    seen: dict[str, list[str]] = {}
    for item in items:
        key = normalize_stem(item.get('stem'))
        if not key:
            continue
        seen.setdefault(key, []).append(str(item.get('item_id')))
    duplicate_stems = {k: v for k, v in seen.items() if len(v) > 1}
    checks.append(_check(
        'QV-03', 'No two items share a normalised stem',
        FAIL if duplicate_stems else PASS,
        'DUPLICATE_STEM' if duplicate_stems else '',
        {'groups': duplicate_stems},
    ))

    # -- QV-04: additional items carry wording ------------------------------
    blank = [str(i.get('item_id')) for i in additional
             if not str(i.get('stem') or '').strip()]
    checks.append(_check(
        'QV-04', 'Every additional item carries wording',
        NOT_APPLICABLE if not additional else (FAIL if blank else PASS),
        'ADDITIONAL_STEM_MISSING' if blank else '',
        {'blank': blank, 'additional_count': len(additional)},
    ))

    # -- QV-05: additional option sets are usable ---------------------------
    bad_options: list[dict] = []
    for item in additional:
        options = item.get('options') or []
        codes = [str(o.get('code') or '') for o in options if isinstance(o, Mapping)]
        if len(options) < 2:
            bad_options.append({'item_id': item.get('item_id'),
                                'reason': 'FEWER_THAN_TWO_OPTIONS',
                                'count': len(options)})
        elif any(not code for code in codes):
            bad_options.append({'item_id': item.get('item_id'),
                                'reason': 'EMPTY_OPTION_CODE'})
        elif len(set(codes)) != len(codes):
            bad_options.append({'item_id': item.get('item_id'),
                                'reason': 'DUPLICATE_OPTION_CODE',
                                'codes': codes})
    checks.append(_check(
        'QV-05', 'Every additional item has >=2 options with unique codes',
        NOT_APPLICABLE if not additional else (FAIL if bad_options else PASS),
        'ADDITIONAL_OPTIONS_UNUSABLE' if bad_options else '',
        {'failures': bad_options},
    ))

    # -- QV-06: response formats are ones this pipeline can render ----------
    unsupported = [
        {'item_id': item.get('item_id'), 'response_format': item.get('response_format')}
        for item in additional
        if str(item.get('response_format') or '') not in SUPPORTED_RESPONSE_FORMATS
    ]
    checks.append(_check(
        'QV-06', 'Every additional item uses a supported response format',
        NOT_APPLICABLE if not additional else (FAIL if unsupported else PASS),
        'RESPONSE_FORMAT_UNSUPPORTED' if unsupported else '',
        {'unsupported': unsupported},
    ))

    # -- QV-07: unresolved requirements are declared and counted -----------
    declared_required = sum(1 for r in unresolved if r.get('required') is True)
    counted_required = sum(
        1
        for item in items
        for slot in (item.get('unresolved_slots') or [])
        if isinstance(slot, Mapping) and slot.get('required') is True
    )
    checks.append(_check(
        'QV-07', 'Declared unresolved requirements match the items',
        FAIL if declared_required != counted_required else PASS,
        'UNRESOLVED_COUNT_MISMATCH' if declared_required != counted_required else '',
        {'declared_required': declared_required,
         'counted_required': counted_required},
    ))

    # -- QV-08: nothing in the document claims authority -------------------
    claiming = [
        str(item.get('item_id'))
        for item in items
        if item.get('fielding_authorized') is not False
        or item.get('publication_authorized') is not False
    ]
    checks.append(_check(
        'QV-08', 'No item claims fielding or publication authority',
        FAIL if claiming else PASS,
        'ITEM_CLAIMS_AUTHORITY' if claiming else '',
        {'claiming': claiming},
    ))

    # -- QV-09: exclusions are accounted for -------------------------------
    unexplained = [str(c.get('candidate_id')) for c in excluded
                   if not str(c.get('reason') or '').strip()]
    checks.append(_check(
        'QV-09', 'Every excluded candidate carries a reason',
        FAIL if unexplained else PASS,
        'EXCLUSION_UNEXPLAINED' if unexplained else '',
        {'unexplained': unexplained, 'excluded_count': len(excluded)},
    ))

    # -- QV-10: an additional item states how it passed semantic review ------
    #
    # Without this, a builder could accept any status string and the document
    # would still validate. The basis is required to be one of the two reachable
    # ones, so "the generator said UNDER_REVIEW and nobody looked at it" cannot
    # be rendered as a passed item.
    unbased = [
        {'item_id': item.get('item_id'),
         'semantic_basis': item.get('semantic_basis'),
         'semantic_status': item.get('semantic_status')}
        for item in additional
        if str(item.get('semantic_basis') or '') not in SEMANTIC_BASES
    ]
    checks.append(_check(
        'QV-10', 'Every additional item declares a permitted semantic basis',
        NOT_APPLICABLE if not additional else (FAIL if unbased else PASS),
        'SEMANTIC_BASIS_UNDECLARED' if unbased else '',
        {'unbased': unbased},
    ))

    failures = [c for c in checks if c['status'] == FAIL]
    return {
        'contract_version': CONTRACT_VERSION,
        'status': FAIL if failures else PASS,
        'failure_count': len(failures),
        'check_count': len(checks),
        'checks': checks,
        # Named so a reader can see which invariant broke without scanning.
        'failed_checks': [c['check_id'] for c in failures],
    }


__all__ = [
    'CONTRACT_VERSION',
    'FAIL',
    'FIXED_CORE_IDS',
    'NOT_APPLICABLE',
    'PASS',
    'SEMANTIC_BASES',
    'SUPPORTED_RESPONSE_FORMATS',
    'normalize_stem',
    'validate_composition',
]
