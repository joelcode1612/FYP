"""Verifier safety and evidence acceptance checks; zero network in these tests."""
from types import SimpleNamespace
import pytest
import bootstrap
from cp13_manual_verify import sanitize,parser,live,controlled,PROTECTED,verify_live_evidence

def test_credentials_and_personal_information_are_redacted():
    from cp13_manual_verify import SECRETS
    SECRETS.append('sentinel-secret')
    result=sanitize(dict(authorization='Bearer token',email='test@example.com',
        message='sentinel-secret postgresql+psycopg2://user:pass@localhost/Dss'))
    assert 'sentinel-secret' not in str(result) and ':pass@' not in str(result)
    assert result['email']=='[REDACTED]'
    assert sanitize({'owner_authorization':False,'qg_authorization':{'receipt_present':True}})=={
        'owner_authorization':False,'qg_authorization':{'receipt_present':True}}

@pytest.mark.parametrize('record',sorted(PROTECTED))
def test_live_verification_refuses_all_protected_ids_before_network(record,monkeypatch):
    import httpx
    monkeypatch.setattr(httpx,'Client',lambda *a,**k:pytest.fail('network before safety gates'))
    settings=SimpleNamespace(project1_workflow_enabled=False,project1_rules_version='',
        project1_rules_adoption_receipt='',tokenharbor_enabled=False)
    args=parser().parse_args(['--mode','live','--assessment-id',record])
    result=live(args,settings,{})
    assert result['status']=='BLOCKED' and any('Protected record' in x for x in result['blockers'])

def test_live_acceptance_requires_actual_database_proof():
    args=SimpleNamespace(revision=2,objective_id='synthetic')
    result=dict(database={},input={'source_fingerprint':'source'},modules={
        'bdj':dict(status='PASS',output={'result_id':'made-up'}),
        'direct-qg':dict(status='PASS',output={'version':'made-up','status':'VALIDATED_OUTPUT','candidate':{'question':'text'}})})
    checks=verify_live_evidence(result,args)
    assert checks and all(x['status']=='FAIL' for x in checks)

@pytest.mark.parametrize('module',['bdj','bcb','direct-qg','all'])
def test_each_menu_module_has_a_runnable_controlled_equivalent(module):
    result=controlled('complete',module)
    assert result['status']=='PASS' and result['mode']=='MOCKED'

def test_all_predefined_scenarios_match_explicit_assertions():
    from harness import CASES
    for case in CASES:
        result=controlled(case,'all')
        assert result['status']=='PASS', (case,result['assertions'])
