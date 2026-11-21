"""Controlled provider envelope and durable projection metadata checks. No cloud."""
import json
from copy import deepcopy
import httpx
import pytest
from pydantic import SecretStr
import bootstrap
from sitewise.project1.provider import TokenHarbor,MODEL,ModelRunner
from sitewise.project1.contracts import BDJOutput,WorkflowHeld
from sitewise.project1.prompts import PROMPTS
from sitewise.services.qg_candidate_service import QgCandidateService
from harness import fixture,run_bcb,TestContexts as FixtureContexts
from sitewise.project1.direct_qg_service import DirectQgService
from sitewise.project1.measurement_policy import lab_authority

def provider(*,model=MODEL,usage=None,body=None):
    envelope=dict(model=model,choices=[dict(finish_reason='stop',message={'content':json.dumps({'issues':[],'overall_note':'Controlled only.'})})],
        usage=usage if usage is not None else {'prompt_tokens':12,'completion_tokens':7,'total_tokens':19,'cost':0.25,'cost_currency':'USD','credential':'NO-EXPORT'})
    return TokenHarbor(SecretStr('NO-EXPORT-KEY'),enabled=True,transport=httpx.MockTransport(lambda r:httpx.Response(200,json=envelope) if body is None else httpx.Response(200,content=body)))

def test_real_envelope_metadata_reports_returned_model_usage_and_only_reported_cost():
    p=provider();p.complete([],BDJOutput);r=p.last_execution
    assert r['model_returned']==MODEL and r['identity_verified'] is True
    assert r['usage']=={'prompt_tokens':12,'completion_tokens':7,'total_tokens':19}
    assert r['provider_reported_cost']==0.25 and r['cost_currency']=='USD'
    assert 'NO-EXPORT' not in json.dumps(r) and r['schema_validation']=='VALID'

def test_strict_identity_mismatch_records_failure_not_a_success():
    p=provider(model='different-model')
    with pytest.raises(WorkflowHeld,match='PROVIDER_MODEL_MISMATCH'):p.complete([],BDJOutput)
    assert p.last_execution['model_returned']=='different-model'
    assert p.last_execution['identity_verified'] is False

def test_unavailable_usage_and_second_failed_call_do_not_reuse_previous_metadata():
    p=provider(usage={});p.complete([],BDJOutput)
    assert p.last_execution['usage'] is None and p.last_execution['provider_reported_cost'] is None
    p.enabled=False
    with pytest.raises(WorkflowHeld,match='PROVIDER_NOT_CONFIGURED'):p.complete([],BDJOutput)
    assert p.last_execution['model_returned'] is None and p.last_execution['dispatched'] is False

def test_malformed_response_records_http_without_claiming_validated_output():
    p=provider(body=b'{invalid')
    with pytest.raises(WorkflowHeld):p.complete([],BDJOutput)
    assert p.last_execution['http_status']==200 and p.last_execution['schema_validation']=='NOT_VALIDATED'

def test_non_object_envelope_and_invalid_usage_do_not_leak_or_claim_valid_output():
    p=provider(body=b'[]')
    with pytest.raises(WorkflowHeld,match='PROVIDER_INVALID_STRUCTURED_RESPONSE'):p.complete([],BDJOutput)
    p=provider(usage={'prompt_tokens':True,'total_tokens':-1,'cost':float('inf')})
    # httpx JSON serialization correctly refuses Infinity; exercise only its
    # finite malformed counters in the transport fixture.
    p=provider(usage={'prompt_tokens':True,'total_tokens':-1,'cost':'unknown'})
    p.complete([],BDJOutput)
    assert p.last_execution['usage'] is None and p.last_execution['provider_reported_cost'] is None

def test_model_runner_metadata_requires_a_committed_receipt():
    class Disclosure:
        def require_current(self,*a):pass  # TEST port, never used for live admission.
    class Ledger:
        def reserve(self,*a):return 1
        def finish(self,*a):self.receipt=a
    ledger=Ledger();runner=ModelRunner(provider(),ledger,PROMPTS,disclosure=Disclosure())
    runner('BDJ',{},BDJOutput)
    assert runner.last_execution['receipt_recorded'] is True and ledger.receipt[1]=='returned'
    assert runner.last_execution['prompt_version']==PROMPTS['BDJ'].version

