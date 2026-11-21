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
                               period_required: bool) -> FixedOptionMeasurement:
    """Validate structure using caller-supplied, server-authoritative policy.

    Source and semantic review remain separate gates; neither the capability set
    nor the need for a reference period may come from model output.
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
            previous = (hi, option.upper_inclusive)
    elif any(o.lower is not None or o.upper is not None for o in spec.options):
        raise WorkflowHeld('QG_RANGE_METADATA_UNEXPECTED')
    return spec


def validate_fixed_candidate(raw: dict, facts: ConfirmedFacts, *,
                             supported_formats: frozenset[str],
                             approved_population: str,
                             period_required: bool) -> FixedOptionCandidate:
    """Admit a source-bound proposal; semantic quality remains for review.

    Restrict routing to END until a server-authoritative target/version policy is
    available. Never infer the approved population from model output.
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
    if not approved_population.strip() or spec.population != approved_population:
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
