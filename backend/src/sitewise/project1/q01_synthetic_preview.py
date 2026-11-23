"""Development-only synthetic preview of the Q01 area-affiliation measurement.

What this module is
-------------------
A frozen, **synthetic** 40-respondent fixture for Q01 that is aggregated into an
EE-01-shaped diagnostic snapshot and then presented through ``chart-spec/1`` in
the ``SYNTHETIC_PREVIEW_ONLY`` render state.

What this module is not
-----------------------
It is not an EE-01 execution, not a fielded measurement, and not report
evidence. It does not touch ``Final_Location_Analysis``, any ``public.*`` table,
or any real respondent record. Nothing here writes to a database.

Provenance honesty
------------------
The snapshot is **constructed by this module**, not produced by
``Ee01Service``. Its ``metadata_json['origin']`` is ``SYNTHETIC_TEST`` and its
``scope`` is ``ISOLATED_TEST`` — the two markers ``chart_spec.from_ee01``
requires before it will chart anything at all. The readback is likewise
assembled here with the same ``digest()`` the writer uses, so
``CHART_READBACK_INTEGRITY_INVALID`` is a real check rather than a bypass.

Because the aggregate is fixture arithmetic rather than an EE-01 run, the
resulting chart's ``source_provenance`` reads ``SYNTHETIC_TEST`` and its
admission block stays ``HELD``. A caller that wants a report-admitted line
cannot get one from this module: ``from_ee01`` refuses to emit
``RENDERABLE``, and ``SYNTHETIC_PREVIEW_ONLY`` refuses to coexist with
``real_reportable``.

Denominator decision (declared, not inferred)
---------------------------------------------
``V`` is **valid answering respondents** (40), not substantive-only answers
(34). The registry's own ``ee01_measurement_rule`` for Q01 states
``formula = 100 * x[code] / V`` with ``denominator = V for this item, version
and stimulus``, and its ``valid`` template reads *"Among {V} valid Q01
respondents, {count} selected {category}."* Six respondents selected only an
exclusive terminal, so a substantive-only denominator would print
*"3 of 34 selected Rarely"* — an assertion the exclusive-terminal rule makes
impossible, because a terminal-only respondent never selected an affiliation.
``V = 40`` is therefore the only internally consistent reading, and
``denominator_scope`` on the emitted chart says so in prose.

Record-first aggregation
------------------------
``_RECORDS`` is the sole source of truth. ``EXPECTED_COUNTS`` exists only to
detect drift; :func:`aggregate_counts` derives the counts from the records and
then *checks* them against the expectation, so an edited record fails loudly
instead of silently changing the chart.
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any

from sitewise.domain.customer_questionnaire import digest as ee01_digest
from sitewise.project1.chart_spec import (
    EE01_DIAGNOSTIC_VERSION,
    EE01_READBACK_VERSION,
    ChartRefused,
    ChartSpec,
    from_ee01,
    percent_of,
)
from sitewise.project1.explanation_registry import (
    fill_item_template,
    load_registry,
)

#: Rendered at the top of every surface that shows this fixture. Long, loud and
#: non-removable: the whole point of the unlock is that nobody mistakes a
#: demonstration for a finding.
PREVIEW_MARKER = 'SYNTHETIC DEMONSTRATION — NOT REPORT EVIDENCE'

#: Secondary line. Names the mechanism, so a reader can audit the claim.
PREVIEW_SUBMARKER = (
    '40 synthetic respondents. No real person, fielded response, customer '
    'database row or authorized measurement is represented here.'
)

SYNTHETIC_ORIGIN = 'SYNTHETIC_TEST'
SYNTHETIC_SCOPE = 'ISOLATED_TEST'
SNAPSHOT_ID = 'snap-q01-synthetic-0001'
FINGERPRINT = 'fp-q01-synthetic-0001'
SYNTHETIC_RUN_ID = 'run-q01-synthetic-0001'
CAMPAIGN_ID = 'campaign-q01-synthetic'
ASSESSMENT_ID = 'assess-q01-synthetic'
CUTOFF = '2026-11-22T09:00:00+00:00'

QUESTION_ID = 'Q01'

#: The frozen instrument contract. Read, never written.
_CUST03_PATH = (Path(__file__).resolve().parents[1] / 'customer_contracts' / 'reference'
                / 'CUST_RECOVERY_20261027'
                / 'CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json')

#: The exclusive terminals, restated so this module does not depend on a
#: registry attribute for its own integrity checks.
EXCLUSIVE_CODES = ('RARELY', 'NEVER', 'NOT_SURE')

#: Funnel. ``S`` is one above ``A`` so a "shown but not answered" unit exists,
#: which keeps the funnel from looking like a degenerate identity. ``V == A``
#: because every answer event here is a valid answer.
Q_UNITS = 44
S_UNITS = 41
A_UNITS = 40

# ---------------------------------------------------------------------------
# The fixture: 40 respondents, one record each.
# ---------------------------------------------------------------------------
#: ``(respondent_id, selected_codes)``. R01-R34 select at least one affiliation;
#: R35-R40 select exactly one exclusive terminal and no affiliation, which is
#: the rule the instrument's ``exclusive_codes`` imposes.
#:
#: Deliberate overlap is concentrated in R12-R19 (LIVE+WORK) and in the
#: STUDY/VISIT_PURPOSE and RUN_BUSINESS/PASS_THROUGH pairs, so the rendered bars
#: show genuinely overlapping categories rather than a partition.
_RECORDS: tuple[tuple[str, tuple[str, ...]], ...] = (
    # --- affiliation only, single selection (11 records) -------------------
    ('R01', ('LIVE',)),
    ('R02', ('LIVE',)),
    ('R03', ('LIVE',)),
    ('R04', ('LIVE',)),
    ('R05', ('LIVE',)),
    ('R06', ('LIVE',)),
    ('R07', ('LIVE',)),
    ('R08', ('WORK',)),
    ('R09', ('WORK',)),
    ('R10', ('WORK',)),
    ('R11', ('WORK',)),
    # --- LIVE + WORK overlap (8 records) ----------------------------------
    ('R12', ('LIVE', 'WORK')),
    ('R13', ('LIVE', 'WORK')),
    ('R14', ('LIVE', 'WORK')),
    ('R15', ('LIVE', 'WORK')),
    ('R16', ('LIVE', 'WORK')),
    ('R17', ('LIVE', 'WORK')),
    ('R18', ('LIVE', 'WORK')),
    ('R19', ('LIVE', 'WORK')),
    # --- STUDY, with VISIT_PURPOSE overlap (6 records) --------------------
    ('R20', ('STUDY', 'VISIT_PURPOSE')),
    ('R21', ('STUDY',)),
    ('R22', ('STUDY', 'VISIT_PURPOSE')),
    ('R23', ('STUDY', 'VISIT_PURPOSE')),
    ('R24', ('STUDY', 'VISIT_PURPOSE')),
    ('R25', ('STUDY', 'VISIT_PURPOSE')),
    # --- RUN_BUSINESS, with PASS_THROUGH overlap (4 records) --------------
    ('R26', ('RUN_BUSINESS', 'PASS_THROUGH')),
    ('R27', ('RUN_BUSINESS',)),
    ('R28', ('RUN_BUSINESS', 'PASS_THROUGH')),
    ('R29', ('RUN_BUSINESS', 'PASS_THROUGH')),
    # --- VISIT_PURPOSE / PASS_THROUGH tail (5 records) --------------------
    ('R30', ('VISIT_PURPOSE', 'PASS_THROUGH')),
    ('R31', ('VISIT_PURPOSE', 'PASS_THROUGH')),
    ('R32', ('VISIT_PURPOSE', 'PASS_THROUGH')),
    ('R33', ('VISIT_PURPOSE',)),
    ('R34', ('PASS_THROUGH',)),
    # --- exclusive terminals, sole selection (6 records) ------------------
    ('R35', ('RARELY',)),
    ('R36', ('RARELY',)),
    ('R37', ('RARELY',)),
    ('R38', ('NEVER',)),
    ('R39', ('NEVER',)),
    ('R40', ('NOT_SURE',)),
)

#: Drift detector only. The chart is built from ``_RECORDS``; these values are
#: what those records are *supposed* to aggregate to.
EXPECTED_COUNTS: dict[str, int] = {
    'LIVE': 15,
    'WORK': 12,
    'STUDY': 6,
    'RUN_BUSINESS': 4,
    'VISIT_PURPOSE': 9,
    'PASS_THROUGH': 7,
    'RARELY': 3,
    'NEVER': 2,
    'NOT_SURE': 1,
}

EXPECTED_TOTAL_RESPONDENTS = 40
EXPECTED_EXCLUSIVE_ONLY = 6
EXPECTED_SUBSTANTIVE_RESPONDENTS = 34
#: 15+12+6+4+9+7 — affiliation selections across the 34 affiliation respondents.
EXPECTED_AFFILIATION_SELECTIONS = 53
#: 3+2+1 — one exclusive terminal each, across the 6 terminal-only respondents.
EXPECTED_EXCLUSIVE_SELECTIONS = 6


class SyntheticPreviewRefused(ChartRefused):
    """Fixed code only; never carries fixture prose into a refusal."""


def _question() -> dict:
    """The frozen Q01 item, assembled from the two hash-pinned sources.

    Wording (``stem``, ``type``) comes from the CUST03 contract; codes, labels,
    sections and limitation prose come from the explanation registry, which is
    digest-verified on load. Neither is re-typed here, so the fixture cannot
    drift from the instrument it claims to describe.
    """
    registry = load_registry()
    entry = registry.question(QUESTION_ID)
    if entry is None:
        raise SyntheticPreviewRefused('SYNTHETIC_PREVIEW_QUESTION_ABSENT', 503)
    contract = _contract_item()
    return {
        'id': QUESTION_ID,
        'construct': entry.construct_id,
        'stem': contract['stem'],
        'type': contract['type'],
        'codes': list(entry.codes),
        'substantive_codes': list(entry.substantive_codes),
        'exclusive_codes': list(contract.get('exclusive_codes') or EXCLUSIVE_CODES),
        'display_order': list(contract.get('display_order') or entry.codes),
        'ordinal_meaning': dict(contract.get('ordinal_meaning') or {}),
        'report_sections': list(entry.report_sections),
        'coverage_limitation': entry.coverage_limitation,
        'forbidden_inference': entry.prohibited_inference,
        'numerator_rule': {},
    }


@lru_cache(maxsize=1)
def _contract_item() -> dict:
    """Q01 as declared in the frozen CUST03 contract."""
    path = _CUST03_PATH
    if not path.exists():
        raise SyntheticPreviewRefused('SYNTHETIC_PREVIEW_CONTRACT_MISSING', 503)
    contract = json.loads(path.read_text(encoding='utf-8'))
    for item in contract.get('items', []):
        if item.get('id') == QUESTION_ID:
            return item
    raise SyntheticPreviewRefused('SYNTHETIC_PREVIEW_QUESTION_ABSENT', 503)


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------

def aggregate_counts(records: tuple[tuple[str, tuple[str, ...]], ...] | None = None
                     ) -> dict[str, int]:
    """Count selections per code **from the records**, then verify the total.

    The counts are derived, never declared: editing a record changes the chart.
    The ``EXPECTED_COUNTS`` comparison is the drift alarm, and it runs here so
    every caller — generator script, test, or future adapter — inherits it.
    """
    rows = _RECORDS if records is None else records
    counts: dict[str, int] = {code: 0 for code in EXPECTED_COUNTS}
    for respondent_id, selected in rows:
        if not selected:
            raise SyntheticPreviewRefused(
                f'SYNTHETIC_PREVIEW_EMPTY_SELECTION:{respondent_id}', 503)
        for code in selected:
            if code not in counts:
                raise SyntheticPreviewRefused(
                    f'SYNTHETIC_PREVIEW_UNKNOWN_CODE:{respondent_id}', 503)
            counts[code] += 1
    if counts != EXPECTED_COUNTS:
        raise SyntheticPreviewRefused('SYNTHETIC_PREVIEW_COUNT_DRIFT', 503)
    return counts


def respondent_summary(records: tuple[tuple[str, tuple[str, ...]], ...] | None = None
                       ) -> dict[str, int]:
    """Structural facts about the fixture, used by the UI header and by tests."""
    rows = _RECORDS if records is None else records
    exclusive_only = sum(1 for _, selected in rows if set(selected) <= set(EXCLUSIVE_CODES))
    affiliation_codes = set(EXPECTED_COUNTS) - set(EXCLUSIVE_CODES)
    substantive = sum(1 for _, selected in rows if set(selected) & affiliation_codes)
    affiliation_selections = sum(len(set(selected) & affiliation_codes) for _, selected in rows)
    exclusive_selections = sum(len(set(selected) & set(EXCLUSIVE_CODES)) for _, selected in rows)
    summary = {
        'respondents': len(rows),
        'exclusive_only': exclusive_only,
        'substantive_respondents': substantive,
        'affiliation_selections': affiliation_selections,
        'exclusive_selections': exclusive_selections,
        'selections': affiliation_selections + exclusive_selections,
        # Every affiliation selection beyond the first in a respondent is an
        # overlap. Reported because "counts sum above V" needs a number.
        'overlap_selections': affiliation_selections - substantive,
    }
    expected = {
        'respondents': EXPECTED_TOTAL_RESPONDENTS,
        'exclusive_only': EXPECTED_EXCLUSIVE_ONLY,
        'substantive_respondents': EXPECTED_SUBSTANTIVE_RESPONDENTS,
        'affiliation_selections': EXPECTED_AFFILIATION_SELECTIONS,
        'exclusive_selections': EXPECTED_EXCLUSIVE_SELECTIONS,
        'selections': EXPECTED_AFFILIATION_SELECTIONS + EXPECTED_EXCLUSIVE_SELECTIONS,
        'overlap_selections': EXPECTED_AFFILIATION_SELECTIONS - EXPECTED_SUBSTANTIVE_RESPONDENTS,
    }
    if summary != expected:
        raise SyntheticPreviewRefused('SYNTHETIC_PREVIEW_STRUCTURE_DRIFT', 503)
    return summary


# ---------------------------------------------------------------------------
# EE-01-shaped snapshot and readback
# ---------------------------------------------------------------------------

def build_snapshot(records: tuple[tuple[str, tuple[str, ...]], ...] | None = None,
                   *, empty: bool = False) -> dict[str, Any]:
    """Assemble an EE-01 diagnostic snapshot in the shape ``_read`` returns.

    Datetimes are strings and ``Decimal`` values are absent, matching what
    ``plain()`` produces. Every cell carries ``v == V`` because EE-01 stores one
    denominator per snapshot; a per-cell denominator would be a different fault.

    ``empty=True`` produces the ``NOT_ESTIMABLE`` variant: the same 40 answer
    events, but no substantive answer survives, so ``V == 0`` and no share may be
    emitted. It exists so the UI and the tests can contrast a withheld
    denominator against the preview, on identical wording and identical labels.
    """
    counts = aggregate_counts(records)
    question = _question()
    V = 0 if empty else A_UNITS
    cells = [
        {'code': code,
         'x': 0 if empty else int(counts[code]),
         'v': V,
         'percentage': None,
         'diagnostic_percentage': None,
         'status': 'NOT_ESTIMABLE' if empty else 'WITHHELD_NOT_AUTHORIZED'}
        for code in question['display_order'] if code in counts
    ]
    return {
        'contract_version': EE01_DIAGNOSTIC_VERSION,
        'id': f'{SNAPSHOT_ID}-not-estimable' if empty else SNAPSHOT_ID,
        'owner_user_id': 'synthetic-owner-0001',
        'assessment_id': ASSESSMENT_ID,
        'campaign_id': CAMPAIGN_ID,
        'release_id': 'release-q01-synthetic',
        'slot_id': QUESTION_ID,
        'question_version': 'q01-v1-SYNTHETIC',
        'cutoff': CUTOFF,
        'fingerprint': f'{FINGERPRINT}-not-estimable' if empty else FINGERPRINT,
        'rules_hash': 'rules-q01-synthetic',
        'source_hash': 'source-q01-synthetic',
        'scope': SYNTHETIC_SCOPE,
        'status': 'NOT_ESTIMABLE' if empty else 'WITHHELD_NOT_AUTHORIZED',
        'q': Q_UNITS, 's': S_UNITS, 'a': A_UNITS, 'v': V,
        'metadata_json': {
            'manifest_hash': 'manifest-q01-synthetic',
            'instrument_version': 'P3-01C-VNEXT-0.6.1-CUST-REC',
            'bank_version': 'option-bank-q01-SYNTHETIC-PREVIEW',
            'routing_version': 'routing-q01-synthetic',
            'consent_version': 'consent-q01-synthetic',
            'stimulus_hash': 'stimulus-q01-synthetic',
            'qualification_versions': ['qual-q01-synthetic'],
            'research_mode': 'DEVELOPER_PREVIEW',
            'rule': 'ACCEPTED_EFFECTIVE_DIAGNOSTIC',
            'authority': 'AUTHORITY_UNVERIFIED',
            'privacy_policy': 'WITHHOLD_ALL_FINDINGS',
            'selection': 'LATEST_ACCEPTED',
            'cutoff_basis': 'COMMITTED_BUILD_SNAPSHOT_WITH_EVENT_TIME_CUTOFF',
            'scientific_gaps': ['A_DEFINITION_UNRESOLVED', 'REVISION_POLICY_UNVERIFIED',
                                'MEASUREMENT_CLAIM_UNAUTHORIZED'],
            'origin': SYNTHETIC_ORIGIN,
            'synthetic_run_id': SYNTHETIC_RUN_ID,
            'consent_semantics': 'SIMULATED_NONHUMAN_NOT_INFORMED_CONSENT',
            'real_reportable': False,
            'diagnostic_qualification': 'TEST_ONLY_REPLAY_OF_FROZEN_FIXTURE_PREDICATES',
        },
        'counts_json': {**{k: (0 if empty else v) for k, v in counts.items()},
                        'not_shown': S_UNITS - A_UNITS, 'excluded': 0},
        'cells': cells,
    }


def build_readback(snapshot: dict[str, Any] | None = None) -> dict[str, Any]:
    """Assemble the held readback the way ``_store_held_context`` writes it.

    ``context_hash`` is computed with the writer's own ``digest`` so
    ``from_ee01``'s integrity check is exercised rather than satisfied by
    construction.
    """
    snap = build_snapshot() if snapshot is None else snapshot
    context = {
        'snapshot_id': snap['id'],
        'fingerprint': snap['fingerprint'],
        'assessment_id': snap['assessment_id'],
        'campaign_id': snap['campaign_id'],
        'source_hash': snap['source_hash'],
        'rules_hash': snap['rules_hash'],
        'authority': 'AUTHORITY_UNVERIFIED',
        'findings': [],
        'gates': ['EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED',
                  'A10_ADAPTER_UNVERIFIED',
                  'REPORT_ADMISSION_REQUIRED',
                  'SYNTHETIC_DATA_NOT_REPORTABLE'],
        'origin': SYNTHETIC_ORIGIN,
        'synthetic_run_id': SYNTHETIC_RUN_ID,
        'real_reportable': False,
    }
    return {
        'contract_version': EE01_READBACK_VERSION,
        'status': 'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE',
        'context_hash': ee01_digest(context),
        'context': context,
        'findings': [],
    }


# ---------------------------------------------------------------------------
# Chart and narrative
# ---------------------------------------------------------------------------

_LIMITATION = (
    'Synthetic preview only. Forty fabricated respondents, aggregated by fixture '
    'arithmetic rather than by an EE-01 execution. No fielded response, no '
    'consent event and no real person is represented. Affiliation categories '
    'overlap, so counts sum above V; they are not a partition and not a census '
    'of residents. RARELY, NEVER and NOT_SURE are exclusive alternatives, '
    'counted separately and never treated as eligible or ineligible. Q01 has no '
    'declared numerator (Q01-NR-DEFAULT), so the shares shown are the mechanical '
    '100*x/V demonstration and are not an authorized distribution.'
)

#: Replaces ``from_ee01``'s default sentence, which names V as *substantive*
#: answers. Q01 counts six valid answers that select only an exclusive terminal,
#: so the default would misdescribe its own denominator.
_DENOMINATOR_SCOPE = (
    'V = 40 valid Q01 answers at this version and stimulus, including 6 who '
    'selected only an exclusive alternative; affiliations overlap and sum to 53'
)


def build_chart(*, allow_synthetic: bool = False,
                state: str = 'SYNTHETIC_PREVIEW_ONLY') -> ChartSpec:
    """Build a Q01 chart in one of three presentation states.

    ``allow_synthetic`` must be passed explicitly. The default refusal means no
    import-time side effect and no accidental construction from a code path that
    did not intend to build a demonstration.

    ``state`` selects which contrast the caller wants, all from the same records
    and the same wording:

    ``SYNTHETIC_PREVIEW_ONLY``
        Counts and shares are shown, under the development-only state. The
        admission block is still ``HELD``.
    ``WITHHELD_NOT_AUTHORIZED``
        The production default. Identical counts, no counts and no shares
        disclosed — this is what R08 shows today.
    ``NOT_ESTIMABLE``
        ``V == 0``. No denominator, therefore no share at all.
    """
    if not allow_synthetic:
        raise SyntheticPreviewRefused('SYNTHETIC_PREVIEW_NOT_ENABLED', 422)
    if state not in ('SYNTHETIC_PREVIEW_ONLY', 'WITHHELD_NOT_AUTHORIZED',
                     'NOT_ESTIMABLE'):
        raise SyntheticPreviewRefused('SYNTHETIC_PREVIEW_STATE_UNKNOWN', 422)

    empty = state == 'NOT_ESTIMABLE'
    snapshot = build_snapshot(empty=empty)
    readback = build_readback(snapshot)
    question = _question()
    registry = load_registry()
    entry = registry.question(QUESTION_ID)
    if entry is None:
        raise SyntheticPreviewRefused('SYNTHETIC_PREVIEW_QUESTION_ABSENT', 503)
    return from_ee01(
        snapshot, readback, question,
        title='Area connection — synthetic preview',
        limitation=_LIMITATION,
        labels=dict(entry.labels),
        render_state_override=(None if empty or state == 'WITHHELD_NOT_AUTHORIZED'
                               else 'SYNTHETIC_PREVIEW_ONLY'),
        denominator_scope=None if empty else _DENOMINATOR_SCOPE,
    )


def build_explanation(chart: ChartSpec | None = None) -> dict[str, Any]:
    """Deterministic narrative built from verified counts and registry wording.

    The prose is the registry's own ``valid`` template (``VD-Q01-APPROVED``)
    filled with the chart's own counts — not model output and not new wording.
    It is emitted under an explicit synthetic marker, and
    ``claim_scope`` records that the production explanation path would withhold
    for Q01 because ``instrument_gate`` is ``NOT_AUTHORIZED``.
    """
    spec = build_chart(allow_synthetic=True) if chart is None else chart
    registry = load_registry()
    entry = registry.question(QUESTION_ID)
    if entry is None:
        raise SyntheticPreviewRefused('SYNTHETIC_PREVIEW_QUESTION_ABSENT', 503)

    V = spec.measurement.V
    sentences: list[dict[str, Any]] = []
    for option in spec.options:
        percentage = percent_of(option.count, V)
        sentences.append({
            'code': option.code,
            'label': option.label or option.code,
            'label_source': option.label_source,
            'count': option.count,
            'percentage': None if percentage is None else str(percentage),
            'exclusive': option.code in EXCLUSIVE_CODES,
            'text': fill_item_template(entry.valid, {
                'V': V,
                'count': option.count,
                'category': option.label or option.code,
            }),
        })

    affiliation_total = sum(s['count'] for s in sentences if not s['exclusive'])
    exclusive_total = sum(s['count'] for s in sentences if s['exclusive'])

    return {
        'preview_marker': PREVIEW_MARKER,
        'preview_submarker': PREVIEW_SUBMARKER,
        'narrative_basis': 'REGISTRY_VALID_TEMPLATE_FILLED_WITH_VERIFIED_SYNTHETIC_COUNTS',
        'template_id': entry.valid.template_id,
        'template_text': entry.valid.text,
        'claim_scope': 'SYNTHETIC_PREVIEW_ONLY_NOT_A_REPORT_FINDING',
        'production_path_behaviour': (
            'The production explanation renderer withholds Q01 because '
            'instrument_gate is NOT_AUTHORIZED; this narrative exists only '
            'inside the synthetic preview.'),
        'V': V,
        'sentences': sentences,
        'affiliation_total': affiliation_total,
        'exclusive_total': exclusive_total,
        'exclusive_note': (
            'RARELY, NEVER and NOT_SURE are exclusive alternatives. '
            f'{exclusive_total} respondents selected one of them and no '
            'affiliation. They are counted separately and are never added to '
            'the affiliation categories.'),
        'not_a_report_finding': [
            'Not fielded data.',
            'Not an authorized measurement.',
            'Not admitted into R02 or R08.',
            'Not a census of residents, and not a demand, revenue or visit count.',
            'NOT_SURE is neither eligible nor ineligible.',
        ],
    }


def build_preview_payload(*, allow_synthetic: bool = False) -> dict[str, Any]:
    """Everything the preview surface renders, in one JSON-serialisable object.

    Byte-reproducible: the timestamp is the fixture cutoff rather than the wall
    clock, so re-running the generator produces an identical file and a diff is
    always a real change.
    """
    if not allow_synthetic:
        raise SyntheticPreviewRefused('SYNTHETIC_PREVIEW_NOT_ENABLED', 422)
    chart = build_chart(allow_synthetic=True)
    snapshot = build_snapshot()
    readback = build_readback(snapshot)
    registry = load_registry()
    entry = registry.question(QUESTION_ID)
    variants = {
        state: build_chart(allow_synthetic=True, state=state).to_json()
        for state in ('SYNTHETIC_PREVIEW_ONLY', 'WITHHELD_NOT_AUTHORIZED',
                      'NOT_ESTIMABLE')
    }
    return {
        'schema_version': 'q01-synthetic-preview/1',
        'preview_marker': PREVIEW_MARKER,
        'preview_submarker': PREVIEW_SUBMARKER,
        'question_id': QUESTION_ID,
        'question_version': snapshot['question_version'],
        'construct_id': entry.construct_id if entry else 'G01_AREA_AFFILIATION',
        'instrument_status': entry.instrument_status if entry else 'BLOCKED_MEASUREMENT',
        'instrument_gate': entry.instrument_gate if entry else 'NOT_AUTHORIZED',
        'report_sections': list(entry.report_sections) if entry else ['R02', 'R08'],
        'section_admission': (entry.report_admission.get('sections') if entry else None),
        'render_state': chart.render_state,
        'admission': chart.admission.model_dump(mode='json'),
        'measurement': chart.measurement.model_dump(mode='json'),
        'denominator_scope': chart.denominator_scope,
        'respondent_summary': respondent_summary(),
        'counts': aggregate_counts(),
        'chart': chart.to_json(),
        'chart_content_hash': chart.content_hash(),
        'chart_variants': variants,
        'explanation': build_explanation(chart),
        'evidence_context_hash': readback['context_hash'],
        'synthetic': {
            'origin': SYNTHETIC_ORIGIN,
            'scope': SYNTHETIC_SCOPE,
            'snapshot_id': SNAPSHOT_ID,
            'synthetic_run_id': SYNTHETIC_RUN_ID,
            'cutoff': CUTOFF,
            'fixture_module': __name__,
        },
        'generated_at': CUTOFF,
    }


__all__ = [
    'EXPECTED_COUNTS',
    'EXCLUSIVE_CODES',
    'PREVIEW_MARKER',
    'PREVIEW_SUBMARKER',
    'SyntheticPreviewRefused',
    'aggregate_counts',
    'build_chart',
    'build_explanation',
    'build_preview_payload',
    'build_readback',
    'build_snapshot',
    'respondent_summary',
]
