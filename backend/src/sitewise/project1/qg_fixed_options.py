"""Candidate-only fixed-option amendment; historical QG contracts stay readable.

This validator does not prove scientific quality or Flutter compatibility.  The
normal generation paths are held until candidate admission and source authority
are wired. Respondent-side execution is a separate future verification.
"""
from __future__ import annotations

from decimal import Decimal, InvalidOperation
from typing import Literal

from pydantic import Field

from sitewise.project1.contracts import StrictModel, WorkflowHeld
from sitewise.project1.qg_contract import QGCandidate, ConfirmedFacts, validate_candidate
import re

FIXED_OPTION_CONTRACT = 'P1-QG-FIXED-OPTION-1.0'
# No QG-to-Flutter-to-answer/readback integration has been verified yet.
VERIFIED_RESPONDENT_FORMATS: frozenset[str] = frozenset()


class FixedOption(StrictModel):
    code: str = Field(pattern=r'^[A-Z][A-Z0-9_]{0,63}$')
    label: str = Field(min_length=1, max_length=500)
    order: int = Field(ge=0)
    lower: Decimal | None = Field(default=None, strict=False)
    upper: Decimal | None = Field(default=None, strict=False)
    lower_inclusive: bool = True
    upper_inclusive: bool = True


class FixedOptionMeasurement(StrictModel):
    contract_version: Literal['P1-QG-FIXED-OPTION-1.0']
    response_format: Literal['SINGLE_CHOICE', 'BINARY_CHOICE', 'ORDERED_SCALE',
                             'NUMERIC_RANGE_OPTIONS', 'MULTIPLE_CHOICE']
    construct_name: str = Field(alias='construct', min_length=1, max_length=500)
    population: str = Field(min_length=1, max_length=500)
    reference_period: str = Field(default='', max_length=500)
    options: list[FixedOption] = Field(min_length=2, max_length=12)
    min_selections: int = Field(ge=1)
    max_selections: int = Field(ge=1)
    exclusive_codes: list[str] = Field(default_factory=list)
    interpretation: str = Field(min_length=1, max_length=1000)
    limitations: str = Field(min_length=1, max_length=1000)
    unit: str = Field(default='', max_length=100)


class FixedOptionCandidate(QGCandidate):
    # This is a proposal only. Source authority comes from the server-side
    # projection and policy, never from these model-supplied fields.
    fixed_measurement: FixedOptionMeasurement | None = None


def require_verified_respondent_path() -> None:
    """Hold legacy generation until the fixed-option adapter is actually wired.

    Verifying a Flutter format alone must never activate the unvalidated V2
    candidate path. The hold can be removed with the versioned candidate adapter,
    source/quality validation and required authority in place; respondent-side
    testing and fielding are separate gates.
    """
    raise WorkflowHeld('QG_FIXED_OPTION_ADMISSION_UNAVAILABLE')


