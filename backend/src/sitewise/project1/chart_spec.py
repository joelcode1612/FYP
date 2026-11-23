"""Typed chart specification (``chart-spec/1``) for R03-R08 measurement lines.

Authority position
------------------
This module renders *presentation structure only*. It never grants measurement,
scientific, privacy or report-admission authority, and it never converts an
unauthorized measurement into an authorized percentage.

The field list mirrors the twenty fields that
``CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json``
(``measurement_line_fields.fields``) requires on every R03-R08 numerical line:

    source_provenance, campaign_id, question_id, construct_id, report_sections,
    question_version, option_bank_version, stimulus_hash, concept_version,
    cohort_scope, cutoff, I, Q, S, A, V, x, percentage, denominator_scope,
    limitation

Numeric policy
--------------
``percentage`` is a :class:`~decimal.Decimal`, never a ``float``. EE-01 stores
``diagnostic_percentage`` as ``NUMERIC`` and the contract forbids emitting a
percentage at all when ``V == 0``; binary floating point would both introduce
representation drift and invite re-derivation of a value that must be copied
verbatim. Serialized JSON therefore carries percentages as decimal *strings*.

``StrictModel`` (``strict=True``) rejects ``Decimal`` -> ``int`` coercion, so
counts are coerced at the adapter boundary with an explicit ``int(...)`` and are
then validated against ``V``. ``int``/``Decimal`` -> ``float`` *is* accepted in
strict mode, which is precisely why ``float`` is not used for any evidential
quantity here.

Refusal vocabulary
------------------
Every refusal raises :class:`ChartRefused` carrying a fixed code. No refusal
message embeds raw source, provider or exception text, matching the
``WorkflowHeld`` convention in :mod:`sitewise.project1.contracts`.
"""
from __future__ import annotations

from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from typing import Literal

from pydantic import Field, field_validator, model_validator

from sitewise.project1.contracts import StrictModel, digest
# The readback context_hash is written by ``Ee01Service._store_held_context``
# with this digest, which sets ``ensure_ascii=True``. ``project1.contracts.digest``
# uses ``ensure_ascii=False``; the two agree on ASCII payloads but would diverge
# on non-ASCII context values, so verification must use the writer's function.
from sitewise.domain.customer_questionnaire import digest as ee01_digest

SCHEMA_VERSION = 'chart-spec/1'
EE01_DIAGNOSTIC_VERSION = 'ee01-diagnostic/1'
EE01_READBACK_VERSION = 'ee01-report-readback/1'

CANONICAL_REPORT_SECTIONS = tuple(f'R{n:02d}' for n in range(1, 13))

#: EE-01 cell codes that are aggregates over other options rather than options.
#: They must never be presented as a selectable response category.
DERIVED_CELL_CODES = frozenset({'TOP_TWO_STATED_INTEREST'})

#: Percentages are quantized to four decimal places, matching the precision the
#: ``NUMERIC`` column stores. Rounding is half-up so the value is reproducible
#: across platforms; it is *not* a claim of additional precision.
PERCENT_SCALE = Decimal('0.0001')

PctStatus = Literal['ESTIMABLE', 'NOT_ESTIMABLE', 'WITHHELD_NOT_AUTHORIZED', 'NOT_SHOWN',
                    'SYNTHETIC_PREVIEW_ESTIMABLE']
RenderState = Literal[
    'RENDERABLE',
    'NOT_SHOWN',
    'NOT_ESTIMABLE',
    'WITHHELD_NOT_AUTHORIZED',
    'UNAVAILABLE_MISSING_APPROVED_STIMULUS',
    'UNAUTHORIZED_CLAIM',
    #: Development-only presentation of a validated **synthetic** measurement.
    #:
    #: This state exists so a synthetic Q01 preview can draw bars and counts
    #: without pretending the line is admitted. It is reachable only through
    #: :func:`from_ee01` on an ``ISOLATED_TEST`` snapshot whose origin is
    #: ``SYNTHETIC_TEST``, and the admission block is still ``HELD`` — so the
    #: same document remains non-reportable through the production A10 pathway.
    #: It is never emitted for a production measurement, and it cannot be
    #: constructed while ``admission.real_reportable`` is true.
    'SYNTHETIC_PREVIEW_ONLY',
]

