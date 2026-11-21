"""Fast, database-free proofs for the provisional LAB-PRICE-RM13-0.1 candidate."""
import pytest

from lab_measurement_v0_1 import (
    APPROVAL_FLAGS, APPROVAL_FLAG_SET, DENOMINATOR_EMPTY, ESTIMAND_INVALID,
    INSTRUMENT_VERSION_DRIFT, MEASUREMENT_ID, NONRESPONSE_NOT_SEPARATE,
    PRODUCTION_ADOPTION, RESPONSE_CODES_INVALID, SOURCE_REF_DUPLICATE,
    SOURCE_REF_NOT_IN_PACKET, STATUS, STIMULUS_OMITS_OFFER_COMPONENT,
    ZERO_DENOMINATOR_NOT_ZERO_PERCENT, canonical_spec, describe_sample,
    validate_lab_measurement,
)

PACKET_REFS = {'UNC-1', 'REF-A'}


def baseline():
    spec = canonical_spec()
    return spec, spec.to_contract(['UNC-1'], 'UNC-1')


def test_no_authority_is_claimed():
    spec = canonical_spec()
    assert spec.measurement_id == MEASUREMENT_ID == 'LAB-PRICE-RM13-0.1'
    assert STATUS == 'PROVISIONAL_TEST_ONLY_NOT_APPROVED'
    assert PRODUCTION_ADOPTION is False
    assert spec.test_only is True
    assert all(getattr(spec, name) is False for name in APPROVAL_FLAGS)
    assert all(value is False for value in APPROVAL_FLAGS.values())


def test_valid_baseline_passes_and_is_a_real_contract_measurement():
    from sitewise.project1.contracts import Measurement
    spec, measurement = baseline()
    assert isinstance(measurement, Measurement)
    assert measurement.construct_name == spec.construct_name
    assert measurement.response_codes == spec.response_codes
    assert set(measurement.routing) == set(spec.response_codes)
    assert all(target == 'END' for target in measurement.routing.values())
    assert 'synthetic_eligibility=true' in measurement.population
    validate_lab_measurement(measurement, spec, PACKET_REFS)


def test_unknown_field_is_rejected_by_the_strict_test_model():
    from pydantic import ValidationError
    with pytest.raises(ValidationError):
        type(canonical_spec())(**{**canonical_spec().model_dump(), 'invented_field': True})


def test_approval_flag_set_is_refused():
    spec, measurement = baseline()
    broken = spec.model_copy(update={'fielding_authorized': True})
    with pytest.raises(ValueError) as refused:
        validate_lab_measurement(measurement, broken, PACKET_REFS)
    assert str(refused.value) == APPROVAL_FLAG_SET


def test_instrument_version_drift_is_refused():
    spec, measurement = baseline()
    broken = spec.model_copy(update={'instrument_version': 'M2V1-20990101-9'})
    with pytest.raises(ValueError) as refused:
        validate_lab_measurement(measurement, broken, PACKET_REFS)
    assert str(refused.value) == INSTRUMENT_VERSION_DRIFT


def test_empty_denominator_is_refused():
    spec, measurement = baseline()
    broken = measurement.model_copy(update={'denominator': '   '})
    with pytest.raises(ValueError) as refused:
        validate_lab_measurement(broken, spec, PACKET_REFS)
    assert str(refused.value) == DENOMINATOR_EMPTY


def test_response_code_count_mismatch_is_refused():
    spec, measurement = baseline()
    broken = measurement.model_copy(
        update={'response_codes': ['ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW']})
    with pytest.raises(ValueError) as refused:
        validate_lab_measurement(broken, spec, PACKET_REFS)
    assert str(refused.value) == RESPONSE_CODES_INVALID


def test_routing_must_cover_every_code():
    spec, measurement = baseline()
    broken = measurement.model_copy(update={'routing': {'ACCEPTABLE': 'END'}})
    with pytest.raises(ValueError) as refused:
        validate_lab_measurement(broken, spec, PACKET_REFS)
    assert str(refused.value) == RESPONSE_CODES_INVALID


def test_numerator_must_be_a_strict_subset_of_denominator():
    spec, measurement = baseline()
    broken = spec.model_copy(
        update={'numerator_codes': ['ACCEPTABLE', 'NOT_ACCEPTABLE']})
    with pytest.raises(ValueError) as refused:
        validate_lab_measurement(measurement, broken, PACKET_REFS)
    assert str(refused.value) == ESTIMAND_INVALID


def test_nonresponse_must_be_reported_separately():
    spec, measurement = baseline()
    broken = spec.model_copy(update={'excluded_response_states': ['SKIPPED']})
    with pytest.raises(ValueError) as refused:
        validate_lab_measurement(measurement, broken, PACKET_REFS)
    assert str(refused.value) == NONRESPONSE_NOT_SEPARATE


def test_stimulus_must_keep_every_offer_component():
    spec, measurement = baseline()
    broken = measurement.model_copy(
        update={'stimulus': 'Hypothetical offer: an iced latte priced at RM13.'})
    with pytest.raises(ValueError) as refused:
        validate_lab_measurement(broken, spec, PACKET_REFS)
    assert str(refused.value) == STIMULUS_OMITS_OFFER_COMPONENT


def test_source_ref_must_exist_in_the_packet():
    spec, measurement = baseline()
    broken = measurement.model_copy(update={'source_refs': ['NOT-IN-PACKET']})
    with pytest.raises(ValueError) as refused:
        validate_lab_measurement(broken, spec, PACKET_REFS)
    assert str(refused.value) == SOURCE_REF_NOT_IN_PACKET


def test_duplicate_source_ref_is_refused():
    spec, measurement = baseline()
    broken = measurement.model_copy(update={'source_refs': ['REF-A', 'REF-A']})
    with pytest.raises(ValueError) as refused:
        validate_lab_measurement(broken, spec, PACKET_REFS)
    assert str(refused.value) == SOURCE_REF_DUPLICATE


def test_zero_denominator_must_not_be_reported_as_zero_percent():
    spec, measurement = baseline()
    empty = describe_sample([], spec)
    assert empty['denominator'] == 0 and empty['percent'] is None
    validate_lab_measurement(measurement, spec, PACKET_REFS, sample=empty)
    with pytest.raises(ValueError) as refused:
        validate_lab_measurement(measurement, spec, PACKET_REFS,
                                 sample={'denominator': 0, 'percent': 0.0})
    assert str(refused.value) == ZERO_DENOMINATOR_NOT_ZERO_PERCENT


def test_describe_sample_excludes_nonresponse_and_reports_each_state():
    spec = canonical_spec()
    result = describe_sample(
        ['ACCEPTABLE', 'ACCEPTABLE', 'NOT_ACCEPTABLE',
         'DONT_KNOW', 'REFUSED', 'SKIPPED'], spec)
    assert result['numerator'] == 2
    assert result['denominator'] == 3
    assert result['percent'] == 66.7
    assert result['excluded_counts'] == {
        'DONT_KNOW': 1, 'REFUSED': 1, 'SKIPPED': 1,
        'NOT_APPLICABLE': 0, 'MISSING': 0, 'INVALID': 0}


def test_describe_sample_rejects_an_unregistered_response():
    with pytest.raises(ValueError) as refused:
        describe_sample(['MAYBE'], canonical_spec())
    assert str(refused.value) == RESPONSE_CODES_INVALID
