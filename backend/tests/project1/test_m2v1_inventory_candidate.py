"""No network or database: inventory remains candidate and non-authoritative."""
from uuid import uuid4
import pytest

from scripts.register_m2_v1 import definition
from sitewise.project1.m2v1_inventory_candidate import inventory


def answer(value, state='ANSWERED', revision=1):
    return {'id':uuid4(), 'value_json':value, 'answer_state':state, 'assessment_revision':revision}


def entries(answers):
    _, _, _, items = definition()
    return {x['item_key']:x for x in inventory(items, answers)['items']}


def test_missing_and_derived_do_not_invent_answer_revision():
    source = answer(['STUDENTS'])
    rows = entries({'M2V1-04':source})
    assert len(rows) == 11
    assert rows['M2V1-05']['state'] == 'DERIVED'
    assert rows['M2V1-05']['value'] == 'STUDENTS'
    assert rows['M2V1-05']['answer_revision_id'] is None
    assert rows['M2V1-05']['derived_from']['answer_revision_id'] == str(source['id'])
    assert rows['M2V1-01']['state'] == 'MISSING'
    assert rows['M2V1-11']['state'] == 'CONDITION_UNRESOLVED'


def test_explicit_states_and_conditions_are_distinct():
    rows = entries({'M2V1-02':answer('DELIVERY'), 'M2V1-08':answer(['UNKNOWN']),
                    'M2V1-09':answer(['NONE']), 'M2V1-06':answer(None, 'SKIPPED_OPTIONAL')})
    assert rows['M2V1-07']['state'] == 'NOT_APPLICABLE'
    assert rows['M2V1-11']['state'] == 'NOT_APPLICABLE'
    assert rows['M2V1-08']['value'] == ['UNKNOWN']
    assert rows['M2V1-06']['state'] == 'SKIPPED_OPTIONAL'
    assert rows['M2V1-07']['answer_revision_id'] is None


def test_incomplete_item_definitions_refused():
    _, _, _, items = definition()
    with pytest.raises(ValueError, match='Exact registered'):
        inventory(items[:-3], {})


def test_conditional_states_require_an_actual_source_answer():
    missing = entries({})
    assert missing['M2V1-05']['state'] == 'CONDITION_UNRESOLVED'
    assert missing['M2V1-07']['state'] == 'CONDITION_UNRESOLVED'
    assert missing['M2V1-10']['state'] == 'CONDITION_UNRESOLVED'
    selected = entries({'M2V1-04':answer(['UNDECIDED']), 'M2V1-09':answer(['NONE'])})
    assert selected['M2V1-05']['state'] == 'NOT_APPLICABLE'
    assert selected['M2V1-10']['state'] == 'NOT_APPLICABLE'
    assert selected['M2V1-05']['answer_revision_id'] is None
