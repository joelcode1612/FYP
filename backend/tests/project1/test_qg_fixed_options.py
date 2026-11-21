"""Synthetic structure checks only; not proof of respondent compatibility."""
from types import SimpleNamespace

import pytest

from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.direct_qg_service import DirectQgService
from sitewise.project1.qg_fixed_options import (
    FIXED_OPTION_CONTRACT, validate_fixed_measurement,
)


def measurement(kind='SINGLE_CHOICE'):
    return dict(contract_version=FIXED_OPTION_CONTRACT, response_format=kind,
        construct='Stated interest', population='Adults in the test fixture',
        options=[dict(code='YES', label='Yes', order=0),
                 dict(code='NO', label='No', order=1)],
        min_selections=1, max_selections=1, interpretation='Proposed response categories',
        limitations='Synthetic proposal; no customer observations.')


def check(value, *, period_required=False):
    return validate_fixed_measurement(value, supported_formats=frozenset({
        'SINGLE_CHOICE', 'BINARY_CHOICE', 'ORDERED_SCALE',
        'NUMERIC_RANGE_OPTIONS', 'MULTIPLE_CHOICE'}), period_required=period_required)


@pytest.mark.parametrize('kind', ['SINGLE_CHOICE', 'BINARY_CHOICE', 'ORDERED_SCALE'])
def test_valid_fixed_options(kind):
    assert check(measurement(kind)).response_format == kind


@pytest.mark.parametrize('kind', ['OPEN_TEXT', 'NUMERIC', 'RANKING', 'MATRIX', 'DATE'])
def test_unsupported_format_is_refused(kind):
    with pytest.raises(WorkflowHeld, match='UNSUPPORTED_FORMAT'):
        check(measurement(kind))


def test_no_respondent_format_is_assumed_verified():
    with pytest.raises(WorkflowHeld, match='UNSUPPORTED_FORMAT'):
        validate_fixed_measurement(measurement(), supported_formats=frozenset(), period_required=False)


@pytest.mark.parametrize('change,code', [
    (lambda x: x['options'][1].update(code='YES'), 'QG_RESPONSE_CODING_DRIFT'),
    (lambda x: x['options'][1].update(label=' yes '), 'QG_RESPONSE_CODING_DRIFT'),
    (lambda x: x['options'][1].update(order=0), 'QG_OPTION_ORDER_INVALID'),
    (lambda x: x.update(population=' '), 'QG_MEASUREMENT_CONTEXT_REQUIRED'),
    (lambda x: x.update(max_selections=2), 'QG_SELECTION_CONSTRAINT_INVALID'),
])
def test_bad_measurement_is_refused(change, code):
    value = measurement()
    change(value)
    with pytest.raises(WorkflowHeld, match=code):
        check(value)


def test_reference_period_requirement_comes_from_policy():
    with pytest.raises(WorkflowHeld, match='QG_REFERENCE_PERIOD_REQUIRED'):
        check(measurement(), period_required=True)


def test_multiple_choice_requires_coherent_limits_and_exclusives():
    value = measurement('MULTIPLE_CHOICE')
    value.update(max_selections=2, exclusive_codes=['NO'])
    assert check(value).exclusive_codes == ['NO']
    value['min_selections'] = 2
    with pytest.raises(WorkflowHeld, match='QG_SELECTION_CONSTRAINT_INVALID'):
        check(value)
    value['min_selections'] = 1
    value['exclusive_codes'] = ['NOT_AN_OPTION']
    with pytest.raises(WorkflowHeld, match='QG_SELECTION_CONSTRAINT_INVALID'):
        check(value)


def test_overlapping_ranges_are_refused():
    value = measurement('NUMERIC_RANGE_OPTIONS')
    value.update(unit='RM', reference_period='per visit')
    value['options'][0].update(lower='5', upper='10')
    value['options'][1].update(lower='10', upper='15')
    with pytest.raises(WorkflowHeld, match='QG_RANGE_OVERLAP'):
        check(value)
    value['options'][0]['upper_inclusive'] = False
    assert check(value).options[0].upper == 10


def test_service_holds_before_provider_or_context_access():
    calls = []
    service = DirectQgService(contexts=SimpleNamespace(retrieve=lambda *a: calls.append('context')),
        authority=SimpleNamespace(measurement_policy_version='TEST_ONLY'),
        runner=lambda *a, **k: calls.append('provider'), enabled=True)
    with pytest.raises(WorkflowHeld, match='QG_FIXED_OPTION_ADMISSION_UNAVAILABLE'):
        service.prepare_candidate(assessment_id='test', context_id='test', actor='test')
    assert calls == []


