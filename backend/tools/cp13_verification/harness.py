"""Test ports around actual engines. All provider replies here are MOCKED.

No database, app startup, authorization override or real HTTP transport is used.
The production algorithms, schemas, prompts and validators are imported unchanged.
"""
from contextlib import contextmanager
from copy import deepcopy
from datetime import datetime, timezone
import json
from types import SimpleNamespace
from uuid import UUID, uuid5, NAMESPACE_URL

import bootstrap
import httpx
from pydantic import SecretStr
from sitewise.project1.contracts import digest, BDJOutput
from sitewise.project1.bdj import BDJEngine
from sitewise.domain import bdj_candidate_rules
from sitewise.project1.provider import TokenHarbor, MODEL
from sitewise.project1.direct_qg_service import DirectQgService
from sitewise.project1.measurement_policy import lab_authority
from sitewise.project1.prompts import PROMPTS
from sitewise.services.business_context_v1 import BusinessContextBuilderV1, CURRENT_CONTEXT_VERSION, source_hash
from sitewise.services.ports.business_context_v1_port import ContextReadView, ContextRequest

CASES = json.loads((bootstrap.PACKAGE/'fixtures/cases.json').read_text(encoding='utf-8'))['cases']

def rebind(f):
    snap = f['confirmation']['snapshot_json']
    snap['answer_revisions'] = [dict(item_key=k, answer_revision_id=a['id'],
        item_version_id=a['item_version_id'], answer_state=a['answer_state'],
        value=a['value_json']) for k, a in sorted(f['answers'].items())]
    snap['unresolved_candidate_findings'] = sorted(x['id'] for x in f['findings'])
    f['confirmation']['acknowledged_issue_ids'] = snap['unresolved_candidate_findings'][:]
    snap['finding_decision_event_refs'] = {x['id']: 'TEST-DECISION-'+x['id'] for x in f['findings']}
    f['confirmation']['snapshot_digest'] = source_hash(snap)
    f['bindings']['concept']['m2_snapshot_digest'] = source_hash(snap)
    f['instrument']['schema_digest'] = source_hash(f['items'])
    snap['instrument_digest'] = f['instrument']['schema_digest']
    f['confirmation']['snapshot_digest'] = source_hash(snap)
    f['bindings']['concept']['m2_snapshot_digest'] = source_hash(snap)

def fixture(case='complete'):
    spec = CASES[case]
    f = json.loads((bootstrap.PACKAGE/'fixtures/bcb_base.json').read_text(encoding='utf-8'))
    f['findings'] = []  # BDJ findings are attached below, not invented as accepted facts.
    text = spec.get('description_text', CASES['complete']['description_text'])
    f['answers']['M2-04']['value_json'] = text
    f['answers']['M2-05']['value_json'] = spec.get('service_format', 'TAKEAWAY_FOCUSED')
    f['items'][2]['option_values'] = ['TAKEAWAY_FOCUSED', 'DINE_IN_FOCUSED']
    if spec.get('missing_mandatory'):
        del f['answers']['M2-01']
    objective = spec.get('objective', CASES['complete']['objective'])
    f['bindings']['uncertainty'] = dict(id=str(uuid5(NAMESPACE_URL, 'CP13/'+case+'/objective')),
        confirmation_id=f['confirmation']['id'], actor_user_id=f['assessment']['owner_user_id'], exact_text=objective)
    f['bindings']['sources'] = []
    f['bindings']['geography'] = None  # Existing CURRENT_CONTEXT_VERSION excludes GEO.
    rebind(f)
    return f

def projection(f):
    # Detached synthetic projection fixture; not proof of real DB source extraction.
    p = dict(schema_version='project1-m2-projection/1-candidate',
        assessment_id=f['assessment']['id'], assessment_revision=f['assessment']['revision'],
        instrument_id=f['instrument']['id'], instrument_version=f['instrument']['version_tag'],
        instrument_digest=f['instrument']['schema_digest'], declarations=[], confirmed=False,
        facts_independently_verified=False, governance_items=['M2-20', 'M2-21'],
        excluded_items={'M2-11':'DEFERRED', 'M2-15':'PRIVACY_PENDING'},
        data_class='SYNTHETIC_NONHUMAN', purpose='SYNTHETIC_BDJ_DIAGNOSTIC')
    items = {x['item_key']:x for x in f['items']}
    for key, a in sorted(f['answers'].items()):
        i=items[key]
        p['declarations'].append(dict(item_key=key, question=i['question_text'],
            item_version_id=a['item_version_id'], definition_digest=digest(i),
            answer_revision_id=a['id'], answer_revision=a['assessment_revision'],
            answer_state=a['answer_state'], value=a['value_json'], trust_class='ENTREPRENEUR_DECLARED'))
    return {**p, 'source_fingerprint':digest(p)}

def draft(packet):
    objective=packet['confirmed_uncertainty']['exact_text']
    if 'RM13' in objective:
        question='Would you find a 12 oz takeaway iced latte at RM13 acceptable?'
        citations=['RM13', '12']
    else:
        question='Which service format would you prefer for this cafe?'
        citations=[packet['confirmed_uncertainty']['id']]
    return dict(decision='DRAFT', question=question, justification='Synthetic candidate for review only.',
        construct_interpretation='Stated preference for the declared offer.',
        response_options=['Acceptable','Not acceptable',"Don't know"],
        response_codes=['ACCEPTABLE','NOT_ACCEPTABLE','DONT_KNOW'],
        routing={x:'END' for x in ('ACCEPTABLE','NOT_ACCEPTABLE','DONT_KNOW')},
        reference_period='At the moment the offer is shown.', measurement_description='Stated response only.',
        denominator_specification='ACCEPTABLE and NOT_ACCEPTABLE; DONT_KNOW separate.',
        limitations='Stated preference only; no purchase or sales prediction.',
        used_confirmed_facts=citations)