#: Render states that disclose counts. ``RENDERABLE`` is the production-
#: admitted case; ``SYNTHETIC_PREVIEW_ONLY`` is the isolated development case.
#: Everything else withholds counts as well as percentages.
COUNT_DISCLOSING_STATES = frozenset({'RENDERABLE', 'SYNTHETIC_PREVIEW_ONLY'})

#: Render states that describe a missing *input* rather than a count outcome.
#: They are legal at any count, never carry a percentage, and never name a
#: highest response, because the measurement cannot be interpreted at all.
INPUT_MISSING_STATES = frozenset({'UNAVAILABLE_MISSING_APPROVED_STIMULUS',
                                  'UNAUTHORIZED_CLAIM'})


class ChartRefused(ValueError):
    """Fixed refusal code only; never carries raw source or provider text."""

    def __init__(self, code: str, status: int = 422):
        super().__init__(code)
        self.code = code
        self.status = status


def percent_of(count: int, denominator: int) -> Decimal | None:
    """``100 * x / V`` quantized, or ``None`` when ``V == 0``.

    The contract's rule is explicit: when ``V == 0`` the line returns
    ``NOT_ESTIMABLE`` and *no percentage field is emitted*. Returning ``None``
    rather than ``Decimal(0)`` is what prevents a "0%" reading of missing data.
    """
    if denominator <= 0:
        return None
    return (Decimal(100) * Decimal(count) / Decimal(denominator)).quantize(
        PERCENT_SCALE, rounding=ROUND_HALF_UP)


class MeasurementCounts(StrictModel):
    """The I/Q/S/A/V funnel for one item, version, stimulus and cutoff."""

    #: ``I = UNKNOWN_NOT_ENUMERABLE`` for open self-selected campaigns. Clicks,
    #: link views and starts are not invitations and are never substituted.
    I: int | Literal['UNKNOWN_NOT_ENUMERABLE'] = Field(
        description='Invited units, or UNKNOWN_NOT_ENUMERABLE for open campaigns.')
    Q: int = Field(ge=0, description='Qualified units.')
    S: int = Field(ge=0, description='Shown units.')
    A: int = Field(ge=0, description='Answer events.')
    V: int = Field(ge=0, description='Substantive answers; the percentage denominator.')

    @model_validator(mode='after')
    def _monotonic(self):
        if not self.S <= self.Q:
            raise ValueError('E_FUNNEL_NON_MONOTONIC:S_GT_Q')
        if not self.A <= self.S:
            raise ValueError('E_FUNNEL_NON_MONOTONIC:A_GT_S')
        if not self.V <= self.A:
            raise ValueError('E_FUNNEL_NON_MONOTONIC:V_GT_A')
        return self


class ChartOption(StrictModel):
    """One response option and its count within ``V``."""

    code: str = Field(min_length=1, max_length=64)
    #: ``None`` when no option-label bank is bound. The renderer then shows the
    #: code, which is honest; inventing prose would not be.
    label: str | None = Field(default=None, max_length=200)
    #: ``CONTRACT_OPTION_BANK_DRAFT`` means a label exists but is a **candidate
    #: draft**, never approved wording. ``CODE_FALLBACK`` means no label at all.
    label_source: Literal['CONTRACT_OPTION_BANK', 'CONTRACT_OPTION_BANK_DRAFT',
                          'CODE_FALLBACK']
    #: Declared ordinal meaning, not display position. The contract keeps these
    #: separate so a display-order change cannot silently change the scale.
    ordinal_value: int | None = None
    count: int = Field(ge=0)
    percentage: Decimal | None = None
    percentage_status: PctStatus

    @model_validator(mode='after')
    def _label_consistency(self):
        if self.label_source in ('CONTRACT_OPTION_BANK',
                                 'CONTRACT_OPTION_BANK_DRAFT') and not self.label:
            raise ValueError('E_LABEL_SOURCE_WITHOUT_LABEL')
        if self.label_source == 'CODE_FALLBACK' and self.label:
            raise ValueError('E_LABEL_WITHOUT_BANK_SOURCE')
        return self

    @model_validator(mode='after')
    def _percentage_consistency(self):
        if self.percentage_status in ('ESTIMABLE', 'SYNTHETIC_PREVIEW_ESTIMABLE'):
            if self.percentage is None:
                raise ValueError('E_PERCENTAGE_STATUS_MISSING_VALUE')
            if not Decimal(0) <= self.percentage <= Decimal(100):
                raise ValueError('E_PERCENTAGE_OUT_OF_RANGE')
        elif self.percentage is not None:
            raise ValueError('E_PERCENTAGE_EMITTED_WITHOUT_AUTHORITY')
        return self