def validate_fixed_measurement(raw: dict, *, supported_formats: frozenset[str],
                               period_required: bool,
                               require_contiguous: bool = False,
                               require_label_boundaries: bool = False
                               ) -> FixedOptionMeasurement:
    """Validate structure using caller-supplied, server-authoritative policy.

    Source and semantic review remain separate gates; neither the capability set
    nor the need for a reference period may come from model output.

    ``require_contiguous`` and ``require_label_boundaries`` default to ``False``
    so historical callers keep their exact behaviour. The versioned adapter turns
    both on, because a band set that silently leaves a gap — or a label that
    names an amount the boundary does not — is a measurement the respondent
    cannot answer as written.
    """
    if not isinstance(raw, dict):
        raise WorkflowHeld('QG_FIXED_OPTION_SCHEMA_INVALID')
    if raw.get('response_format') not in supported_formats:
        raise WorkflowHeld('UNSUPPORTED_FORMAT')
    try:
        spec = FixedOptionMeasurement.model_validate(raw)
    except (ValueError, InvalidOperation) as exc:
        raise WorkflowHeld('QG_FIXED_OPTION_SCHEMA_INVALID') from exc
    if not spec.construct_name.strip() or not spec.population.strip():
        raise WorkflowHeld('QG_MEASUREMENT_CONTEXT_REQUIRED')
    if period_required and not spec.reference_period.strip():
        raise WorkflowHeld('QG_REFERENCE_PERIOD_REQUIRED')
    if not spec.interpretation.strip() or not spec.limitations.strip():
        raise WorkflowHeld('QG_INTERPRETATION_REQUIRED')
    codes = [o.code for o in spec.options]
    labels = [o.label.strip().casefold() for o in spec.options]
    if len(set(codes)) != len(codes) or len(set(labels)) != len(labels) or '' in labels:
        raise WorkflowHeld('QG_RESPONSE_CODING_DRIFT')
    if [o.order for o in spec.options] != list(range(len(spec.options))):
        raise WorkflowHeld('QG_OPTION_ORDER_INVALID')
    if len(set(spec.exclusive_codes)) != len(spec.exclusive_codes) or not set(spec.exclusive_codes) <= set(codes):
        raise WorkflowHeld('QG_SELECTION_CONSTRAINT_INVALID')
    if spec.response_format == 'MULTIPLE_CHOICE':
        if not (1 <= spec.min_selections <= spec.max_selections <= len(codes)):
            raise WorkflowHeld('QG_SELECTION_CONSTRAINT_INVALID')
        if spec.exclusive_codes and spec.min_selections != 1:
            raise WorkflowHeld('QG_SELECTION_CONSTRAINT_INVALID')
    elif (spec.min_selections, spec.max_selections) != (1, 1) or spec.exclusive_codes:
        raise WorkflowHeld('QG_SELECTION_CONSTRAINT_INVALID')
    if spec.response_format == 'BINARY_CHOICE' and len(codes) != 2:
        raise WorkflowHeld('QG_BINARY_OPTION_COUNT_INVALID')
    if spec.response_format == 'NUMERIC_RANGE_OPTIONS':
        if not spec.unit.strip():
            raise WorkflowHeld('QG_RANGE_UNIT_REQUIRED')
        previous = None
        for option in spec.options:
            lo, hi = option.lower, option.upper
            if (lo is None or hi is None or not lo.is_finite() or not hi.is_finite()
                    or lo > hi or (lo == hi and not (option.lower_inclusive and option.upper_inclusive))):
                raise WorkflowHeld('QG_RANGE_INVALID')
            if previous is not None:
                old_hi, old_inclusive = previous
                if lo < old_hi or (lo == old_hi and old_inclusive and option.lower_inclusive):
                    raise WorkflowHeld('QG_RANGE_OVERLAP')
                if require_contiguous:
                    # An exhaustive band set must cover the interval without a
                    # hole and without a double-covered boundary: the shared
                    # edge must be inclusive on exactly one side.
                    if lo != old_hi or old_inclusive == option.lower_inclusive:
                        raise WorkflowHeld('QG_RANGE_GAP_OR_DOUBLE_COVERED_BOUNDARY')
            previous = (hi, option.upper_inclusive)
        if require_label_boundaries:
            for option in spec.options:
                amounts = {Decimal(m.group(1))
                           for m in re.finditer(r'RM\s?(\d+(?:\.\d+)?)',
                                                option.label, re.I)}
                if not amounts:
                    # A worded label ("less than RM10" is still caught above;
                    # "low" is not an amount) is not a boundary claim.
                    continue
                allowed = {value for value in (option.lower, option.upper)
                           if value is not None}
                if not amounts <= allowed:
                    raise WorkflowHeld('QG_RANGE_LABEL_BOUNDARY_MISMATCH')
    elif any(o.lower is not None or o.upper is not None for o in spec.options):
        raise WorkflowHeld('QG_RANGE_METADATA_UNEXPECTED')
    return spec


