"""PROVISIONAL_TEST_ONLY_NOT_APPROVED measurement candidate LAB-PRICE-RM13-0.1.

This module binds the research handoff candidate
``MEASUREMENT_CANDIDATE_LAB_V0_1.json`` onto the *actual* live contract
``sitewise.project1.contracts.Measurement`` and carries, in a separate
test-only strict model, the estimand facts that the live contract cannot
express (numerator codes, denominator codes, excluded response states).

Nothing here confers authority. Every approval flag is False, production
adoption is False, and no provider, bank, GEO or Owner approval is claimed.
"""
from __future__ import annotations

from pydantic import Field

from sitewise.project1.contracts import Measurement, StrictModel

MEASUREMENT_ID = 'LAB-PRICE-RM13-0.1'
STATUS = 'PROVISIONAL_TEST_ONLY_NOT_APPROVED'
PRODUCTION_ADOPTION = False
INSTRUMENT_VERSION = 'M2V1-20261114-1'

#: The five authority switches named by the research handoff. All are False.
APPROVAL_FLAGS = {
    'fielding_authorized': False,
    'scientific_accepted': False,
    'owner_approved_for_publication': False,
    'production_bank_authority_verified': False,
    'qg_research_comparison_authorized': False,
}

#: The exact hypothetical offer. Every component must stay visible in the
#: stimulus, otherwise the stated-price question silently changes meaning.
OFFER_COMPONENTS = ('12 oz', 'takeaway', 'iced latte', 'RM13')

#: Fixed machine codes; one per failure mode, no free text in the reason.
APPROVAL_FLAG_SET = 'LAB_APPROVAL_FLAG_SET'
INSTRUMENT_VERSION_DRIFT = 'LAB_INSTRUMENT_VERSION_DRIFT'
DENOMINATOR_EMPTY = 'LAB_DENOMINATOR_EMPTY'
RESPONSE_CODES_INVALID = 'LAB_RESPONSE_CODES_INVALID'
ESTIMAND_INVALID = 'LAB_ESTIMAND_INVALID'
NONRESPONSE_NOT_SEPARATE = 'LAB_NONRESPONSE_NOT_SEPARATE'
STIMULUS_OMITS_OFFER_COMPONENT = 'LAB_STIMULUS_OMITS_OFFER_COMPONENT'
SOURCE_REF_DUPLICATE = 'LAB_SOURCE_REF_DUPLICATE'
SOURCE_REF_NOT_IN_PACKET = 'LAB_SOURCE_REF_NOT_IN_PACKET'
ZERO_DENOMINATOR_NOT_ZERO_PERCENT = 'LAB_ZERO_DENOMINATOR_NOT_ZERO_PERCENT'


class LabMeasurementSpec(StrictModel):
    """Test-only strict model for what the live ``Measurement`` cannot carry.

    ``extra='forbid'`` and ``strict=True`` are inherited from ``StrictModel`` so
    an unknown or coerced field fails instead of being silently dropped.
    """
    measurement_id: str = Field(min_length=1, max_length=100)
    instrument_version: str = Field(min_length=1, max_length=100)
    test_only: bool
    fielding_authorized: bool
    scientific_accepted: bool
    owner_approved_for_publication: bool
    production_bank_authority_verified: bool
    qg_research_comparison_authorized: bool
    construct_name: str = Field(min_length=1, max_length=500)
    population: str = Field(min_length=1, max_length=500)
    timeframe: str = Field(min_length=1, max_length=500)
    stimulus: str = Field(min_length=1, max_length=2000)
    response_options: list[str] = Field(min_length=2, max_length=12)
    response_codes: list[str] = Field(min_length=2, max_length=12)
    numerator_codes: list[str] = Field(min_length=1, max_length=12)
    denominator_codes: list[str] = Field(min_length=1, max_length=12)
    excluded_response_states: list[str] = Field(min_length=1, max_length=12)
    denominator: str = Field(min_length=1, max_length=500)
    limitations: str = Field(min_length=1, max_length=1000)

    def to_contract(self, source_refs: list[str], uncertainty_version: str) -> Measurement:
        """Return a real live-contract measurement; no authority is implied."""
        return Measurement(
            uncertainty_version=uncertainty_version,
            construct=self.construct_name,
            population=self.population,
            timeframe=self.timeframe,
            stimulus=self.stimulus,
            response_options=list(self.response_options),
            response_codes=list(self.response_codes),
            routing={code: 'END' for code in self.response_codes},
            denominator=self.denominator,
            source_refs=list(source_refs),
            limitations=self.limitations,
        )