class DerivedLine(StrictModel):
    """A declared aggregate over option codes, kept out of ``options``.

    EE-01 emits e.g. ``TOP_TWO_STATED_INTEREST`` for Q05 as a category cell. It
    is a predeclared numerator rule, not a response a respondent could pick, so
    it is presented in its own list and never contributes to
    ``highest_options``.
    """

    code: str = Field(min_length=1, max_length=64)
    label: str | None = Field(default=None, max_length=200)
    numerator_codes: list[str] = Field(min_length=2, max_length=16)
    count: int = Field(ge=0)
    percentage: Decimal | None = None
    percentage_status: PctStatus
    formula: str = Field(min_length=1, max_length=200)
    output_label: str = Field(min_length=1, max_length=200)
    #: Aggregate of disjoint single-select codes only. Overlapping multi-select
    #: codes would require a union over units, which this contract cannot prove.
    combination: Literal['DISJOINT_SINGLE_SELECT'] = 'DISJOINT_SINGLE_SELECT'

    @model_validator(mode='after')
    def _percentage_consistency(self):
        if self.percentage_status in ('ESTIMABLE', 'SYNTHETIC_PREVIEW_ESTIMABLE'):
            if self.percentage is None:
                raise ValueError('E_PERCENTAGE_STATUS_MISSING_VALUE')
            if not Decimal(0) <= self.percentage <= Decimal(100):
                raise ValueError('E_PERCENTAGE_OUT_OF_RANGE')
        elif self.percentage is not None:
            raise ValueError('E_PERCENTAGE_EMITTED_WITHOUT_AUTHORITY')
        return self


class ChartAdmission(StrictModel):
    """Why the chart is, or is not, admissible into a report.

    ``authority`` is copied from the EE-01 readback and is never upgraded here.
    """

    status: Literal['HELD', 'ADMITTED']
    authority: str = Field(min_length=1, max_length=64)
    gates: list[str] = Field(max_length=16)
    real_reportable: bool

    @model_validator(mode='after')
    def _held_requires_gates(self):
        if self.status == 'HELD' and not self.gates:
            raise ValueError('E_HELD_WITHOUT_GATE')
        if self.status == 'ADMITTED' and self.gates:
            raise ValueError('E_ADMITTED_WITH_OPEN_GATE')
        return self


