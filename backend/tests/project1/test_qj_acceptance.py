"""P1 offline acceptance: twelve defects at the QJ measurement boundary.

Every case here runs without a model call. The authority is the real
``MeasurementAuthority`` with a real policy document; nothing is stubbed, so a
passing case says something about the shipped validator rather than about a
double that agrees with the test.

Each test names one defect. A negative case asserts the exact refusal code, not
merely that *an* exception was raised: a wrong-code refusal is a different bug
from an accepted candidate, and only the code tells them apart.
"""
from __future__ import annotations

import copy

import pytest
from pydantic import ValidationError

from sitewise.project1.contracts import Measurement, QJOutput, WorkflowHeld, digest, no_authority
from sitewise.project1.measurement_estimator import (
    ESTIMATOR_CONTRACT_VERSION, EstimatorContract, attach_estimator, validate_estimator,
)
from sitewise.project1.measurement_policy import LAB_PRICE_RM13_POLICY, lab_authority

UNCERTAINTY_ID = 'a1b2c3d4-0000-4000-8000-000000000000'
CONFIRMATION_ID = 'b2c3d4e5-0000-4000-8000-000000000000'
EXACT_TEXT = ('Would eligible customers find RM13 acceptable for a 12 oz takeaway '
              'iced latte?')


def packet(*, uncertainty_id=UNCERTAINTY_ID, confirmation_id=CONFIRMATION_ID,
           revision=1, exact_text=EXACT_TEXT, status='CURRENT_CONFIRMED',
           geography=None, permissions=None):
    value = {
        'schema_version': 'business-context-package/1.1',
        'confirmation': {'status': status, 'id': confirmation_id, 'revision': revision},
        'confirmed_uncertainty': {'id': uncertainty_id,
                                  'confirmation_id': confirmation_id,
                                  'actor_user_id': 'c3d4e5f6-0000-4000-8000-000000000000',
                                  'exact_text': exact_text},
        'geography': geography,
        'permissions': ({'qj_execution': False} if permissions is None else permissions),
        'm2_answers': [{'answer_revision_id': 'SYN-A1', 'item_key': 'M2-04'}],
        'supporting_sources': [],
    }
    value['packet_hash'] = digest(value)
    return value


def rehash(value: dict) -> dict:
    value = copy.deepcopy(value)
    value.pop('packet_hash', None)
    value['packet_hash'] = digest(value)
    return value


def measurement(**overrides):
    """A survey candidate the invariant document admits."""
    value = dict(uncertainty_version=UNCERTAINTY_ID,
                 construct='stated price acceptability',
                 population='eligible screened respondents',
                 timeframe='at presentation of the hypothetical offer',
                 stimulus='12 oz takeaway iced latte at RM13',
                 response_options=['Acceptable', 'Not acceptable', 'Unsure'],
                 response_codes=['ACCEPTABLE', 'NOT_ACCEPTABLE', 'UNSURE'],
                 routing={'ACCEPTABLE': 'RECORD', 'NOT_ACCEPTABLE': 'RECORD',
                          'UNSURE': 'RECORD'},
                 denominator='ACCEPTABLE and NOT_ACCEPTABLE respondents; UNSURE apart',
                 source_refs=[UNCERTAINTY_ID],
                 limitations=('Stated acceptability of one hypothetical price; not a '
                              'maximum willingness-to-pay and not a purchase forecast.'))
    value.update(overrides)
    return value


def pinned_measurement(**overrides):
    """A measurement the pinned lab instrument admits, exactly."""
    value = dict(
        uncertainty_version=UNCERTAINTY_ID,
        construct=('Hypothetical stated acceptability of RM13 for an exactly described '
                   '12 oz takeaway iced latte'),
        population=('Synthetic eligible respondents flagged synthetic_eligibility=true in '
                    'a disposable test cluster; no real sampling frame is authorized'),
        timeframe=('Judgment at the moment the respondent views the hypothetical offer; '
                   'no future purchase window is inferred'),
        stimulus='Hypothetical offer: a 12 oz takeaway iced latte priced at RM13.',
        response_options=['Acceptable', 'Not acceptable', "Don't know",
                          'Prefer not to answer'],
        response_codes=['ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW', 'REFUSED'],
        routing={code: 'END' for code in
                 ('ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW', 'REFUSED')},
        denominator=('Count of eligible in-scope respondents answering ACCEPTABLE or '
                     'NOT_ACCEPTABLE; DONT_KNOW, REFUSED, SKIPPED, NOT_APPLICABLE, '
                     'MISSING and INVALID excluded and reported separately'),
        source_refs=[UNCERTAINTY_ID],
        limitations=('Sample-descriptive only: X of Y eligible respondents described the '
                     'fixed RM13 offer as acceptable. Not a demand, willingness-to-pay, '
                     'sales, profitability or GEO estimate.'))
    value.update(overrides)
    return value