def canonical_spec() -> LabMeasurementSpec:
    """The single canonical synthetic candidate, every approval flag False."""
    return LabMeasurementSpec(
        measurement_id=MEASUREMENT_ID,
        instrument_version=INSTRUMENT_VERSION,
        test_only=True,
        **APPROVAL_FLAGS,
        construct_name=('Hypothetical stated acceptability of RM13 for an exactly described '
                   '12 oz takeaway iced latte'),
        population=('Synthetic eligible respondents flagged synthetic_eligibility=true in a '
                    'disposable test cluster; no real sampling frame is authorized'),
        timeframe=('Judgment at the moment the respondent views the hypothetical offer; no '
                   'future purchase window is inferred'),
        stimulus='Hypothetical offer: a 12 oz takeaway iced latte priced at RM13.',
        response_options=['Acceptable', 'Not acceptable', "Don't know",
                          'Prefer not to answer'],
        response_codes=['ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW', 'REFUSED'],
        numerator_codes=['ACCEPTABLE'],
        denominator_codes=['ACCEPTABLE', 'NOT_ACCEPTABLE'],
        excluded_response_states=['DONT_KNOW', 'REFUSED', 'SKIPPED', 'NOT_APPLICABLE',
                                  'MISSING', 'INVALID'],
        denominator=('Count of eligible in-scope respondents answering ACCEPTABLE or '
                     'NOT_ACCEPTABLE; DONT_KNOW, REFUSED, SKIPPED, NOT_APPLICABLE, MISSING '
                     'and INVALID excluded and reported separately'),
        limitations=('Sample-descriptive only: X of Y eligible respondents described the fixed '
                     'RM13 offer as acceptable. Not a demand, willingness-to-pay, sales, '
                     'profitability or GEO estimate, and not generalizable beyond the sample.'),
    )


def _stimulus_omits_offer(text: str) -> bool:
    lowered = text.lower()
    return any(component.lower() not in lowered for component in OFFER_COMPONENTS)


def validate_lab_measurement(measurement: Measurement, spec: LabMeasurementSpec,
                             packet_refs, *, sample=None) -> None:
    """Deterministic validator; raises ``ValueError`` with one fixed machine code.

    ``packet_refs`` is the set of references the real packet actually contains
    (answer revision ids, ``source_id@version`` strings and the confirmed
    uncertainty id). ``sample`` is optional observed output from
    ``describe_sample``; when supplied it proves that a zero denominator was not
    rendered as zero percent.
    """
    flags = {name: getattr(spec, name) for name in APPROVAL_FLAGS}
    if any(value is not False for value in flags.values()):
        raise ValueError(APPROVAL_FLAG_SET)
    if spec.instrument_version != INSTRUMENT_VERSION:
        raise ValueError(INSTRUMENT_VERSION_DRIFT)
    if not measurement.denominator.strip() or not spec.denominator_codes:
        raise ValueError(DENOMINATOR_EMPTY)

    codes = measurement.response_codes
    options = measurement.response_options
    invalid = (len(codes) != len(options)
               or len(set(codes)) != len(codes)
               or len(set(options)) != len(options)
               or set(measurement.routing) != set(codes)
               or list(spec.response_codes) != list(codes)
               or list(spec.response_options) != list(options)
               or not set(spec.numerator_codes) <= set(codes)
               or not set(spec.denominator_codes) <= set(codes))
    if invalid:
        raise ValueError(RESPONSE_CODES_INVALID)

    if (not spec.numerator_codes
            or not set(spec.numerator_codes) < set(spec.denominator_codes)):
        raise ValueError(ESTIMAND_INVALID)

    separate = (set(spec.denominator_codes).isdisjoint(spec.excluded_response_states)
                and set(codes) - set(spec.denominator_codes)
                <= set(spec.excluded_response_states))
    if not separate:
        raise ValueError(NONRESPONSE_NOT_SEPARATE)

    if _stimulus_omits_offer(measurement.stimulus) or _stimulus_omits_offer(spec.stimulus):
        raise ValueError(STIMULUS_OMITS_OFFER_COMPONENT)

    refs = list(measurement.source_refs)
    if len(set(refs)) != len(refs):
        raise ValueError(SOURCE_REF_DUPLICATE)
    if not set(refs) <= set(packet_refs):
        raise ValueError(SOURCE_REF_NOT_IN_PACKET)

    if sample is not None and sample.get('denominator') == 0 and sample.get('percent') is not None:
        raise ValueError(ZERO_DENOMINATOR_NOT_ZERO_PERCENT)


def describe_sample(responses, spec: LabMeasurementSpec) -> dict:
    """Numerator, denominator, percent and per-state excluded counts.

    A zero denominator yields ``percent=None``; it is never rendered as 0.0.
    """
    known = set(spec.response_codes) | set(spec.excluded_response_states)
    if any(response not in known for response in responses):
        raise ValueError(RESPONSE_CODES_INVALID)
    numerator = sum(1 for response in responses if response in spec.numerator_codes)
    denominator = sum(1 for response in responses if response in spec.denominator_codes)
    percent = None if denominator == 0 else round(100.0 * numerator / denominator, 1)
    excluded_counts = {state: sum(1 for response in responses if response == state)
                       for state in spec.excluded_response_states}
    return {'numerator': numerator, 'denominator': denominator, 'percent': percent,
            'excluded_counts': excluded_counts}