class ChartSpec(StrictModel):
    """Versioned, self-describing horizontal bar chart for one R03-R08 line."""

    schema_version: str = Field(pattern=r'^chart-spec/1$')
    chart_id: str = Field(min_length=1, max_length=128)
    chart_type: Literal['HORIZONTAL_BAR'] = 'HORIZONTAL_BAR'

    # --- the twenty contract fields -------------------------------------
    source_provenance: str = Field(min_length=1, max_length=200)
    #: The EE-01 readback ``context_hash`` this chart was built from.
    #:
    #: This is the join key that binds a chart to an explanation: the
    #: explanation service refuses any request whose ``context_hash`` does not
    #: match its stored context, so a chart and its narrative can only be shown
    #: together when both name the same evidence. Without it, "the explanation
    #: is about this chart" would be a claim rather than a check.
    evidence_context_hash: str = Field(pattern=r'^[0-9a-f]{64}$')
    campaign_id: str = Field(min_length=1, max_length=64)
    question_id: str = Field(min_length=1, max_length=32)
    construct_id: str = Field(min_length=1, max_length=64)
    report_sections: list[str] = Field(min_length=1, max_length=6)
    question_version: str = Field(min_length=1, max_length=64)
    option_bank_version: str = Field(min_length=1, max_length=64)
    stimulus_hash: str = Field(min_length=1, max_length=128)
    concept_version: str = Field(min_length=1, max_length=64)
    cohort_scope: str = Field(min_length=1, max_length=200)
    cutoff: datetime
    measurement: MeasurementCounts
    denominator_scope: str = Field(min_length=1, max_length=200)
    limitation: str = Field(min_length=1, max_length=2000)

    # --- presentation ----------------------------------------------------
    title: str = Field(min_length=1, max_length=200)
    question_text: str = Field(min_length=1, max_length=2000)
    response_kind: Literal['SINGLE_SELECT', 'MULTI_SELECT', 'ORDINAL']
    options: list[ChartOption] = Field(min_length=1, max_length=64)
    derived_lines: list[DerivedLine] = Field(default_factory=list, max_length=8)
    #: Codes tied at the maximum non-zero count. Empty when nothing is shown or
    #: when ``V == 0``. Ties are reported as ties; no single "winner" is picked.
    highest_options: list[str] = Field(default_factory=list, max_length=64)
    #: Mandatory, always rendered. Never optional and never collapsed.
    limitations: list[str] = Field(min_length=1, max_length=16)
    #: The single authoritative presentation decision, so a renderer never has
    #: to re-derive admissibility from the counts.
    render_state: RenderState
    admission: ChartAdmission

    # --- validators ------------------------------------------------------
    @field_validator('report_sections')
    @classmethod
    def _canonical_sections(cls, value: list[str]):
        for section in value:
            if section not in CANONICAL_REPORT_SECTIONS:
                raise ValueError('E_NONCANONICAL_REPORT_SECTION')
        if len(set(value)) != len(value):
            raise ValueError('E_DUPLICATE_REPORT_SECTION')
        return value

    @field_validator('cutoff')
    @classmethod
    def _tz_aware(cls, value: datetime):
        if value.tzinfo is None:
            raise ValueError('E_CUTOFF_NAIVE')
        return value.astimezone(timezone.utc)

    @field_validator('options')
    @classmethod
    def _unique_codes(cls, value: list[ChartOption]):
        codes = [option.code for option in value]
        if len(set(codes)) != len(codes):
            raise ValueError('E_DUPLICATE_OPTION_CODE')
        return value

    @model_validator(mode='after')
    def _line_invariants(self):
        counts = self.measurement
        V = counts.V

        for option in self.options:
            if option.count > V:
                raise ValueError('E_OPTION_COUNT_EXCEEDS_V')

        total = sum(option.count for option in self.options)
        if self.response_kind in ('SINGLE_SELECT', 'ORDINAL'):
            if total != V:
                raise ValueError('E_SINGLE_SELECT_SUM_MISMATCH')
        elif total < V:
            # Multi-select: options may overlap, so the sum may exceed V, but it
            # can never fall below V when every substantive answer selects at
            # least one counted code.
            raise ValueError('E_MULTI_SELECT_SUM_BELOW_V')

        for line in self.derived_lines:
            if line.count > V:
                raise ValueError('E_DERIVED_COUNT_EXCEEDS_V')
            if not set(line.numerator_codes) <= {o.code for o in self.options}:
                raise ValueError('E_DERIVED_CODE_NOT_AN_OPTION')
            expected = sum(o.count for o in self.options if o.code in set(line.numerator_codes))
            if line.count != expected:
                raise ValueError('E_DERIVED_COUNT_MISMATCH')

        expected_highest = self._compute_highest()
        if list(self.highest_options) != expected_highest:
            raise ValueError('E_HIGHEST_OPTIONS_MISMATCH')

        self._check_render_state()
        return self

    def _compute_highest(self) -> list[str]:
        # A state that describes a missing input has no interpretable ordering.
        # Naming a "highest" response there would invite a reading the instrument
        # cannot support, so the highlight is withheld along with the percentage.
        if self.render_state in INPUT_MISSING_STATES:
            return []
        if self.measurement.V == 0:
            return []
        ranked = [option for option in self.options if option.count > 0]
        if not ranked:
            return []
        top = max(option.count for option in ranked)
        return sorted(option.code for option in ranked if option.count == top)

    def _check_render_state(self):
        counts = self.measurement
        # Two contract statuses describe a missing input rather than a count
        # outcome; they are legal at any count and never carry a percentage.
        if self.render_state in ('UNAVAILABLE_MISSING_APPROVED_STIMULUS',
                                 'UNAUTHORIZED_CLAIM'):
            for option in self.options:
                if option.percentage is not None:
                    raise ValueError('E_PERCENTAGE_EMITTED_WITHOUT_AUTHORITY')
            return
        if counts.S == 0:
            allowed = {'NOT_SHOWN'}
        elif counts.V == 0:
            allowed = {'NOT_ESTIMABLE'}
        elif self.admission.status != 'ADMITTED':
            # A held line may be presented either as withheld (production) or as
            # an isolated synthetic preview (development). Both carry the same
            # HELD admission block, so neither becomes a reportable finding.
            allowed = {'WITHHELD_NOT_AUTHORIZED', 'SYNTHETIC_PREVIEW_ONLY'}
        else:
            allowed = {'RENDERABLE'}
        if self.render_state not in allowed:
            raise ValueError('E_RENDER_STATE_INCONSISTENT')

        # A preview presentation may never ride on a line the caller declared
        # reportable; that would let a development label carry production
        # authority into the document.
        if (self.render_state == 'SYNTHETIC_PREVIEW_ONLY'
                and self.admission.real_reportable):
            raise ValueError('E_SYNTHETIC_PREVIEW_MARKED_REPORTABLE')

        estimable = self.render_state == 'RENDERABLE'
        preview = self.render_state == 'SYNTHETIC_PREVIEW_ONLY'
        expected_pct_status = ('ESTIMABLE' if estimable
                               else 'SYNTHETIC_PREVIEW_ESTIMABLE')
        for option in self.options:
            if estimable or preview:
                if option.percentage_status != expected_pct_status:
                    raise ValueError('E_RENDERABLE_OPTION_NOT_ESTIMABLE')
                if option.percentage != percent_of(option.count, counts.V):
                    raise ValueError('E_PERCENTAGE_MISMATCH')
            elif option.percentage is not None:
                raise ValueError('E_PERCENTAGE_EMITTED_WITHOUT_AUTHORITY')
        for line in self.derived_lines:
            if estimable or preview:
                if line.percentage_status != expected_pct_status:
                    raise ValueError('E_RENDERABLE_OPTION_NOT_ESTIMABLE')
                if line.percentage != percent_of(line.count, counts.V):
                    raise ValueError('E_PERCENTAGE_MISMATCH')
            elif line.percentage is not None:
                raise ValueError('E_PERCENTAGE_EMITTED_WITHOUT_AUTHORITY')

    # --- helpers ---------------------------------------------------------
    def to_json(self) -> dict:
        """JSON-safe dict; percentages are decimal strings, not floats."""
        return self.model_dump(mode='json')

    def content_hash(self) -> str:
        """Deterministic identity of the rendered chart."""
        return digest(self.to_json())


