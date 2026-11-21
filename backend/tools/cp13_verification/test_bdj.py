"""Real BDJ validator/engine; controlled provider failures are explicitly MOCKED."""
import copy
import pytest
import bootstrap
from harness import fixture,projection,run_bdj,CASES,ControlledRunner
from sitewise.project1.bdj import BDJEngine,validate_candidates,load_rules
from sitewise.project1.contracts import WorkflowHeld,BDJOutput
from sitewise.domain import bdj_candidate_rules

def test_explicit_conflict_is_not_suppressed_by_empty_model_answer():
    result,calls=run_bdj(fixture('conflicting'),CASES['conflicting'])
    assert result['outcome']=='reviewed'
    assert any(x['kind']=='SOURCE_CONFLICT' for x in result['findings'])
    assert calls[0]['stage']=='BDJ'
    assert result['fielding_authorized'] is False

def test_typographical_text_is_preserved_and_no_new_facts_written():
    f=fixture('typos');original=copy.deepcopy(f)
    result,_=run_bdj(f,CASES['typos'])
    assert f==original
    assert projection(f)['declarations'][1]['value']==CASES['typos']['description_text']
    assert result['finding_authority']=='CANDIDATE_ONLY'

def test_unknown_rules_fail_closed_before_model_dispatch():
    p=projection(fixture());r=ControlledRunner({})
    assert BDJEngine(None,r).review(p,recheck_current=lambda:p['source_fingerprint'])['outcome']=='held'
    assert r.calls==[]
    with pytest.raises(WorkflowHeld,match='BDJ_RULE_ADOPTION_REQUIRED'):load_rules('','','')

def test_invented_rule_and_quote_are_rejected():
    p=projection(fixture())
    issue=dict(rule_id='MADE_UP',kind='UNSUPPORTED_ASSERTION',source_refs=[dict(item_key='M2-04',
        answer_revision_id=p['declarations'][1]['answer_revision_id'],item_version_id=p['declarations'][1]['item_version_id'],
        quote='invented business fact')],observed_condition='test',counterargument='test',justification='test',next_action='test')
    with pytest.raises(WorkflowHeld,match='BDJ_RULE_NOT_REGISTERED'):
        validate_candidates(dict(issues=[issue],overall_note='test'),p,set())
    with pytest.raises(WorkflowHeld,match='BDJ_SOURCE_QUOTE_INVALID'):
        validate_candidates(dict(issues=[issue],overall_note='test'),p,{'MADE_UP'})

@pytest.mark.parametrize('fault,code', [('timeout','E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN'),
    ('malformed','PROVIDER_INVALID_STRUCTURED_RESPONSE'),('schema','PROVIDER_INVALID_STRUCTURED_RESPONSE')])
def test_actual_provider_parser_rejects_injected_failures_without_retry(fault,code):
    r=ControlledRunner({},fault)
    with pytest.raises(WorkflowHeld,match=code):r('BDJ',projection(fixture()),BDJOutput)
    assert len(r.calls)==1

def test_stale_source_is_not_presented_as_current():
    p=projection(fixture())
    result=BDJEngine(bdj_candidate_rules).review(p,recheck_current=lambda:'changed')
    assert result['outcome']=='stale'
