"""The QJ capture validator must be the repository's own rule set.

``run_qj_call.validate_output`` previously reimplemented ``validate_measurement``
locally, which meant a capture could be judged by rules the workflow itself does
not use. It now delegates. These tests pin that behaviour: the same input must
produce the same refusal codes the workflow would produce, and the expected
``uncertainty_version`` must come from the packet rather than from the model.
"""
from __future__ import annotations

from sitewise.project1.contracts import digest
from run_qj_call import validate_output


def packet():
    value = {'confirmation': {'status': 'CURRENT_CONFIRMED', 'id': 'SYN-CONF-1',
                              'revision': 1},
             'confirmed_uncertainty': {'id': 'SYN-UC-1', 'confirmation_id': 'SYN-CONF-1',
                                       'exact_text': 'Would eligible customers find RM13 '
                                                     'acceptable for a 12 oz takeaway iced '
                                                     'latte?'},
             'm2_answers': [{'answer_revision_id': 'SYN-A1', 'item_key': 'M2-04'}],
             'supporting_sources': []}
    value['packet_hash'] = digest(value)
    return value


def measurement(**overrides):
    value = dict(uncertainty_version='SYN-UC-1', construct='stated preference',
                 population='local adults', timeframe='next month',
                 stimulus='12 oz latte at RM13',
                 response_options=['Prefer', 'Do not prefer', 'Unsure'],
                 response_codes=['A', 'B', 'U'],
                 routing={'A': 'END', 'B': 'END', 'U': 'END'},
                 denominator='A and B substantive respondents; U reported separately',
                 source_refs=['SYN-A1', 'SYN-UC-1'],
                 limitations='Stated preference does not establish sales.')
    value.update(overrides)
    return value


def survey(**overrides):
    return {'route': 'CUSTOMER_SURVEY_CANDIDATE', 'measurement': measurement(**overrides)}


def test_complete_measurement_passes():
    result = validate_output(survey(), packet())
    assert result['valid'] is True and result['codes'] == []
    assert result['validator'] == 'sitewise.project1.research.validate_measurement'
    assert result['uncertainty_version_expected'] == 'SYN-UC-1'
    assert result['scientific_acceptance'] is False


def test_invented_source_reference_is_refused():
    assert validate_output(survey(source_refs=['SYN-A1', 'INVENTED-REF']),
                           packet())['codes'] == ['MEASUREMENT_SOURCE_MISMATCH']


def test_duplicate_source_reference_is_refused():
    assert validate_output(survey(source_refs=['SYN-A1', 'SYN-A1']),
                           packet())['codes'] == ['MEASUREMENT_SOURCE_MISMATCH']


def test_uncertainty_version_comes_from_the_packet_not_the_output():
    result = validate_output(survey(uncertainty_version='SYN-UC-9'), packet())
    assert result['codes'] == ['MEASUREMENT_SOURCE_MISMATCH']


def test_routing_must_cover_every_code():
    result = validate_output(survey(routing={'A': 'END', 'B': 'END'}), packet())
    assert result['codes'] == ['MEASUREMENT_CODES_OR_ROUTING_INVALID']


def test_parallel_lists_must_align():
    result = validate_output(survey(response_codes=['A', 'B']), packet())
    assert result['codes'] == ['MEASUREMENT_CODES_OR_ROUTING_INVALID']


def test_non_survey_route_carrying_a_measurement_is_refused():
    result = validate_output({'route': 'HOLD', 'measurement': measurement()}, packet())
    assert result['codes'] == ['NON_SURVEY_MEASUREMENT_FORBIDDEN']


def test_survey_route_without_a_measurement_is_refused():
    result = validate_output({'route': 'CUSTOMER_SURVEY_CANDIDATE', 'measurement': None},
                             packet())
    assert result['codes'] == ['SURVEY_MEASUREMENT_INCOMPLETE']


def test_extra_key_fails_closed_without_persisting_the_reason():
    result = validate_output(survey(invented_field='SYNTHETIC_SECRET'), packet())
    assert result['codes'] == ['MEASUREMENT_SCHEMA_INVALID']
    assert 'SYNTHETIC_SECRET' not in repr(result)