def validate_response(spec: FixedOptionMeasurement, selected) -> list[str]:
    """Validate one respondent selection against an admitted specification.

    Specification validation cannot decide this: "NONE alongside another option"
    is a property of a *selection*, not of the option set, and rejecting every
    multi-select specification that carries an exclusive code would also reject
    the legitimate "select up to three features, or None" shape. So the
    exclusivity rule lives here, where a selection actually exists.

    Returns the selection as a list on success. Raises on any violation; the
    caller must not persist an answer that fails here.
    """
    codes = [o.code for o in spec.options]
    if not isinstance(selected, (list, tuple)) or not selected:
        raise WorkflowHeld('QG_RESPONSE_EMPTY')
    chosen = list(selected)
    if any(not isinstance(code, str) for code in chosen):
        raise WorkflowHeld('QG_RESPONSE_CODE_UNKNOWN')
    unknown = [code for code in chosen if code not in codes]
    if unknown:
        raise WorkflowHeld('QG_RESPONSE_CODE_UNKNOWN')
    if len(set(chosen)) != len(chosen):
        raise WorkflowHeld('QG_RESPONSE_DUPLICATE_CODE')
    if not (spec.min_selections <= len(chosen) <= spec.max_selections):
        raise WorkflowHeld('QG_RESPONSE_CARDINALITY')
    exclusive = set(chosen) & set(spec.exclusive_codes)
    if exclusive and len(chosen) > 1:
        # "None of these" plus another option is a contradiction, not a
        # preference, so it is refused rather than stored and interpreted later.
        raise WorkflowHeld('QG_RESPONSE_EXCLUSIVE_VIOLATED')
    return chosen


def validate_fixed_candidate(raw: dict, facts: ConfirmedFacts, *,
                             supported_formats: frozenset[str],
                             approved_population: str | None,
                             period_required: bool,
                             population_basis: str = 'APPROVED_SPECIFICATION') -> FixedOptionCandidate:
    """Admit a source-bound proposal; semantic quality remains for review.

    Restrict routing to END until a server-authoritative target/version policy is
    available. Never infer the approved population from model output.

    ``population_basis`` says whether an approved population exists at all.
    Under contract 2.1 a candidate may be drafted against a *proposed*
    measurement, in which case there is nothing to compare the candidate's
    population against. Comparing it to the model's own output would make the
    check self-satisfying, which is the same defect as checking a purpose the
    caller just wrote (DD-034). So the proposed basis requires only that a
    population is declared, and the row records that it is not approved.
    """
    try:
        candidate = FixedOptionCandidate.model_validate(raw)
    except ValueError as exc:
        raise WorkflowHeld('QG_FIXED_OPTION_SCHEMA_INVALID') from exc
    validate_candidate(candidate.model_dump(exclude={'fixed_measurement'}), facts)
    if candidate.decision == 'ABSTAIN_NEEDS_REVIEW':
        if candidate.fixed_measurement is not None:
            raise WorkflowHeld('QG_ABSTENTION_CONTAINS_MEASUREMENT')
        return candidate
    if not facts.objective_id or not facts.objective_text.strip():
        raise WorkflowHeld('QG_APPROVED_OBJECTIVE_REQUIRED')
    if not re.fullmatch(r'[0-9a-f]{64}', facts.context_hash):
        raise WorkflowHeld('QG_CONTEXT_HASH_INVALID')
    if candidate.fixed_measurement is None:
        raise WorkflowHeld('QG_FIXED_MEASUREMENT_REQUIRED')
    spec = validate_fixed_measurement(candidate.fixed_measurement.model_dump(by_alias=True),
        supported_formats=supported_formats, period_required=period_required)
    if population_basis == 'PROPOSED_NOT_CONFIRMED':
        # No approved population exists to compare against. Requiring a declared
        # one keeps the field answerable without pretending it was approved.
        if not str(spec.population or '').strip():
            raise WorkflowHeld('QG_POPULATION_NOT_DECLARED')
    elif (not str(approved_population or '').strip()
          or spec.population != approved_population):
        raise WorkflowHeld('QG_POPULATION_AUTHORITY_MISMATCH')
    if [o.code for o in spec.options] != candidate.response_codes or [o.label for o in spec.options] != candidate.response_options:
        raise WorkflowHeld('QG_FIXED_OPTION_MISMATCH')
    if any(target != 'END' for target in candidate.routing.values()):
        raise WorkflowHeld('QG_ROUTING_TARGET_UNVERIFIED')
    if re.search(r'\b(?:amazing|wonderful|everyone loves|you will love)\b', candidate.question, re.I):
        raise WorkflowHeld('QG_KNOWN_LEADING_WORDING')
    labels = ' '.join(candidate.response_options)
    amounts = {m.group(0).replace(' ', '').upper() for m in re.finditer(r'RM\s?\d+(?:\.\d+)?', labels, re.I)}
    if not amounts <= set(facts.confirmed_currency):
        raise WorkflowHeld('QG_UNSOURCED_AMOUNT')
    return candidate