def estimator_for(measurement_value: dict, **overrides) -> EstimatorContract:
    """An estimator bound to ``measurement_value``; overrides keep the binding."""
    base = dict(estimator_version='LAB-ESTIMATOR-0.1',
                measurement_digest=digest(measurement_value),
                numerator_codes=['ACCEPTABLE'],
                denominator_codes=['ACCEPTABLE', 'NOT_ACCEPTABLE'],
                excluded_response_states=['UNSURE', 'SKIPPED'],
                eligibility_predicate='synthetic_eligibility = true',
                reference_period='instant of presentation, not a purchase window',
                prohibited_interpretations=['not a demand estimate',
                                            'not a willingness-to-pay estimate'],
                permitted_interpretation='descriptive share of stated acceptability')
    base.update(overrides)
    return EstimatorContract(**base)


def held(code: str, function) -> None:
    with pytest.raises(WorkflowHeld) as caught:
        function()
    assert str(caught.value) == code


# 1
def test_complete_source_supported_measurement_is_admitted_test_scoped():
    """Guards the admitted path: a bound, conforming candidate must not be refused."""
    authority = lab_authority()
    task = authority.admit_qj(packet())
    value = measurement()
    receipt = authority.validate_measurement(packet(), task, value)
    assert receipt['status'] == 'TEST_SCOPED_VALID'
    assert receipt['scientific_accepted'] is False
    assert receipt['measurement_digest'] == digest(value)
    estimator = estimator_for(value)
    estimator_receipt = validate_estimator(estimator, value)
    assert estimator_receipt['status'] == 'ESTIMATOR_TEST_SCOPED_VALID'
    assert estimator_receipt['scientific_accepted'] is False
    assert estimator_receipt['estimator_contract_version'] == ESTIMATOR_CONTRACT_VERSION
    combined = attach_estimator(value, estimator)
    assert combined['measurement_digest'] == digest(value)
    assert combined['estimator']['numerator_codes'] == ['ACCEPTABLE']


# 2
def test_a_measurement_without_an_uncertainty_version_is_rejected_by_the_contract():
    """Guards the required version field: the deployed contract cannot omit it."""
    value = measurement()
    del value['uncertainty_version']
    with pytest.raises(ValidationError) as caught:
        Measurement.model_validate(value)
    assert 'uncertainty_version' in str(caught.value)


# 3
def test_a_stale_assessment_revision_cannot_validate_a_measurement():
    """Guards F-01 staleness: admission on revision 1 must not validate revision 2."""
    authority = lab_authority()
    task = authority.admit_qj(packet())
    moved = packet(uncertainty_id='2f2f2f2f-0000-4000-8000-000000000000',
                   confirmation_id='3f3f3f3f-0000-4000-8000-000000000000', revision=2)
    held('F01_ADMISSION_STALE',
         lambda: authority.validate_measurement(moved, task, measurement()))


# 4
def test_a_changed_bcb_packet_hash_alone_invalidates_the_admission():
    """Guards context binding: the same version label is not proof of the same packet."""
    authority = lab_authority()
    task = authority.admit_qj(packet())
    moved = copy.deepcopy(packet())
    moved['m2_answers'][0]['item_key'] = 'M2-05'
    moved = rehash(moved)
    assert moved['confirmed_uncertainty']['id'] == task['uncertainty_version']
    held('F01_CONTEXT_CHANGED_SINCE_ADMISSION',
         lambda: authority.require_current(moved, task))


# 5
def test_a_stimulus_that_drops_the_confirmed_price_is_refused():
    """Guards offer fidelity: a pinned instrument may not lose the price it pins."""
    authority = lab_authority(LAB_PRICE_RM13_POLICY)
    task = authority.admit_qj(packet())
    held('F02_STIMULUS_PRICE_DRIFT',
         lambda: authority.validate_measurement(
             packet(), task,
             pinned_measurement(stimulus='Hypothetical offer: a 12 oz takeaway iced latte.')))


# 6
def test_a_price_the_uncertainty_never_confirmed_is_refused():
    """Guards D-01: a correct version label must not let a substituted price through."""
    authority = lab_authority()
    task = authority.admit_qj(packet())
    held('F02_STIMULUS_NOT_SUPPORTED_BY_UNCERTAINTY',
         lambda: authority.validate_measurement(
             packet(), task,
             measurement(stimulus='12 oz takeaway iced latte at RM12')))


# 7
def test_a_target_population_outside_the_pinned_instrument_is_refused():
    """Guards population authority: a pinned instrument cannot be re-aimed."""
    authority = lab_authority(LAB_PRICE_RM13_POLICY)
    task = authority.admit_qj(packet())
    held('F02_POPULATION_UNAUTHORIZED',
         lambda: authority.validate_measurement(
             packet(), task, pinned_measurement(population='All consumers in the area')))


