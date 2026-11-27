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
    # The closed-ended policy, enforced by the validator rather than trusted to
    # the prompt. Each of these is a wording a model can produce even when the
    # instruction forbids it, so the refusal has to exist here.
    ('free_text', 'QG_FREE_TEXT_REQUESTED'),
    ('option_specify', 'QG_OPTION_REQUIRES_FREE_TEXT'),
    ('double_barrelled', 'QG_DOUBLE_BARRELLED_WORDING'),
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
    if mutation=='free_text':
        raw['question']='In your own words, how do you feel about this price?'
    if mutation=='option_specify':
        # Both representations, because the equality check runs first: changing
        # only one would be refused as a mismatch and never reach the wording rule.
        raw['response_options'][0]='Other, please specify'
        spec['options'][0]['label']='Other, please specify'
    if mutation=='double_barrelled':
        raw['question']=('How acceptable is this price and how often would you '
                         'buy it?')
    with pytest.raises(WorkflowHeld, match=code):
        validate_fixed_candidate(raw,facts,supported_formats=frozenset({'SINGLE_CHOICE'}),
                                 approved_population='Synthetic',period_required=False)


def test_a_proposal_shaped_answer_cannot_satisfy_the_live_validator():
    """The QG_PROPOSAL output contract is not admissible on this pathway.

    This is the reason ``qg_live.DEFAULT_PROMPT_KEY`` names the fixed-option
    prompt. A proposal-shaped answer is contract-2.0 valid — it passes
    ``validate_candidate`` — but it carries no ``fixed_measurement``, so the
    validator that guards ``m2_qg_candidates`` refuses it. A default that
    dispatched the proposal prompt would therefore reserve an attempt, pay for
    the call, and then discard the answer, which is a cost with no possible
    result.
    """
    from test_qg_contract_v2 import packet, draft
    from sitewise.project1.qg_contract import facts_from_packet
    from sitewise.project1.qg_fixed_options import validate_fixed_candidate

    source = packet()
    objective = {'objective_id': source['confirmed_uncertainty']['id'],
                 'text': source['confirmed_uncertainty']['exact_text']}
    facts = facts_from_packet(source, objective=objective)

    raw = draft()
    assert 'fixed_measurement' not in raw

    with pytest.raises(WorkflowHeld, match='QG_FIXED_MEASUREMENT_REQUIRED'):
        validate_fixed_candidate(raw, facts,
                                 supported_formats=frozenset({'SINGLE_CHOICE'}),
                                 approved_population='Synthetic',
                                 period_required=False)


@pytest.mark.parametrize(('question','options','code'), [    ('In your own words, what do you think about this price?', ['Yes','No'],
     'QG_FREE_TEXT_REQUESTED'),
    ('Please describe your experience at our cafe.', ['Good','Bad'],
     'QG_FREE_TEXT_REQUESTED'),
    ('Any comments?', ['Yes','No'], 'QG_FREE_TEXT_REQUESTED'),
    ('Tell us why you chose this option.', ['A','B'], 'QG_FREE_TEXT_REQUESTED'),
    ('How often do you buy coffee?', ['Daily','Other, please specify'],
     'QG_OPTION_REQUIRES_FREE_TEXT'),
    ('How often do you buy coffee?', ['Daily','Other (specify)'],
     'QG_OPTION_REQUIRES_FREE_TEXT'),
    ('How satisfied are you with the price and how often would you buy it?',
     ['A','B'], 'QG_DOUBLE_BARRELLED_WORDING'),
    ('Would you buy this coffee? And would you collect it in store?',
     ['Yes','No'], 'QG_DOUBLE_BARRELLED_WORDING'),
    ('Rate the taste and rate the price.', ['1','2'],
     'QG_DOUBLE_BARRELLED_WORDING'),
])
def test_structured_wording_is_refused(question, options, code):
    """A question that cannot be answered by selecting an option is refused.

    The policy admits only closed-ended questions with predefined options, so
    these are contract violations rather than style notes: the respondent would
    have nowhere to type, and the answer could not be counted.
    """
    from sitewise.project1.qg_fixed_options import validate_structured_wording
    with pytest.raises(WorkflowHeld, match=code):
        validate_structured_wording(question, options)


@pytest.mark.parametrize(('question','options'), [
    ('How much would you be willing to pay for a 12 oz filter coffee?',
     ['Less than RM7.00','RM7.00 to RM8.99','RM9.00 to RM10.99','RM11.00 or more']),
    ('Would you buy this coffee at RM9.50?',
     ['Yes, definitely','Yes, probably','No, probably not','No, definitely not']),
    # One decision with two clauses is not two questions: the narrow rule matters
    # or the check would reject ordinary closed-ended wording.
    ('Would you buy this coffee and collect it from the counter?', ['Yes','No']),
    ('How often do you buy a hot drink between 8am and 10am?',
     ['Every day','A few times a week','Rarely','Never']),
    # "Other" alone is a closed answer ("none of these apply") and stays legal.
    ('Which of these features would you use?',
     ['Pre-order collection','Seating','None of these','Other']),
    ('How acceptable is a price of RM9.50 for a 12 oz coffee?',
     ['Very acceptable','Acceptable','Not acceptable']),
])
def test_structured_wording_is_accepted(question, options):
    """A false refusal costs a regeneration, so the rules stay narrow."""
    from sitewise.project1.qg_fixed_options import validate_structured_wording
    validate_structured_wording(question, options)