def held_admission(gates: list[str], *, real_reportable: bool = False) -> ChartAdmission:
    """The only admission this module can construct without an adopted adapter."""
    return ChartAdmission(status='HELD', authority='AUTHORITY_UNVERIFIED',
                          gates=sorted(set(gates)), real_reportable=real_reportable)


# ---------------------------------------------------------------------------
# Synthetic EE-01 adapter
# ---------------------------------------------------------------------------

_RESPONSE_KIND = {
    'single_select': 'SINGLE_SELECT',
    'nominal_single': 'SINGLE_SELECT',
    'multi_select': 'MULTI_SELECT',
    'multi_select_with_exclusive_terminals': 'MULTI_SELECT',
    'ordinal_single': 'ORDINAL',
    # ``ordinal_matrix`` (Q10) is deliberately absent. A matrix needs a
    # per-feature denominator, and EE-01 stores one V per snapshot, so the
    # response kind is refused rather than flattened into a single scale.
}

_STATUS_TO_RENDER: dict[str, RenderState] = {
    'NOT_SHOWN': 'NOT_SHOWN',
    'NOT_ESTIMABLE': 'NOT_ESTIMABLE',
    'WITHHELD_NOT_AUTHORIZED': 'WITHHELD_NOT_AUTHORIZED',
    # The preview state is never inferred from an EE-01 status: it must be
    # requested explicitly through ``render_state_override`` on a synthetic
    # snapshot, so no production readback can drift into it.
    'SYNTHETIC_PREVIEW_ONLY': 'SYNTHETIC_PREVIEW_ONLY',
}