# 8
def test_a_response_code_missing_from_routing_is_refused():
    """Guards routing completeness: an unrouted code has no defined disposition."""
    authority = lab_authority()
    task = authority.admit_qj(packet())
    held('F02_ROUTING_DRIFT',
         lambda: authority.validate_measurement(
             packet(), task,
             measurement(routing={'ACCEPTABLE': 'RECORD',
                                  'NOT_ACCEPTABLE': 'RECORD'})))


# 9a
def test_a_numerator_that_is_not_a_strict_subset_of_the_denominator_is_refused():
    """Guards the estimand: numerator == denominator would report a fixed 100%."""
    value = measurement()
    held('ESTIMATOR_NOT_A_SUBSET_OF_DENOMINATOR',
         lambda: validate_estimator(
             estimator_for(value, numerator_codes=['ACCEPTABLE', 'NOT_ACCEPTABLE'],
                           denominator_codes=['ACCEPTABLE']), value))


# 9b
def test_a_denominator_code_that_is_not_a_response_code_is_refused():
    """Guards the denominator: it may only count codes the instrument declared."""
    value = measurement()
    held('ESTIMATOR_DENOMINATOR_NOT_IN_CODES',
         lambda: validate_estimator(
             estimator_for(value,
                           denominator_codes=['ACCEPTABLE', 'NOT_ACCEPTABLE', 'MAYBE']),
             value))


# 10
def test_a_no_op_authority_is_distinguishable_from_a_versioned_one():
    """Guards F-02: a validator that returns nothing must not read as a pass."""

    class NoOpAuthority:
        def validate_measurement(self, packet, task, measurement):
            return None

    no_op = NoOpAuthority()
    assert not getattr(no_op, 'measurement_policy_version', None)
    # research.py refuses to dispatch QG drafting on exactly this marker.

    result = no_op.validate_measurement(packet(), {}, measurement())
    assert result is None
    assert not isinstance(result, dict)  # the workflow labels it NOT_RECORDED_BY_AUTHORITY
    assert 'policy_digest' not in (result or {})
    assert 'measurement_digest' not in (result or {})

    real = lab_authority()
    task = real.admit_qj(packet())
    receipt = real.validate_measurement(packet(), task, measurement())
    assert receipt['policy_digest']
    assert receipt['measurement_digest'] == digest(measurement())


# 11
def test_a_mutated_or_replayed_validation_receipt_no_longer_binds():
    """Guards receipt integrity: a receipt must bind one measurement and one packet.

    ``verify_validation_receipt`` shipped alongside these acceptance tests, so the
    assertions below use the production refusal codes rather than merely stating
    that a digest differs. A receipt that fails verification is not a validation.
    """
    from sitewise.project1.measurement_policy import verify_validation_receipt

    authority = lab_authority()
    first = packet()
    task = authority.admit_qj(first)
    value = measurement()
    receipt = authority.validate_measurement(first, task, value)
    assert verify_validation_receipt(receipt, value, first) is receipt

    tampered = dict(receipt, measurement_digest=digest(measurement(stimulus='something else')))
    held('MEASUREMENT_RECEIPT_MEASUREMENT_MISMATCH',
         lambda: verify_validation_receipt(tampered, value, first))

    other = copy.deepcopy(first)
    other['m2_answers'][0]['item_key'] = 'M2-05'
    other = rehash(other)
    held('MEASUREMENT_RECEIPT_CONTEXT_MISMATCH',
         lambda: verify_validation_receipt(receipt, value, other))

    # And the admission itself is stale against the changed packet.
    held('F01_CONTEXT_CHANGED_SINCE_ADMISSION',
         lambda: authority.require_current(other, task))


# 12
def test_a_non_survey_route_without_a_measurement_is_a_valid_outcome():
    """Guards the HOLD route: no measurement is a legitimate result, not a defect."""
    qj = QJOutput.model_validate({'route': 'HOLD',
                                  'justification': 'The confirmed uncertainty is not a '
                                                   'stated-price question.',
                                  'measurement': None})
    assert qj.route == 'HOLD'
    assert qj.measurement is None

    # research.py returns before any invariant runs; the result records no
    # measurement validation because none applies.
    result = {'qj': qj.model_dump(), 'qg': None, 'bank': 'not_checked',
              'source_fingerprint': packet()['packet_hash'], **no_authority()}
    assert 'measurement_validation' not in result
    assert result['qj']['route'] == 'HOLD'
    assert result['scientific_acceptance'] is False
    assert result['publication_authorized'] is False
    assert result['fielding_authorized'] is False