class ControlledRunner:
    supports_prompt_key=True
    def __init__(self, response, fault=None):
        self.response, self.fault, self.calls = response, fault, []
    def __call__(self, stage, packet, output_type, *, prompt_key=None):
        assert stage in {'BDJ','QG'}, 'Retired stage dispatch prohibited'
        prompt=PROMPTS[prompt_key or stage]
        messages=prompt.messages(packet, output_type.model_json_schema())
        entry=dict(stage=stage, input=deepcopy(packet), messages=messages,
            prompt_version=prompt.version,prompt_hash=prompt.fingerprint,mode='MOCKED',
            status_code=None,token_usage=None,estimated_cost=None)
        self.calls.append(entry)
        def respond(request):
            entry['request']=json.loads(request.content)
            if self.fault=='timeout': raise httpx.ReadTimeout('injected timeout',request=request)
            if self.fault=='malformed': return httpx.Response(200,content=b'{not-json')
            value={} if self.fault=='schema' else self.response
            if self.fault=='unsupported-question':
                value={**value, 'question':'Would you find a 12 oz takeaway iced latte at RM999 acceptable?'}
            return httpx.Response(200,json=dict(model=MODEL,choices=[dict(finish_reason='stop',
                message=dict(content=json.dumps(value)))],usage=dict(prompt_tokens=0,completion_tokens=0)))
        provider=TokenHarbor(SecretStr('TEST-NONSECRET'), enabled=True, transport=httpx.MockTransport(respond))
        provider.telemetry={}
        try:
            output=provider.complete(messages,output_type)
            entry['output']=output
            return output
        finally:
            entry['telemetry']=provider.telemetry
            entry['status_code']=provider.telemetry.get('status_code')
            entry['identity']=provider.last_identity

def run_bdj(f, spec):
    p=projection(f)
    r=ControlledRunner(dict(issues=[],overall_note='Only bounded source checks; no viability claim.'),spec.get('fault') if spec.get('fault')!='unsupported-question' else None)
    try:
        result=BDJEngine(bdj_candidate_rules, r).review(p,recheck_current=lambda:p['source_fingerprint'])
        return result, r.calls
    except Exception as exc:
        exc.cp13_calls=r.calls
        raise

def attach_findings(f, result):
    for n,x in enumerate(result.get('findings',[])):
        f['findings'].append(dict(id=str(uuid5(NAMESPACE_URL,'CP13/finding/'+str(n))),
            assessment_id=f['assessment']['id'],assessment_revision=f['assessment']['revision'],
            rule_id=x['rule_id'],rule_version=bdj_candidate_rules.RULE_VERSION,
            source_answer_ids=[r['answer_revision_id'] for r in x['source_refs']],
            issue_type='POTENTIAL_DECLARATION_CONFLICT',explanation=x['observed_condition'],
            not_proven=x['counterargument'],next_action=x['next_action'],review_state='CANDIDATE'))
        f['bindings']['rule_versions'][x['rule_id']]=bdj_candidate_rules.RULE_VERSION
    rebind(f)  # Explicit TEST confirmation fixture; never a human approval event.

class TestClock:
    def now(self): return datetime(2026,11,8,tzinfo=timezone.utc)
class TestAuthorization:
    def __init__(self,f): self.f=f
    def authorize(self,request): return deepcopy(self.f['decision'])
class ReadPort:
    def __init__(self,f): self.f=f
    def get_assessment(self,*a): return deepcopy(self.f['assessment'])
    def get_confirmation(self,*a): return deepcopy(self.f['confirmation'])
    def get_instrument(self,*a): return deepcopy(self.f['instrument'])
    def list_items(self,*a): return deepcopy(self.f['items'])
    def get_latest_answers(self,*a): return deepcopy(self.f['answers'])
    def get_findings(self,*a): return deepcopy(self.f['findings'])
class TestSnapshots:
    def __init__(self,f): self.f=f
    @contextmanager
    def open_read(self,*a):
        f=deepcopy(self.f)
        yield ContextReadView(ReadPort(f),f['bindings'])

def run_bcb(f):
    data=deepcopy(f['request'])
    for key in ('viewer_id','assessment_id','confirmation_id'): data[key]=UUID(data[key])
    service=BusinessContextBuilderV1(TestAuthorization(f),TestSnapshots(f),TestClock(),contract=CURRENT_CONTEXT_VERSION)
    result=service.get_context(ContextRequest(**data))
    assert result==service.get_context(ContextRequest(**data)), 'BCB nondeterminism'
    assert source_hash({k:v for k,v in result.items() if k!='packet_hash'})==result['packet_hash']
    return result

class TestContexts:
    def __init__(self,packet): self.packet=packet
    def retrieve(self,*a): return dict(packet=deepcopy(self.packet),qg_execution_authorized=False)

def run_qg(packet,spec):
    runner=ControlledRunner(draft(packet),spec.get('fault'))
    svc=DirectQgService(contexts=TestContexts(packet),authority=lab_authority(),runner=runner,
                        enabled=spec.get('qg_enabled',True))
    try:
        result=svc.prepare_candidate(assessment_id=UUID(packet['identity']['assessment_id']),
            context_id=UUID(int=900),actor=SimpleNamespace(user_id=UUID(int=1)),
            objective=dict(objective_id=packet['confirmed_uncertainty']['id'],
                text=packet['confirmed_uncertainty']['exact_text']),attempt_limit=1)
        return result,runner.calls
    except Exception as exc:
        exc.cp13_calls=runner.calls
        raise