def _require(condition: bool, code: str, status: int = 422) -> None:
    if not condition:
        raise ChartRefused(code, status)


def from_ee01(snapshot: dict, readback: dict, question: dict, *, title: str,
              limitation: str | None = None,
              labels: dict[str, str] | None = None,
              render_state_override: RenderState | None = None,
              denominator_scope: str | None = None) -> ChartSpec:
    """Map a verified synthetic EE-01 snapshot into ``chart-spec/1``.

    Every check below is a refusal, not a repair. A missing denominator, a
    version mismatch, a stale readback or a non-synthetic scope is never
    "worked around" into a presentable chart.

    ``question`` is the frozen CUST03 item dict (``stem``, ``codes``,
    ``display_order``, ``ordinal_meaning``, ``coverage_limitation``, ...). It is
    used for wording and display order only; it confers no authority.

    ``labels`` maps a response code to a **draft** option label. Supplying one
    sets ``label_source='CONTRACT_OPTION_BANK_DRAFT'``; the label is presented as
    a candidate, never as approved wording. Absent, the code is shown instead.

    ``render_state_override`` may only *restrict* what the snapshot status allows
    — it exists so an item whose required stimulus is missing can be held at
    ``UNAVAILABLE_MISSING_APPROVED_STIMULUS`` even when counts exist. It can never
    produce ``RENDERABLE``: that would manufacture admission from a caller value.

    ``denominator_scope`` overrides the default sentence that names ``V`` as
    *substantive answers*. It exists because an item with exclusive terminals
    (Q01) counts valid answers that select no substantive code, so the default
    sentence would misdescribe the denominator it is attached to. It is prose
    only: no validator derives a count or a percentage from it, and the default
    is unchanged for every existing caller.
    """
    _require(snapshot.get('contract_version') == EE01_DIAGNOSTIC_VERSION,
             'CHART_SNAPSHOT_VERSION_MISMATCH', 409)
    _require(readback.get('contract_version') == EE01_READBACK_VERSION,
             'CHART_READBACK_VERSION_MISMATCH', 409)
    _require(render_state_override != 'RENDERABLE',
             'CHART_OVERRIDE_CANNOT_AUTHORIZE', 422)
    _require(render_state_override in (None, 'NOT_SHOWN', 'NOT_ESTIMABLE',
                                       'WITHHELD_NOT_AUTHORIZED',
                                       'UNAVAILABLE_MISSING_APPROVED_STIMULUS',
                                       'UNAUTHORIZED_CLAIM',
                                       'SYNTHETIC_PREVIEW_ONLY'),
             'CHART_OVERRIDE_UNKNOWN', 422)

    context = readback.get('context') or {}
    _require(bool(context), 'CHART_READBACK_CONTEXT_MISSING', 503)
    _require(context.get('snapshot_id') == str(snapshot.get('id')),
             'CHART_READBACK_STALE_SNAPSHOT', 409)
    _require(context.get('fingerprint') == snapshot.get('fingerprint'),
             'CHART_READBACK_FINGERPRINT_MISMATCH', 409)
    _require(readback.get('context_hash') == ee01_digest(context),
             'CHART_READBACK_INTEGRITY_INVALID', 503)

    # Synthetic separation: a PRODUCTION snapshot has no verified measurement
    # authority, so it cannot be charted at all yet.
    _require(snapshot.get('scope') == 'ISOLATED_TEST',
             'CHART_MEASUREMENT_AUTHORITY_UNVERIFIED', 503)
    _require(context.get('authority') == 'AUTHORITY_UNVERIFIED',
             'CHART_ADMISSION_AUTHORITY_UNEXPECTED', 503)

    metadata = snapshot.get('metadata_json') or {}
    _require(metadata.get('origin') == 'SYNTHETIC_TEST',
             'CHART_SYNTHETIC_ORIGIN_MISSING', 503)

    V = int(snapshot.get('v') or 0)
    Q = int(snapshot.get('q') or 0)
    S = int(snapshot.get('s') or 0)
    A = int(snapshot.get('a') or 0)
    _require(S >= 0 and Q >= 0 and A >= 0 and V >= 0, 'CHART_COUNTS_NEGATIVE', 503)

    status = str(snapshot.get('status') or '')
    _require(status in _STATUS_TO_RENDER, 'CHART_STATUS_UNKNOWN', 503)

    question_codes = list(question.get('codes') or [])
    substantive = set(question.get('substantive_codes') or [])
    _require(bool(question_codes), 'CHART_QUESTION_CODES_MISSING', 503)

    cells = {cell['code']: cell for cell in (snapshot.get('cells') or [])}
    _require(bool(cells), 'CHART_CELLS_MISSING', 503)

    derived_codes = set(DERIVED_CELL_CODES) & set(cells)
    unknown = set(cells) - set(question_codes) - derived_codes
    _require(not unknown, 'CHART_UNKNOWN_CELL_CODE', 503)

    # Percentages are only ever emitted when the line is genuinely renderable.
    # No adopted admission adapter exists, so in V1 that is never the case; the
    # branch is retained so a future authorized adapter does not need new rules.
    admission = held_admission(list(context.get('gates') or []),
                               real_reportable=bool(context.get('real_reportable')))
    render_state = render_state_override or _STATUS_TO_RENDER[status]
    # A preview presentation must never be attached to a line the caller has
    # declared reportable. The two are mutually exclusive by construction: a
    # real_reportable line is asking for production authority, which this state
    # does not carry.
    _require(not (render_state == 'SYNTHETIC_PREVIEW_ONLY'
                  and admission.real_reportable),
             'CHART_SYNTHETIC_PREVIEW_REPORTABLE', 422)
    estimable = render_state == 'RENDERABLE'
    preview = render_state == 'SYNTHETIC_PREVIEW_ONLY'
    discloses_counts = estimable or preview
    disclosed_pct_status = ('ESTIMABLE' if estimable
                            else 'SYNTHETIC_PREVIEW_ESTIMABLE' if preview else None)
    label_bank = dict(labels or {})

    display_order = list(question.get('display_order') or question_codes)
    ordered_codes = [code for code in display_order if code in cells] + \
                    [code for code in question_codes if code in cells and code not in display_order]
    ordinal_meaning = question.get('ordinal_meaning') or {}

    options: list[ChartOption] = []
    for code in ordered_codes:
        cell = cells[code]
        count = int(cell.get('x') or 0)
        cell_v = int(cell.get('v') or 0)
        _require(cell_v == V, 'CHART_CELL_DENOMINATOR_MISMATCH', 503)
        label = label_bank.get(code)
        options.append(ChartOption(
            code=code,
            label=label or None,
            label_source=('CONTRACT_OPTION_BANK_DRAFT' if label else 'CODE_FALLBACK'),
            ordinal_value=int(ordinal_meaning[code]) if code in ordinal_meaning else None,
            count=count,
            percentage=percent_of(count, V) if discloses_counts else None,
            percentage_status=(disclosed_pct_status
                               or _held_status(render_state)),
        ))

    derived_lines: list[DerivedLine] = []
    rule = question.get('numerator_rule') or {}
    for code in sorted(derived_codes):
        cell = cells[code]
        count = int(cell.get('x') or 0)
        numerator = list(rule.get('numerator_categories') or [])
        _require(bool(numerator), 'CHART_DERIVED_RULE_MISSING', 503)
        _require(set(numerator) <= substantive,
                 'CHART_DERIVED_RULE_NOT_SUBSTANTIVE', 503)
        derived_lines.append(DerivedLine(
            code=code,
            label=None,
            numerator_codes=numerator,
            count=count,
            percentage=percent_of(count, V) if discloses_counts else None,
            percentage_status=(disclosed_pct_status
                               or _held_status(render_state)),
            formula=str(rule.get('formula') or ''),
            output_label=str(rule.get('output_label') or code),
        ))

    # A matrix is refused for a different reason than an unknown type, and the
    # difference is worth reading from the code alone. Q10's per-feature
    # denominators exist: ``cq_runtime.route`` expands Q10 into one slot per
    # feature and EE-01 measures one slot, so each feature slot carries its own V
    # (D-09 is superseded on exactly this point). What is missing is the rule, not
    # the denominator — the registry declares no per-feature measurement rule
    # (``Q10-NR-DEFAULT`` names the denominator unsupported) and no ordinal scale
    # (``ordinal_meaning_source: UNDECLARED``), and the feature bank is unapproved
    # (G06). Projecting the matrix onto one scale would invent both, so it is
    # refused under the code the project already uses for this condition.
    if str(question.get('type') or '') == 'ordinal_matrix':
        raise ChartRefused('PER_FEATURE_SLOT_UNSUPPORTED', 422)

    response_kind = _RESPONSE_KIND.get(str(question.get('type') or ''))
    _require(response_kind is not None, 'CHART_RESPONSE_KIND_UNSUPPORTED', 422)

    sections = list(question.get('report_sections') or [])
    _require(bool(sections), 'CHART_REPORT_SECTION_MISSING', 422)

    limitation_text = limitation or str(question.get('coverage_limitation') or '')
    _require(bool(limitation_text.strip()), 'CHART_LIMITATION_MISSING', 422)

    limitations = [limitation_text.strip()]
    for key in ('forbidden_inference', 'ordinal_only_rationale'):
        extra = str(question.get(key) or '').strip()
        if extra:
            limitations.append(extra)

    spec = ChartSpec(
        schema_version=SCHEMA_VERSION,
        chart_id=f"chart:{snapshot.get('id')}:{sections[0]}",
        chart_type='HORIZONTAL_BAR',
        source_provenance=str(metadata.get('origin') or 'SYNTHETIC_FIXTURE'),
        evidence_context_hash=str(readback.get('context_hash')),
        campaign_id=str(snapshot.get('campaign_id')),
        question_id=str(question.get('id')),
        construct_id=str(question.get('construct')),
        report_sections=sections,
        question_version=str(snapshot.get('question_version')),
        option_bank_version=str(metadata.get('bank_version') or ''),
        stimulus_hash=str(metadata.get('stimulus_hash') or ''),
        concept_version=str(metadata.get('instrument_version') or ''),
        cohort_scope=(f"{metadata.get('research_mode', 'UNKNOWN')} / "
                      f"qualification {','.join(metadata.get('qualification_versions') or []) or 'UNSPECIFIED'}"),
        cutoff=_as_utc(snapshot.get('cutoff')),
        measurement=MeasurementCounts(I='UNKNOWN_NOT_ENUMERABLE', Q=Q, S=S, A=A, V=V),
        denominator_scope=(denominator_scope or
                           f'V = substantive answers to {question.get("id")} '
                           f'at this version and stimulus'),
        limitation=limitation_text.strip(),
        title=title,
        question_text=str(question.get('stem') or ''),
        response_kind=response_kind,
        options=options,
        derived_lines=derived_lines,
        highest_options=highest_codes(options, V, render_state),
        limitations=limitations,
        render_state=render_state,
        admission=admission,
    )
    return spec