# ---------------------------------------------------------------------------
# The response projection is derived, not demanded twice
# ---------------------------------------------------------------------------
# A candidate carries its option set twice: ``fixed_measurement.options`` and the
# contract-2.0 ``response_codes`` / ``response_options`` / ``routing`` projection.
# The provider schema does not mark the projection as required, so a model could
# return a complete measurement and no projection, and the attempt then failed
# ``QG_RESPONSE_CODING_DRIFT`` on ``len(codes) < 2`` — which reads as a coding
# defect in the model's answer when the option set was in fact complete.

def _projected_candidate(*, drop=('response_codes', 'response_options', 'routing'),
                         mutate=None):
    """A draft whose top-level projection has been removed or altered."""
    from test_qg_contract_v2 import packet, draft
    from sitewise.project1.qg_contract import facts_from_packet
    source = packet()
    objective = {'objective_id': source['confirmed_uncertainty']['id'],
                 'text': source['confirmed_uncertainty']['exact_text']}
    facts = facts_from_packet(source, objective=objective)
    spec = measurement()
    spec.update(population='Synthetic', options=[
        {'code': 'ACCEPTABLE', 'label': 'Acceptable', 'order': 0},
        {'code': 'NOT_ACCEPTABLE', 'label': 'Not acceptable', 'order': 1},
        {'code': 'DONT_KNOW', 'label': "Don't know", 'order': 2}])
    raw = {**draft(), 'fixed_measurement': spec}
    for key in drop:
        raw.pop(key, None)
    if mutate is not None:
        mutate(raw, spec)
    return raw, facts


def _validate(raw, facts):
    from sitewise.project1.qg_fixed_options import validate_fixed_candidate
    return validate_fixed_candidate(
        raw, facts, supported_formats=frozenset({'SINGLE_CHOICE'}),
        approved_population='Synthetic', period_required=False)


def test_an_absent_response_projection_is_filled_from_the_option_set():
    """The option set is model-supplied and persisted; the projection is derived."""
    raw, facts = _projected_candidate()
    candidate = _validate(raw, facts)
    assert candidate.response_codes == ['ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW']
    assert candidate.response_options == ['Acceptable', 'Not acceptable', "Don't know"]
    # Only END is admissible, so the target is not a claim the model must repeat.
    assert candidate.routing == {'ACCEPTABLE': 'END', 'NOT_ACCEPTABLE': 'END',
                                 'DONT_KNOW': 'END'}


@pytest.mark.parametrize('drop', [
    ('response_codes',),
    ('response_options',),
    ('routing',),
    ('response_codes', 'response_options', 'routing'),
])
def test_each_absent_projection_field_is_filled_independently(drop):
    raw, facts = _projected_candidate(drop=drop)
    candidate = _validate(raw, facts)
    assert len(candidate.response_codes) == len(candidate.response_options) == 3
    assert set(candidate.routing) == set(candidate.response_codes)


def test_an_empty_projection_is_treated_as_absent():
    """``[]`` and ``{}`` are what a strict-mode model emits for "not supplied"."""
    def empty(raw, _spec):
        raw['response_codes'] = []
        raw['response_options'] = []
        raw['routing'] = {}
    raw, facts = _projected_candidate(drop=(), mutate=empty)
    assert _validate(raw, facts).response_codes == [
        'ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW']


def test_a_supplied_projection_is_never_overwritten():
    raw, facts = _projected_candidate(drop=())
    candidate = _validate(raw, facts)
    assert candidate.response_codes == ['ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW']


@pytest.mark.parametrize(('field', 'value', 'code'), [
    # Truncating the codes leaves the two arrays different lengths, and
    # ``validate_candidate`` checks that coherence before the projection is
    # compared entry by entry — so this one refuses earlier, with the coding code.
    ('response_codes', ['ACCEPTABLE', 'NOT_ACCEPTABLE'], 'QG_RESPONSE_CODING_DRIFT'),
    # Same count, different label: only the entry-by-entry comparison can catch it.
    ('response_options', ['Acceptable', 'Not acceptable', 'Unsure'],
     'QG_FIXED_OPTION_MISMATCH'),
])
def test_a_supplied_but_different_projection_is_still_refused(field, value, code):
    """Filling an absence is not the same as accepting a contradiction.

    A model that states the option set twice and disagrees with itself has
    produced an ambiguous measurement, and the persisted row would carry both
    readings. That stays a refusal, whichever check happens to see it first.
    """
    def differ(raw, _spec):
        raw[field] = value
    raw, facts = _projected_candidate(drop=(), mutate=differ)
    with pytest.raises(WorkflowHeld, match=code):
        _validate(raw, facts)


def test_a_projection_cannot_smuggle_an_option_the_measurement_lacks():
    """The projection is derived from the measurement, never the reverse.

    An extra code with no matching routing entry is refused as routing drift,
    which is the first coherent check to see the inconsistency. The point of the
    test is that it is refused at all: nothing here lets the top-level array add
    an option the measurement does not contain.
    """
    def extra(raw, _spec):
        raw['response_codes'] = ['ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW', 'EXTRA']
        raw['response_options'] = ['Acceptable', 'Not acceptable', "Don't know", 'Extra']
    raw, facts = _projected_candidate(drop=(), mutate=extra)
    with pytest.raises(WorkflowHeld, match='QG_ROUTING_DRIFT'):
        _validate(raw, facts)


def test_an_abstention_is_untouched_by_the_projection():
    """No measurement means nothing to project from, so the abstention is intact."""
    raw, facts = _projected_candidate(drop=('response_codes', 'response_options', 'routing'))
    raw.update(decision='ABSTAIN_NEEDS_REVIEW', question='',
               fixed_measurement=None, missing_business_facts=['PRICE'])
    assert _validate(raw, facts).decision == 'ABSTAIN_NEEDS_REVIEW'