def test_candidate_projection_and_readback_expose_only_existing_saved_metadata():
    execution={'model_requested':MODEL,'model_returned':MODEL,'identity_verified':True,'receipt_recorded':True}
    result={'status':'VALIDATED_OUTPUT','provider_execution':execution}
    body=QgCandidateService._project(result,version='test-version')
    assert body['provider_execution']==execution
    row=dict(id='test-version',objective_id='test-objective',source_receipt=json.dumps({'evaluation':result}),question='test',options=[])
    assert QgCandidateService._candidate(row)['provider_execution']==execution

def test_early_context_refusal_does_not_replay_previous_request_metadata():
    class Runner:
        last_execution={'model_returned':MODEL,'identity_verified':True}
        def __call__(self,*a,**k):raise AssertionError('must not dispatch')
    p=run_bcb(fixture());p['packet_hash']='tampered'
    service=DirectQgService(contexts=FixtureContexts(p),authority=lab_authority(),runner=Runner(),enabled=True)
    result=service.prepare_candidate(assessment_id='test',context_id='test',actor=None,attempt_limit=1)
    assert result['status']=='BLOCKED_INPUT' and 'provider_execution' not in result

def test_active_direct_qg_composition_carries_real_parser_receipt_metadata():
    from harness import draft
    class Disclosure:
        def require_current(self,stage,*a):assert stage=='QG'
    class Ledger:
        def reserve(self,*a):return 1
        def finish(self,*a):self.saved=a
    packet=run_bcb(fixture())
    candidate=draft(packet)
    envelope={'model':MODEL,'choices':[{'finish_reason':'stop','message':{'content':json.dumps(candidate)}}],
              'usage':{'prompt_tokens':100,'completion_tokens':60,'total_tokens':160}}
    provider=TokenHarbor(SecretStr('TEST-NONSECRET'),enabled=True,
        transport=httpx.MockTransport(lambda request:httpx.Response(200,json=envelope)))
    ledger=Ledger();runner=ModelRunner(provider,ledger,PROMPTS,disclosure=Disclosure())
    service=DirectQgService(contexts=FixtureContexts(packet),authority=lab_authority(),runner=runner,enabled=True)
    result=service.prepare_candidate(assessment_id='test',context_id='test',actor=None,attempt_limit=1)
    assert result['status']=='VALIDATED_OUTPUT'
    execution=result['provider_execution']
    assert execution['model_requested']==execution['model_returned']==MODEL
    assert execution['prompt_version']==PROMPTS['QG_PROPOSAL'].version and execution['receipt_recorded'] is True
    projected=QgCandidateService._project(result,version='fixture')
    row={'id':'fixture','objective_id':'objective','source_receipt':json.dumps({'evaluation':result}),
         'question':result['qg']['question'],'options':[],'depth':0}
    assert QgCandidateService._candidate(row)['provider_execution']==projected['provider_execution']
    assert QgCandidateService._history_entry(row)['provider_execution']==execution
    import os
    from pathlib import Path
    destination=os.environ.get('CP13_V2_EVIDENCE_DIR')
    if destination:
        target=Path(destination).resolve()
        assert target.is_relative_to(bootstrap.ROOT/'artifacts')
        target.mkdir(parents=True,exist_ok=True)
        (target/'controlled_qg_observability.json').write_text(json.dumps({
            'mode':'MOCKED','cloud_calls':0,'status':'PASS',
            'receipt_scope':'Controlled in-memory ledger port, not a real provider/DB receipt',
            'input_bcb':packet,'result':result,'candidate_projection':projected,
            'read_projection':QgCandidateService._candidate(row),
            'history_projection':QgCandidateService._history_entry(row)},indent=2)+'\n',encoding='utf-8')