def highest_codes(options: list[ChartOption], V: int,
                  render_state: RenderState | None = None) -> list[str]:
    """Codes tied at the maximum non-zero count; ``[]`` when nothing is shown.

    Computed before construction so the stored value is the value the model
    validates, rather than being patched in afterwards. A state that describes a
    missing input returns ``[]``: there is no interpretable ordering to report.
    """
    if render_state in INPUT_MISSING_STATES:
        return []
    if V == 0:
        return []
    ranked = [option for option in options if option.count > 0]
    if not ranked:
        return []
    top = max(option.count for option in ranked)
    return sorted(option.code for option in ranked if option.count == top)


def _as_utc(value) -> datetime:
    """EE-01 ``plain()`` stringifies datetimes with ``str()``, so parse it back."""
    if isinstance(value, datetime):
        parsed = value
    else:
        try:
            parsed = datetime.fromisoformat(str(value))
        except (TypeError, ValueError) as exc:
            raise ChartRefused('CHART_CUTOFF_INVALID', 503) from exc
    if parsed.tzinfo is None:
        raise ChartRefused('CHART_CUTOFF_NAIVE', 503)
    return parsed.astimezone(timezone.utc)


def _held_status(render_state: RenderState) -> PctStatus:
    return {
        'NOT_SHOWN': 'NOT_SHOWN',
        'NOT_ESTIMABLE': 'NOT_ESTIMABLE',
    }.get(render_state, 'WITHHELD_NOT_AUTHORIZED')