def test_real_workflow_fixed_candidate_adapter_with_synthetic_model_only():
    import copy
    from test_qg_contract_v2 import packet, draft, lab_authority
    from sitewise.project1.research import ResearchWorkflow

    source = packet()
    objective = {'objective_id': source['confirmed_uncertainty']['id'],
                 'text': source['confirmed_uncertainty']['exact_text']}
    population = 'Synthetic eligible respondents'
    spec = measurement()
    spec.update(population=population, options=[
        {'code': 'ACCEPTABLE', 'label': 'Acceptable', 'order': 0},
        {'code': 'NOT_ACCEPTABLE', 'label': 'Not acceptable', 'order': 1},
        {'code': 'DONT_KNOW', 'label': "Don't know", 'order': 2},
    ])
    raw = {**draft(), 'fixed_measurement': spec}
    calls = []
    def runner(stage, payload, output_type):
        calls.append((stage, payload['contract_version'], output_type.__name__))
        return copy.deepcopy(raw)
    workflow = ResearchWorkflow(SimpleNamespace(get_context=lambda _: copy.deepcopy(source)),
                                lab_authority(), None, runner)
    policy = {'policy_version': 'TEST_ONLY', 'approved_population': population,
              'objective_version': objective['objective_id'],
              'supported_formats': ['SINGLE_CHOICE'], 'period_required': False}
    result = workflow.execute_fixed_option_candidate(None, objective=objective, policy=policy)
    assert calls == [('QG', FIXED_OPTION_CONTRACT, 'FixedOptionCandidate')]
    assert result['objective_id'] == objective['objective_id']
    assert result['source_fingerprint'] == source['packet_hash']
    assert result['admission']['semantic_source_review_required'] is True
    assert not result['fielding_authorized'] and not result['publication_authorized']

    raw['question'] = 'Would you love our amazing cafe?'
    with pytest.raises(WorkflowHeld, match='QG_KNOWN_LEADING_WORDING'):
        workflow.execute_fixed_option_candidate(None, objective=objective, policy=policy)


def test_fixed_policy_cannot_be_reused_with_a_different_context():
    from test_qg_contract_v2 import packet, lab_authority
    source = packet()
    calls = []
    resolver = lambda assessment, context, actor, objective, value: {
        'assessment_id':str(assessment),'context_id':str(context),
        'objective_id':objective['objective_id'], 'assessment_revision':1,
        'context_hash':'0' * 64}
    service = DirectQgService(contexts=SimpleNamespace(retrieve=lambda *args: {'packet':source}),
        authority=lab_authority(), runner=lambda *args: calls.append('provider'),
        enabled=True, fixed_policy_resolver=resolver)
    with pytest.raises(WorkflowHeld, match='QG_FIXED_POLICY_SOURCE_MISMATCH'):
        service.prepare_candidate(assessment_id=source['assessment_id'],context_id='TEST-CONTEXT',
            actor='TEST',objective={'objective_id':source['confirmed_uncertainty']['id'], 'text':'Synthetic'})
    assert not calls


@pytest.mark.parametrize(('mutation','code'), [
    ('option_label', 'QG_FIXED_OPTION_MISMATCH'),
    ('routing', 'QG_ROUTING_TARGET_UNVERIFIED'),
    ('leading', 'QG_KNOWN_LEADING_WORDING'),
    ('population', 'QG_POPULATION_AUTHORITY_MISMATCH'),
    ('price_option', 'QG_UNSOURCED_AMOUNT'),
])
def test_fixed_candidate_rejects_invalid_proposal(mutation, code):
    from test_qg_contract_v2 import packet, draft
    from sitewise.project1.qg_contract import facts_from_packet
    from sitewise.project1.qg_fixed_options import validate_fixed_candidate
    source=packet()
    objective={'objective_id':source['confirmed_uncertainty']['id'],
               'text':source['confirmed_uncertainty']['exact_text']}
    facts=facts_from_packet(source, objective=objective)
    spec=measurement()
    spec.update(population='Synthetic', options=[
        {'code':'ACCEPTABLE','label':'Acceptable','order':0},
        {'code':'NOT_ACCEPTABLE','label':'Not acceptable','order':1},
        {'code':'DONT_KNOW','label':"Don't know",'order':2}])
    raw={**draft(), 'fixed_measurement':spec}
    if mutation=='option_label': spec['options'][0]['label']='Other'
    if mutation=='routing': raw['routing']['ACCEPTABLE']='UNKNOWN_TARGET'
    if mutation=='leading': raw['question']='Would you love our amazing cafe?'
    if mutation=='population': spec['population']='Unverified population'
    if mutation=='price_option':
        raw['response_options'][0]='RM5'
        spec['options'][0]['label']='RM5'
    with pytest.raises(WorkflowHeld, match=code):
        validate_fixed_candidate(raw,facts,supported_formats=frozenset({'SINGLE_CHOICE'}),
                                 approved_population='Synthetic',period_required=False)
