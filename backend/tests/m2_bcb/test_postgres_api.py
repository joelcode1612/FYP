"""Actual FastAPI + signed JWT verifier + Dss-derived private PostgreSQL.

Instrument, tenant, concept and purpose grants below are TEST FIXTURES. GEO is no
longer supplied at all: BCB-V1-1.1.0 excludes GEO from V1 scope. No production
authority, endpoint or database is used by this module.
"""
from copy import deepcopy
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import threading
import time
from uuid import UUID, uuid4

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
import uvicorn

if not os.environ.get('M2_BCB_PRIVATE_CLUSTER'):
    pytest.skip('Run tests/m2_bcb/run_isolated.py; existing DBs are prohibited.', allow_module_level=True)

from sitewise.services.business_context_v1 import canonical_bytes, json_value, source_hash
from sitewise.services.ports.business_context_store_port import (
    ContextBindingUnavailable, GovernedContextInputs,
)
from sitewise.services.ports.business_context_v1_port import ContextRequest


class FixtureBindingResolver:
    def __init__(self, session): self.session = session
    def resolve(self, selection, actor):
        row = self.session.execute(text('SELECT request_json,decision_json,bindings_json FROM test_bcb_bindings '
            'WHERE confirmation_id=:id AND owner_id=:owner'),
            {'id':selection.confirmation_id,'owner':actor.user_id}).mappings().first()
        if row is None: raise ContextBindingUnavailable()
        request = dict(row['request_json'])
        for key in ('viewer_id','assessment_id','confirmation_id'): request[key] = UUID(request[key])
        return GovernedContextInputs(ContextRequest(**request),row['decision_json'],row['bindings_json'])


@pytest.fixture(scope='module')
def lab():
    url = make_url(os.environ['DATABASE_URL'])
    assert (url.host,url.port,url.database) == ('127.0.0.1',int(os.environ.get('M2_BCB_PRIVATE_PORT', '55441')),'project1_m2_bcb_test')
    db = create_engine(url,hide_parameters=True,connect_args={'options':'-c timezone=UTC'})
    with db.connect() as connection:
        assert Path(connection.execute(text('SHOW data_directory')).scalar_one()).resolve() == (
            Path(os.environ['M2_BCB_PRIVATE_CLUSTER'])/'data').resolve()
    key = ec.generate_private_key(ec.SECP256R1())
    jwk = jwt.algorithms.ECAlgorithm.to_jwk(key.public_key(),as_dict=True)
    jwk.update(kid='private-m2-bcb',use='sig',alg='ES256')
    class Keys(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
            self.wfile.write(json.dumps({'keys':[jwk]}).encode())
        def log_message(self,*args): pass
    keys = ThreadingHTTPServer(('127.0.0.1',0),Keys)
    key_thread=threading.Thread(target=keys.serve_forever,daemon=True);key_thread.start()
    os.environ.update(SUPABASE_URL='http://m2-bcb.test',SUPABASE_JWKS_URL=f'http://127.0.0.1:{keys.server_port}/keys')
    from sitewise.main import app
    if os.environ.get('CAPTURE_FLOW_HTTP')=='1':
        from http_exchange_capture import HttpExchangeCapture
        app.add_middleware(HttpExchangeCapture,output=Path(os.environ['M2_BCB_EVIDENCE'])/'http_exchanges.ndjson')
    from sitewise import dependencies as deps
    from sitewise.db.models.user import User
    from sitewise.db.models.m2_schema import instruments, items
    actor,other,staff,suspended = [uuid4() for _ in range(4)]
    iid = uuid4()
    definitions = [
        ('M2-01','REQUIRED','SINGLE',['SYNTHETIC_A','SYNTHETIC_B'],['ANSWERED','NOT_PROVIDED']),
        ('M2-04','RECOMMENDED','TEXT',[],['ANSWERED','NOT_PROVIDED']),
        ('M2-05','REQUIRED','SINGLE',['TAKEAWAY_FOCUSED','DINE_IN_FOCUSED'],['ANSWERED','NOT_DECIDED']),
        ('M2-06','OPTIONAL','MULTI',['TEST_A','TEST_B','NONE'],['ANSWERED','SKIPPED_OPTIONAL']),
        ('M2-20','OPTIONAL','ACTION',[],[]),('M2-21','OPTIONAL','ACTION',[],[]),
    ]
    with db.begin() as connection:
        for uid,role,status in [(actor,'entrepreneur','active'),(other,'entrepreneur','active'),
                                (staff,'agent','active'),(suspended,'entrepreneur','suspended')]:
            connection.execute(User.__table__.insert().values(user_id=uid,email=f'{uid}@test.invalid',
                role=role,account_status=status,email_verified=True))
        connection.execute(instruments.insert().values(id=iid,code='SYNTHETIC-M2-BCB',version_tag='SYNTHETIC-PRIVATE-ONLY',
            approval_state='AUTHORIZED',schema_digest=source_hash(definitions)))
        for order,(key_name,required,kind,options,states) in enumerate(definitions):
            connection.execute(items.insert().values(id=uuid4(),instrument_id=iid,item_key=key_name,
                question_text='SYNTHETIC TEST ITEM '+key_name,requiredness=required,answer_kind=kind,
                option_values=options,allowed_states=states,lifecycle='ACTIVE',sort_order=order))
        connection.execute(text('CREATE TABLE test_bcb_bindings(confirmation_id uuid PRIMARY KEY,owner_id uuid NOT NULL,'
            'request_json jsonb NOT NULL,decision_json jsonb NOT NULL,bindings_json jsonb NOT NULL)'))
        # TEST-ONLY table read by the fixture resolver on the restricted BCB
        # session. This grants nothing on any product table.
        connection.execute(text('GRANT SELECT ON test_bcb_bindings TO p1_m2_runtime'))
    app.dependency_overrides[deps.get_bcb_bindings_resolver_factory] = lambda: FixtureBindingResolver
    bound=socket.socket();bound.bind(('127.0.0.1',0));bound.listen(128)
    port=bound.getsockname()[1]
    server=uvicorn.Server(uvicorn.Config(app,lifespan='off',log_level='error',access_log=False))
    thread=threading.Thread(target=server.run,kwargs={'sockets':[bound]},daemon=True);thread.start()
    deadline=time.monotonic()+15
    while not server.started and thread.is_alive() and time.monotonic()<deadline: time.sleep(.02)
    assert server.started
    client=httpx.Client(base_url=f'http://127.0.0.1:{port}/api/v1/m2',timeout=15)
    traces=[]
    state={'db':db,'actor':actor,'other':other,'staff':staff,'suspended':suspended,
        'iid':iid,'app':app,'traces':traces,'case':'setup'}
    def token(uid):
        assert uid in {actor,other,staff,suspended}
        now=int(time.time())
        return jwt.encode({'sub':str(uid),'email':f'{uid}@test.invalid','email_verified':True,
            'iss':'http://m2-bcb.test/auth/v1','aud':'authenticated','iat':now,'exp':now+1800},
            key,algorithm='ES256',headers={'kid':'private-m2-bcb'})
    state.update(token=token,base=f'http://127.0.0.1:{port}')
    def request(method,path,expected=200,uid=actor,aal=None,**kwargs):
        now=int(time.time())
        headers={}
        if uid is not None:
            claims={'sub':str(uid),'email':f'{uid}@test.invalid','email_verified':True,
                'iss':'http://m2-bcb.test/auth/v1','aud':'authenticated','iat':now,'exp':now+600}
            if aal is not None: claims['aal']=aal
            token=jwt.encode(claims,
                key,algorithm='ES256',headers={'kid':'private-m2-bcb'})
            headers={'Authorization':'Bearer '+token}
        response=client.request(method,path,headers=headers,**kwargs)
        accepted = expected if isinstance(expected,tuple) else (expected,)
        traces.append({'test_id':state['case'],'method':method,'path':'/api/v1/m2'+path,
            'auth':'none' if uid is None else 'signed-test-principal:'+str(uid),
            'assurance':aal,
            'expected_http':expected,'actual_http':response.status_code,'input':kwargs,
            'output':response.json(),'result':'PASS' if response.status_code in accepted else 'FAIL'})
        assert response.status_code in accepted,response.text
        return response
    state['request']=request
    try: yield state
    finally:
        output=Path(os.environ['M2_BCB_EVIDENCE'])
        (output/'api_execution.json').write_text(json.dumps(traces,indent=2,ensure_ascii=False,default=str),encoding='utf-8')
        with db.connect() as connection:
            rows=connection.execute(text('SELECT context_id,assessment_id,owner_user_id,confirmation_id,'
                'assessment_revision,schema_version,builder_version,packet_hash,lifecycle_status,created_at '
                'FROM m2_business_contexts ORDER BY created_at')).mappings().all()
            states=connection.execute(text('SELECT * FROM m2_business_context_builds ORDER BY created_at')).mappings().all()
            physical={}
            for name,query in {
                'columns':"SELECT table_schema,table_name,column_name,udt_name,is_nullable FROM information_schema.columns WHERE table_schema='public' ORDER BY table_name,ordinal_position",
                'constraints':"SELECT c.relname AS table_name,p.conname,p.contype,pg_get_constraintdef(p.oid) AS definition FROM pg_constraint p JOIN pg_class c ON c.oid=p.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' ORDER BY 1,2",
                'indexes':"SELECT tablename,indexname,indexdef FROM pg_indexes WHERE schemaname='public' ORDER BY 1,2",
                'rls':"SELECT c.relname AS table_name,c.relrowsecurity,c.relforcerowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' ORDER BY 1",
            }.items():
                physical[name]=[dict(row) for row in connection.execute(text(query)).mappings()]
        (output/'private_physical_schema.json').write_text(json.dumps(physical,indent=2,default=str),encoding='utf-8')
        (output/'independent_context_readback.json').write_text(json.dumps({'contexts':[dict(x) for x in rows],
            'build_statuses':[dict(x) for x in states],'data':'SYNTHETIC PRIVATE CLUSTER ONLY'},indent=2,default=str),encoding='utf-8')
        (output/'registered_m2_routes.json').write_text(json.dumps([
            {'path':p,'methods':list(v)} for p,v in app.openapi()['paths'].items()
            if p.startswith('/api/v1/m2')],indent=2),encoding='utf-8')
        client.close();server.should_exit=True;thread.join(timeout=15);bound.close()
        app.dependency_overrides.clear();keys.shutdown();keys.server_close();key_thread.join(timeout=5);db.dispose()


@pytest.fixture(autouse=True)
def case_name(request,lab): lab['case']=request.node.name


def create(lab):
    return lab['request']('POST','/assessments',201,json={'instrument_version_id':str(lab['iid'])}).json()['id']


def answer(lab,mid,key,value,revision,state='ANSWERED',expected=200):
    return lab['request']('PUT',f'/assessments/{mid}/answers/{key}',expected,
        json={'expected_revision':revision,'answer_state':state,'value':value})


def confirmed(lab, description='A fictional cafÃ© serving drinks.', uncertainty=True, service_unknown=False):
    mid=create(lab)
    answer(lab,mid,'M2-01','SYNTHETIC_A',0)
    answer(lab,mid,'M2-04',description,1)
    answer(lab,mid,'M2-05',None if service_unknown else 'TAKEAWAY_FOCUSED',2,
           'NOT_DECIDED' if service_unknown else 'ANSWERED')
    # Current declaration confirmation never runs BDJ or invents finding
    # acknowledgements. Historical pin validation is verified separately.
    lab['request']('POST',f'/assessments/{mid}/review',json={'expected_revision':3})
    result=lab['request']('POST',f'/assessments/{mid}/confirm',json={
        'expected_revision':3,'acknowledged_issue_ids':[]}).json()
    cid=result['id']
    uid=None
    if uncertainty:
        uid=lab['request']('POST',f'/confirmations/{cid}/uncertainty',json={
            'exact_text':'SYNTHETIC confirmed uncertainty; no customer research execution.'}).json()['id']
    return mid,cid,uid


def bind(lab,mid,cid,uid=None,*,test_concept=None):
    """Persist explicit TEST authority receipts, deriving facts from actual rows."""
    template=json.loads((Path(__file__).parents[1]/'project1/bcb/fixtures/valid_confirmed.json').read_text())
    with lab['db'].begin() as connection:
        confirmation=dict(connection.execute(text('SELECT * FROM m2_confirmation_snapshots WHERE id=:id'),{'id':cid}).mappings().one())
        revision=confirmation['assessment_revision']
        declaration=test_concept if test_concept is not None else connection.execute(text("SELECT value_json FROM m2_answer_revisions a JOIN m2_item_versions i ON i.id=a.item_version_id WHERE a.assessment_id=:id AND i.item_key='M2-04' ORDER BY a.assessment_revision DESC LIMIT 1"),{'id':mid}).scalar_one()
        findings=connection.execute(text('SELECT rule_id,rule_version FROM m2_bdj_findings WHERE assessment_id=:id AND assessment_revision=:rev'),{'id':mid,'rev':revision}).mappings().all()
        tenant='SYNTHETIC-TENANT-FIXTURE'
        request={'viewer_id':str(lab['actor']),'tenant_id':tenant,'role':'entrepreneur','assessment_id':mid,
            'purpose':'EXPLANATION','confirmation_id':cid,'confirmed_revision':revision,'concept_version':f'SYNTHETIC-CONCEPT-{revision}'}
        decision={'allowed':True,'scope':deepcopy(request),'owner_id':str(lab['actor']),
            'decision_id':'SYNTHETIC-ACCESS-'+cid,'policy_version':'SYNTHETIC-TEST-POLICY','valid_until':'2099-01-01T00:00:00+00:00'}
        bindings=deepcopy(template['bindings'])
        bindings.update(scope={'tenant_id':tenant,'assessment_id':mid},consistency='IMMUTABLE_SNAPSHOT',
            snapshot_id='SYNTHETIC-SNAPSHOT-'+cid,current_concept_version=request['concept_version'],
            rule_versions={f['rule_id']:f['rule_version'] for f in findings},finding_authorities={},sources=[],uncertainty=None)
        content={'description':declaration}
        bindings['concept'].update(tenant_id=tenant,assessment_id=mid,version=request['concept_version'],
            confirmation_id=cid,assessment_revision=revision,status='ENTREPRENEUR_CONFIRMED',confirmed_by=str(lab['actor']),
            confirmation_event_id=cid,content=content,source_hash=source_hash(content),
            m2_snapshot_digest=confirmation['snapshot_digest'],valid_until='2099-01-01T00:00:00+00:00')
        # BCB-V1-1.1.0 excludes GEO from V1 scope, so the fixture binding source
        # supplies no GEO catalogue/approval authority at all.
        bindings['geography']=None
        if uid:
            row=connection.execute(text('SELECT * FROM m2_confirmed_uncertainties WHERE id=:id'),{'id':uid}).mappings().one()
            bindings['uncertainty']={k:str(row[k]) if isinstance(row[k],UUID) else row[k] for k in ('id','confirmation_id','actor_user_id','exact_text')}
        connection.execute(text('INSERT INTO test_bcb_bindings VALUES(:cid,:owner,CAST(:request AS jsonb),CAST(:decision AS jsonb),CAST(:bindings AS jsonb))'),
            {'cid':cid,'owner':lab['actor'],'request':json.dumps(request),'decision':json.dumps(decision),'bindings':json.dumps(bindings)})
    return bindings


def build(lab,mid,cid,expected=201,uid=None,revision=3):
    kwargs={'json':{'confirmation_id':cid,'expected_revision':revision}}
    if uid is not None: kwargs['uid']=uid
    return lab['request']('POST',f'/assessments/{mid}/business-context',expected,**kwargs)


def test_PG01_submission_revision_and_independent_readback(lab):
    lab['request']('GET',f"/instruments/{lab['iid']}")
    lab['request']('GET',f'/instruments/{uuid4()}',404)
    mid=create(lab)
    lab['request']('GET',f'/assessments/{mid}')
    lab['request']('GET',f'/assessments/{uuid4()}',404)
    lab['request']('GET',f'/assessments/{mid}',401,uid=None)
    answer(lab,mid,'M2-01','SYNTHETIC_A',0)
    answer(lab,mid,'M2-01','SYNTHETIC_B',1)
    answer(lab,mid,'M2-01','SYNTHETIC_A',1,expected=409)
    lab['request']('GET',f'/assessments/{mid}',404,uid=lab['other'])
    with lab['db'].connect() as independent:
        rows=independent.execute(text('SELECT a.*,m.owner_user_id FROM m2_answer_revisions a JOIN m2_assessments m ON m.id=a.assessment_id WHERE a.assessment_id=:id ORDER BY assessment_revision'),{'id':mid}).mappings().all()
        assert len(rows)==2 and [r['value_json'] for r in rows]==['SYNTHETIC_A','SYNTHETIC_B']
        assert all(str(r['owner_user_id'])==str(lab['actor']) and r['created_at'] is not None for r in rows)


@pytest.mark.parametrize('key,value,state',[('M2-01','NOT_A_CODE','ANSWERED'),('M2-04','  ','ANSWERED'),
    ('M2-04','x'*4001,'ANSWERED'),('M2-06',['NONE','TEST_A'],'ANSWERED'),('M2-06',['TEST_A','TEST_A'],'ANSWERED'),
    ('M2-05','TAKEAWAY_FOCUSED','NOT_DECIDED'),('M2-20','YES','ANSWERED'),('M2-99','X','ANSWERED')])
def test_PG02_invalid_answers_never_bump_revision(lab,key,value,state):
    mid=create(lab)
    answer(lab,mid,key,value,0,state,404 if key=='M2-99' else 422)
    with lab['db'].connect() as independent:
        assert independent.execute(text('SELECT revision FROM m2_assessments WHERE id=:id'),{'id':mid}).scalar_one()==0
        assert independent.execute(text('SELECT count(*) FROM m2_answer_revisions WHERE assessment_id=:id'),{'id':mid}).scalar_one()==0


def test_PG03_mandatory_and_explicit_unknown(lab):
    mid=create(lab)
    lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',409,json={'expected_revision':0})
    lab['request']('POST',f'/assessments/{mid}/review',409,json={'expected_revision':0})
    lab['request']('POST',f'/assessments/{mid}/confirm',409,json={'expected_revision':0,'acknowledged_issue_ids':[]})
    answer(lab,mid,'M2-01','SYNTHETIC_A',0)
    answer(lab,mid,'M2-05',None,1,'NOT_DECIDED')
    lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',json={'expected_revision':2})
    lab['request']('POST',f'/assessments/{mid}/review',json={'expected_revision':2})
    lab['request']('POST',f'/assessments/{mid}/confirm',json={'expected_revision':2,'acknowledged_issue_ids':[]})


def test_submit_completion_revision_and_explicit_evaluation_receipts(lab):
    mid=create(lab)
    path=f'/assessments/{mid}'
    def rows(table):
        assert table in {'m2_bdj_evaluations','m2_bdj_findings'}
        with lab['db'].connect() as c:
            return c.execute(text(f'SELECT count(*) FROM {table} WHERE assessment_id=:id'),{'id':mid}).scalar_one()
    lab['request']('POST',path+'/bdj/evaluate',422)
    lab['request']('POST',path+'/bdj/evaluate',422,json={'expected_revision':'0'})
    denied=lab['request']('POST',path+'/bdj/evaluate',409,json={'expected_revision':0}).json()
    assert 'M2-01' in denied['detail'] and 'M2-05' in denied['detail']
    answer(lab,mid,'M2-04','We guarantee profit.',0)
    assert rows('m2_bdj_evaluations')==rows('m2_bdj_findings')==0
    answer(lab,mid,'M2-01','SYNTHETIC_A',1)
    denied=lab['request']('POST',path+'/bdj/evaluate',409,json={'expected_revision':2}).json()
    assert 'M2-05' in denied['detail'] and 'M2-01' not in denied['detail']
    answer(lab,mid,'M2-05',None,2,'NOT_DECIDED')
    lab['request']('POST',path+'/bdj/evaluate',404,uid=lab['other'],json={'expected_revision':3})
    lab['request']('POST',path+'/bdj/evaluate',409,json={'expected_revision':2})
    assert rows('m2_bdj_evaluations')==rows('m2_bdj_findings')==0
    result=lab['request']('POST',path+'/bdj/evaluate',json={'expected_revision':3}).json()
    assert result['revision']==3 and result['evaluation_state']=='EVALUATED_CANDIDATE'
    assert result['findings'] and rows('m2_bdj_evaluations')==1
    lab['request']('POST',path+'/bdj/evaluate',json={'expected_revision':3})
    assert rows('m2_bdj_evaluations')==1  # replay does not duplicate receipts
    answer(lab,mid,'M2-04','An updated entrepreneur declaration.',3)
    worksheet=lab['request']('GET',path+'/business-understanding').json()
    assert worksheet['revision']==4 and worksheet['evaluation_state']=='NOT_EVALUATED'
    lab['request']('POST',path+'/review',409,json={'expected_revision':4})
    lab['request']('POST',path+'/confirm',409,json={'expected_revision':4,'acknowledged_issue_ids':[]})
    lab['request']('POST',path+'/bdj/evaluate',409,json={'expected_revision':3})
    assert rows('m2_bdj_evaluations')==1
    lab['request']('POST',path+'/bdj/evaluate',json={'expected_revision':4})
    lab['request']('POST',path+'/review',json={'expected_revision':4})
    lab['request']('POST',path+'/confirm',json={'expected_revision':4,'acknowledged_issue_ids':[]})
    with lab['db'].connect() as c:
        assert list(c.execute(text('SELECT assessment_revision FROM m2_bdj_evaluations WHERE assessment_id=:id ORDER BY assessment_revision'),{'id':mid}).scalars())==[3,4]


def test_submit_revalidates_persisted_values_and_rolls_back_findings(lab,monkeypatch):
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    invalid_mid=create(lab)
    answer(lab,invalid_mid,'M2-01','SYNTHETIC_A',0)
    answer(lab,invalid_mid,'M2-05','TAKEAWAY_FOCUSED',1)
    # Append a malformed source fixture directly, retaining immutable history.
    # This deliberately bypasses answer validation only inside the private lab.
    with lab['db'].begin() as c:
        c.execute(text("INSERT INTO m2_answer_revisions(id,assessment_id,item_version_id,assessment_revision,answer_state,value_json) "
            "SELECT gen_random_uuid(),assessment_id,item_version_id,3,'ANSWERED','\"UNREGISTERED\"'::jsonb "
            "FROM m2_answer_revisions WHERE assessment_id=:id AND assessment_revision=1"),{'id':invalid_mid})
        c.execute(text('UPDATE m2_assessments SET revision=3 WHERE id=:id'),{'id':invalid_mid})
    lab['request']('POST',f'/assessments/{invalid_mid}/bdj/evaluate',422,json={'expected_revision':3})
    with lab['db'].connect() as c:
        assert c.execute(text('SELECT count(*) FROM m2_bdj_evaluations WHERE assessment_id=:id'),{'id':invalid_mid}).scalar_one()==0
    mid=create(lab)
    answer(lab,mid,'M2-01','SYNTHETIC_A',0)
    answer(lab,mid,'M2-05','TAKEAWAY_FOCUSED',1)
    answer(lab,mid,'M2-04','We guarantee profit.',2)
    path=f'/assessments/{mid}/bdj/evaluate'
    original=SqlModelM2Repository.add_evaluation
    def fail(self,*args,**kwargs):
        original(self,*args,**kwargs)
        self.session.execute(text('SELECT 1/0'))
    monkeypatch.setattr(SqlModelM2Repository,'add_evaluation',fail)
    lab['request']('POST',path,503,json={'expected_revision':3})
    with lab['db'].connect() as c:
        assert c.execute(text('SELECT count(*) FROM m2_bdj_evaluations WHERE assessment_id=:id'),{'id':mid}).scalar_one()==0
        assert c.execute(text('SELECT count(*) FROM m2_bdj_findings WHERE assessment_id=:id'),{'id':mid}).scalar_one()==0
    monkeypatch.setattr(SqlModelM2Repository,'add_evaluation',original)
    lab['request']('POST',path,json={'expected_revision':3})


def test_PG04_findings_decisions_confirmation_and_pending_status(lab):
    mid,cid,uid=confirmed(lab,'We guarantee profit.')
    source=lab['request']('GET',f'/assessments/{mid}/confirmations/{cid}?expected_revision=3').json()
    assert source_hash(source['snapshot'])==source['snapshot_digest']
    assert source['snapshot']['snapshot_contract_version']=='m2-confirmation/2'
    assert source['snapshot']['bdj_evaluation_id'] and source['snapshot']['review_event_id']
    assert source['snapshot']['finding_hashes'] and source['snapshot']['item_definition_hashes']
    review=lab['request']('GET',f'/assessments/{mid}/confirmed-review?confirmation_id={cid}&expected_revision=3').json()
    assert review['findings'] and review['qj_handoff_authorized'] is False
    lab['request']('POST',f'/assessments/{mid}/findings/{uuid4()}/decisions',409,json={
        'expected_revision':3,'request_id':str(uuid4()),'decision':'KEEP_ORIGINAL'})
    status=lab['request']('GET',f'/assessments/{mid}/confirmations/{cid}/business-context-status').json()
    assert status['status']=='PENDING' and status['attempt_count']==0 and status['context_id'] is None
    with lab['db'].connect() as independent:
        assert independent.execute(text('SELECT status FROM m2_business_context_builds WHERE confirmation_id=:id'),{'id':cid}).scalar_one()=='PENDING'


def test_PG05_construct_persist_readback_idempotent_retrieval(lab):
    mid,cid,uid=confirmed(lab,'We guarantee profit.')
    bind(lab,mid,cid,uid)
    response=build(lab,mid,cid)
    result=response.json(); packet=result['packet']; ctx=result['context_id']
    assert response.headers['cache-control']=='no-store'
    assert packet['confirmed_uncertainty']['id']==uid
    assert packet['findings'][0]['review_state']=='CANDIDATE'
    assert packet['findings'][0]['business_facts_verified'] is False
    assert all(value is False for value in packet['permissions'].values())
    with lab['db'].connect() as independent:
        row=independent.execute(text('SELECT * FROM m2_business_contexts WHERE context_id=:id'),{'id':ctx}).mappings().one()
        assert row['packet_json']==packet and row['packet_hash']==packet['packet_hash']
        assert source_hash({k:v for k,v in packet.items() if k!='packet_hash'})==row['packet_hash']
        assert json.loads(row['canonical_body'])=={k:v for k,v in packet.items() if k!='packet_hash'}
        assert str(row['owner_user_id'])==str(lab['actor']) and str(row['confirmation_id'])==cid
    replay=build(lab,mid,cid,200).json()
    assert replay['context_id']==ctx and replay['replayed'] is True and replay['created_at']==result['created_at']
    retrieved=lab['request']('GET',f'/assessments/{mid}/business-contexts/{ctx}').json()
    assert retrieved['packet']==packet
    with lab['db'].connect() as independent:
        assert independent.execute(text('SELECT count(*) FROM m2_business_contexts WHERE confirmation_id=:id'),{'id':cid}).scalar_one()==1


def test_PG06_missing_binding_is_durable_hold_not_synthetic_context(lab):
    mid,cid,uid=confirmed(lab)
    response=build(lab,mid,cid,503)
    assert response.json()['detail']['code']=='BCB_BINDING_AUTHORITY_UNVERIFIED'
    status=lab['request']('GET',f'/assessments/{mid}/confirmations/{cid}/business-context-status').json()
    assert status['status']=='HELD' and status['context_id'] is None
    bind(lab,mid,cid,uid)
    build(lab,mid,cid)


def test_PG07_ownership_authentication_and_forged_input(lab):
    mid,cid,uid=confirmed(lab);bind(lab,mid,cid,uid)
    path=f'/assessments/{mid}/business-context'
    payload={'confirmation_id':cid,'expected_revision':3}
    lab['request']('POST',path,401,uid=None,json=payload)
    lab['request']('POST',path,403,uid=lab['staff'],json=payload)
    lab['request']('POST',path,403,uid=lab['suspended'],json=payload)
    lab['request']('POST',path,404,uid=lab['other'],json=payload)
    lab['request']('POST',path,422,json={**payload,'owner_id':str(lab['other']),'bindings':{'approved':True}})
    context=build(lab,mid,cid).json()['context_id']
    lab['request']('GET',f'/assessments/{mid}/business-contexts/{context}',404,uid=lab['other'])
    lab['request']('GET',f'/assessments/{uuid4()}/business-contexts/{context}',404)
    lab['request']('GET',f'/assessments/{mid}/business-contexts/{uuid4()}',404)


def test_PG08_stale_source_and_wrong_confirmation(lab):
    mid,cid,uid=confirmed(lab);bind(lab,mid,cid,uid)
    context=build(lab,mid,cid).json()['context_id']
    other_mid,other_cid,_=confirmed(lab)
    build(lab,mid,other_cid,404)
    answer(lab,mid,'M2-04','Revised fictional business description.',3)
    build(lab,mid,cid,409)
    lab['request']('GET',f'/assessments/{mid}/business-contexts/{context}',409)
    lab['request']('GET',f'/assessments/{mid}/confirmations/{cid}?expected_revision=3',409)
    status=lab['request']('GET',f'/assessments/{mid}/confirmations/{cid}/business-context-status').json()
    assert status['source_is_current'] is False


def test_PG09_packet_and_status_write_are_atomic_then_retry(lab,monkeypatch):
    from sitewise.repositories.business_context_repository import SqlBusinessContextUnit
    mid,cid,uid=confirmed(lab);bind(lab,mid,cid,uid)
    original=SqlBusinessContextUnit.record_build
    injected=[]
    def fail_after_insert(self,confirmation_id,owner_id,status,code,context_id=None):
        if status=='PERSISTED' and not injected:
            injected.append(True)
            self.session.execute(text('SELECT 1/0'))
        return original(self,confirmation_id,owner_id,status,code,context_id)
    monkeypatch.setattr(SqlBusinessContextUnit,'record_build',fail_after_insert)
    build(lab,mid,cid,503)
    with lab['db'].connect() as independent:
        assert independent.execute(text('SELECT count(*) FROM m2_business_contexts WHERE confirmation_id=:id'),{'id':cid}).scalar_one()==0
        assert independent.execute(text('SELECT status FROM m2_business_context_builds WHERE confirmation_id=:id'),{'id':cid}).scalar_one()=='FAILED'
    build(lab,mid,cid)


def test_PG10_answer_failure_rolls_back_revision_and_row(lab,monkeypatch):
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    mid=create(lab)
    original=SqlModelM2Repository.save_answer
    def fail(self,*args,**kwargs):
        original(self,*args,**kwargs)
        self.session.execute(text('SELECT 1/0'))
    monkeypatch.setattr(SqlModelM2Repository,'save_answer',fail)
    answer(lab,mid,'M2-01','SYNTHETIC_A',0,expected=503)
    with lab['db'].connect() as independent:
        assert independent.execute(text('SELECT revision FROM m2_assessments WHERE id=:id'),{'id':mid}).scalar_one()==0
        assert independent.execute(text('SELECT count(*) FROM m2_answer_revisions WHERE assessment_id=:id'),{'id':mid}).scalar_one()==0


def test_PG11_missing_source_schema_fails_safely(lab):
    mid,cid,uid=confirmed(lab);bind(lab,mid,cid,uid)
    with lab['db'].begin() as connection:
        connection.execute(text('ALTER TABLE m2_clarification_events RENAME TO test_hidden_clarifications'))
    try:
        lab['request']('GET',f'/assessments/{mid}/confirmed-review?confirmation_id={cid}&expected_revision=3',503)
        build(lab,mid,cid,503)
    finally:
        with lab['db'].begin() as connection:
            connection.execute(text('ALTER TABLE test_hidden_clarifications RENAME TO m2_clarification_events'))


def test_PG12_sql_integrity_append_only_and_default_deny_rls(lab):
    from sqlalchemy.exc import DBAPIError
    mid,cid,uid=confirmed(lab);bind(lab,mid,cid,uid)
    ctx=build(lab,mid,cid).json()['context_id']
    from sitewise.db.models.business_context_schema import contexts
    with lab['db'].connect() as connection:
        record=dict(connection.execute(contexts.select().where(contexts.c.context_id==UUID(ctx))).mappings().one())
        record.update(context_id=uuid4(),packet_hash='0'*64)
        with pytest.raises(DBAPIError) as invalid:
            connection.execute(contexts.insert().values(**record))
        assert invalid.value.orig.pgcode=='23514'
        connection.rollback()
    with lab['db'].connect() as connection:
        for statement,params in [
            ('UPDATE m2_business_contexts SET packet_hash=:hash WHERE context_id=:id',{'hash':'0'*64,'id':ctx}),
            ('DELETE FROM m2_confirmation_snapshots WHERE id=:id',{'id':cid}),
            ("UPDATE m2_item_versions SET question_text='changed' WHERE instrument_id=:id",{'id':lab['iid']})]:
            with pytest.raises(DBAPIError): connection.execute(text(statement),params)
            connection.rollback()
    with lab['db'].begin() as connection:
        connection.execute(text('CREATE ROLE m2_bcb_no_policy NOLOGIN NOSUPERUSER NOBYPASSRLS'))
        connection.execute(text('GRANT USAGE ON SCHEMA public TO m2_bcb_no_policy'))
        connection.execute(text('GRANT SELECT ON m2_business_contexts TO m2_bcb_no_policy'))
        connection.execute(text('SET LOCAL ROLE m2_bcb_no_policy'))
        assert connection.execute(text('SELECT count(*) FROM m2_business_contexts')).scalar_one()==0


def test_PG13_production_binding_factory_authorizes_owner_and_refuses_others(lab):
    """The wired factory now resolves from M2; refusal is by authorization, not absence."""
    from sitewise import dependencies as deps
    from sitewise.core.config import settings
    mid,cid,uid=confirmed(lab)
    override=lab['app'].dependency_overrides.pop(deps.get_bcb_bindings_resolver_factory)
    try:
        created=build(lab,mid,cid)
        assert created.status_code==201
        packet=created.json()['packet']
        assert packet['identity']['owner_id']==str(lab['actor'])
        assert packet['confirmation']['id']==cid and packet['geography'] is None
        payload={'confirmation_id':cid,'expected_revision':3}
        path=f'/assessments/{mid}/business-context'
        lab['request']('POST',path,401,uid=None,json=payload)
        lab['request']('POST',path,403,uid=lab['staff'],json=payload)
        lab['request']('POST',path,404,uid=lab['other'],json=payload)
        with lab['db'].connect() as independent:
            assert independent.execute(text('SELECT count(*) FROM m2_business_contexts '
                'WHERE confirmation_id=:id'),{'id':cid}).scalar_one()==1
    finally: lab['app'].dependency_overrides[deps.get_bcb_bindings_resolver_factory]=override
    before=settings.m2_bcb_persistence_enabled
    settings.m2_bcb_persistence_enabled=False
    try:
        response=build(lab,mid,cid,503)
        assert response.json()['detail']['code']=='BCB_PERSISTENCE_NOT_CONFIGURED'
    finally: settings.m2_bcb_persistence_enabled=before


def test_PG14_expired_grant_and_changed_source_binding(lab):
    mid,cid,uid=confirmed(lab);bind(lab,mid,cid,uid)
    ctx=build(lab,mid,cid).json()['context_id']
    with lab['db'].begin() as connection:
        connection.execute(text("UPDATE test_bcb_bindings SET decision_json=jsonb_set(decision_json,'{valid_until}','\"2000-01-01T00:00:00+00:00\"') WHERE confirmation_id=:id"),{'id':cid})
    lab['request']('GET',f'/assessments/{mid}/business-contexts/{ctx}',409)
    with lab['db'].begin() as connection:
        connection.execute(text("UPDATE test_bcb_bindings SET decision_json=jsonb_set(decision_json,'{valid_until}','\"2099-01-01T00:00:00+00:00\"'),bindings_json=jsonb_set(bindings_json,'{snapshot_id}','\"SYNTHETIC-NEW-SNAPSHOT\"') WHERE confirmation_id=:id"),{'id':cid})
    lab['request']('GET',f'/assessments/{mid}/business-contexts/{ctx}',409)
    new=build(lab,mid,cid).json()
    assert new['context_id']!=ctx


def test_PG15_decision_reference_revision_and_request_idempotency(lab):
    mid=create(lab)
    path=f'/assessments/{mid}/findings/{uuid4()}/decisions'
    payload={'expected_revision':0,'request_id':str(uuid4()),'decision':'KEEP_ORIGINAL'}
    lab['request']('POST',path,404,json=payload)
    answer(lab,mid,'M2-04','We guarantee profit.',0)
    answer(lab,mid,'M2-01','SYNTHETIC_A',1)
    answer(lab,mid,'M2-05','TAKEAWAY_FOCUSED',2)
    finding=lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',json={'expected_revision':3}).json()['findings'][0]
    path=f"/assessments/{mid}/findings/{finding['id']}/decisions"
    lab['request']('POST',path,409,json=payload)
    payload['expected_revision']=3
    first=lab['request']('POST',path,json=payload).json()
    replay=lab['request']('POST',path,json=payload).json()
    assert first['event']['id']==replay['event']['id'] and replay['replayed'] is True
    lab['request']('POST',path,409,json={**payload,'decision':'REVIEW_LATER'})
    lab['request']('POST',path,422,json={**payload,'decision':'RESOLVED'})


def test_PG16_confirmation_and_pending_status_roll_back_together(lab,monkeypatch):
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    mid=create(lab)
    answer(lab,mid,'M2-01','SYNTHETIC_A',0)
    answer(lab,mid,'M2-05','TAKEAWAY_FOCUSED',1)
    lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',json={'expected_revision':2})
    lab['request']('POST',f'/assessments/{mid}/review',json={'expected_revision':2})
    original=SqlModelM2Repository.create_confirmation
    def fail(self,*args,**kwargs):
        original(self,*args,**kwargs)
        self.session.execute(text('SELECT 1/0'))
    monkeypatch.setattr(SqlModelM2Repository,'create_confirmation',fail)
    lab['request']('POST',f'/assessments/{mid}/confirm',503,json={'expected_revision':2,'acknowledged_issue_ids':[]})
    with lab['db'].connect() as independent:
        assert independent.execute(text('SELECT confirmed_revision FROM m2_assessments WHERE id=:id'),{'id':mid}).scalar_one() is None
        for table in ('m2_confirmation_snapshots','m2_business_context_builds'):
            assert independent.execute(text(f'SELECT count(*) FROM {table} WHERE assessment_id=:id'),{'id':mid}).scalar_one()==0


def test_PG17_concurrent_duplicate_context_builds_produce_one_row(lab):
    from concurrent.futures import ThreadPoolExecutor
    mid,cid,uid=confirmed(lab);bind(lab,mid,cid,uid)
    barrier=threading.Barrier(2)
    def execute(_):
        barrier.wait(timeout=5)
        return build(lab,mid,cid,(200,201))
    with ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(execute,range(2)))
    assert sorted(r.status_code for r in results)==[200,201]
    assert len({r.json()['context_id'] for r in results})==1
    with lab['db'].connect() as independent:
        assert independent.execute(text('SELECT count(*) FROM m2_business_contexts WHERE confirmation_id=:id'),{'id':cid}).scalar_one()==1
        status=independent.execute(text('SELECT status,attempt_count FROM m2_business_context_builds WHERE confirmation_id=:id'),{'id':cid}).one()
        assert tuple(status)==('PERSISTED',2)


def test_PG18_tampered_confirmation_digest_is_refused(lab):
    mid,cid,uid=confirmed(lab);bind(lab,mid,cid,uid)
    # Explicit isolated privileged fault injection, never a production edit API.
    with lab['db'].begin() as connection:
        original=connection.execute(text('SELECT snapshot_digest FROM m2_confirmation_snapshots WHERE id=:id'),{'id':cid}).scalar_one()
        connection.execute(text('ALTER TABLE m2_confirmation_snapshots DISABLE TRIGGER m2_bcb_append_only'))
        connection.execute(text('UPDATE m2_confirmation_snapshots SET snapshot_digest=:hash WHERE id=:id'),{'id':cid,'hash':'0'*64})
        connection.execute(text('SET CONSTRAINTS refresh_workflow IMMEDIATE'))
        connection.execute(text('ALTER TABLE m2_confirmation_snapshots ENABLE TRIGGER m2_bcb_append_only'))
    try:
        build(lab,mid,cid,409)
        lab['request']('GET',f'/assessments/{mid}/confirmations/{cid}?expected_revision=3',409)
    finally:
        with lab['db'].begin() as connection:
            connection.execute(text('ALTER TABLE m2_confirmation_snapshots DISABLE TRIGGER m2_bcb_append_only'))
            connection.execute(text('UPDATE m2_confirmation_snapshots SET snapshot_digest=:hash WHERE id=:id'),{'id':cid,'hash':original})
            connection.execute(text('SET CONSTRAINTS refresh_workflow IMMEDIATE'))
            connection.execute(text('ALTER TABLE m2_confirmation_snapshots ENABLE TRIGGER m2_bcb_append_only'))


def test_PG19_invalid_finding_source_cannot_be_confirmed(lab):
    from sitewise.db.models.m2_schema import findings
    from sitewise.domain.bdj_candidate_rules import RULE_VERSION
    mid=create(lab)
    answer(lab,mid,'M2-01','SYNTHETIC_A',0)
    answer(lab,mid,'M2-05','TAKEAWAY_FOCUSED',1)
    lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',json={'expected_revision':2})
    lab['request']('POST',f'/assessments/{mid}/review',json={'expected_revision':2})
    fid=uuid4()
    with lab['db'].begin() as connection:
        connection.execute(findings.insert().values(id=fid,assessment_id=UUID(mid),assessment_revision=2,
            rule_id='SYNTHETIC_BAD_SOURCE',rule_version=RULE_VERSION,source_answer_ids=[str(uuid4())],
            issue_type='TEST',explanation='Malformed synthetic source',not_proven='No fact verified',
            next_action='Review',review_state='CANDIDATE'))
    lab['request']('POST',f'/assessments/{mid}/confirm',409,json={
        'expected_revision':2,'acknowledged_issue_ids':[str(fid)]})
    with lab['db'].connect() as independent:
        assert independent.execute(text('SELECT count(*) FROM m2_confirmation_snapshots WHERE assessment_id=:id'),{'id':mid}).scalar_one()==0


def test_PG20_unsupported_or_forged_scope_cannot_open_context(lab):
    mid,cid,uid=confirmed(lab);bind(lab,mid,cid,uid)
    with lab['db'].begin() as connection:
        connection.execute(text("UPDATE test_bcb_bindings SET request_json=jsonb_set(request_json,'{tenant_id}','\"OTHER-TEST-TENANT\"') WHERE confirmation_id=:id"),{'id':cid})
    build(lab,mid,cid,403)
    with lab['db'].connect() as independent:
        assert independent.execute(text('SELECT count(*) FROM m2_business_contexts WHERE confirmation_id=:id'),{'id':cid}).scalar_one()==0


def test_PG21_instrument_approval_withdrawal_blocks_context_and_new_answers(lab):
    mid,cid,uid=confirmed(lab);bind(lab,mid,cid,uid)
    with lab['db'].begin() as connection:
        connection.execute(text("UPDATE m2_instrument_versions SET approval_state='DRAFT' WHERE id=:id"),{'id':lab['iid']})
    try:
        build(lab,mid,cid,409)
        answer(lab,mid,'M2-04','Changed synthetic source',3,expected=409)
        lab['request']('POST','/assessments',409,json={'instrument_version_id':str(lab['iid'])})
    finally:
        with lab['db'].begin() as connection:
            connection.execute(text("UPDATE m2_instrument_versions SET approval_state='AUTHORIZED' WHERE id=:id"),{'id':lab['iid']})


def test_PG22_legacy_snapshot_stays_readable_but_context_pins_are_required(lab):
    mid,cid,uid=confirmed(lab);bind(lab,mid,cid,uid)
    with lab['db'].begin() as connection:
        snapshot=connection.execute(text('SELECT snapshot_json FROM m2_confirmation_snapshots WHERE id=:id'),{'id':cid}).scalar_one()
        for key in ('snapshot_contract_version','bdj_rule_version','bdj_evaluation_id','review_event_id','finding_hashes','item_definition_hashes'):
            snapshot.pop(key)
        connection.execute(text('ALTER TABLE m2_confirmation_snapshots DISABLE TRIGGER m2_bcb_append_only'))
        connection.execute(text('UPDATE m2_confirmation_snapshots SET snapshot_json=CAST(:snapshot AS json),snapshot_digest=:hash WHERE id=:id'),
            {'id':cid,'snapshot':json.dumps(snapshot),'hash':source_hash(snapshot)})
        connection.execute(text('SET CONSTRAINTS refresh_workflow IMMEDIATE'))
        connection.execute(text('ALTER TABLE m2_confirmation_snapshots ENABLE TRIGGER m2_bcb_append_only'))
    lab['request']('GET',f'/assessments/{mid}/confirmations/{cid}?expected_revision=3')
    refused=build(lab,mid,cid,409)
    assert refused.json()['detail']['code']=='M2_CONFIRMATION_PROVENANCE_UNPINNED'


def test_PG23_unknown_answers_missing_uncertainty_and_external_evidence_stay_unknown(lab):
    mid,cid,uid=confirmed(lab,uncertainty=False,service_unknown=True)
    bind(lab,mid,cid,uid)
    packet=build(lab,mid,cid).json()['packet']
    answer_row=next(a for a in packet['m2_answers'] if a['item_key']=='M2-05')
    assert answer_row['answer_state']=='NOT_DECIDED' and answer_row['value'] is None
    assert packet['confirmed_uncertainty'] is None and packet['supporting_sources']==[]
    unknowns={u['code'] for u in packet['unknowns']}
    assert {'M2_NONANSWER','UNCERTAINTY_NOT_CONFIRMED','EXTERNAL_EVIDENCE_MISSING'} <= unknowns


def test_PG24_existing_admin_alias_requires_aal2_and_uses_canonical_role(lab):
    mid,cid,uid=confirmed(lab);bind(lab,mid,cid,uid)
    with lab['db'].begin() as connection:
        connection.execute(text("UPDATE users SET role='administrator' WHERE user_id=:id"),{'id':lab['actor']})
        connection.execute(text("UPDATE test_bcb_bindings SET request_json=jsonb_set(request_json,'{role}','\"admin\"'),decision_json=jsonb_set(decision_json,'{scope,role}','\"admin\"') WHERE confirmation_id=:id"),{'id':cid})
    path=f'/assessments/{mid}/business-context'
    payload={'confirmation_id':cid,'expected_revision':3}
    try:
        lab['request']('POST',path,403,json=payload)
        lab['request']('POST',path,201,aal='aal2',json=payload)
    finally:
        with lab['db'].begin() as connection:
            connection.execute(text("UPDATE users SET role='entrepreneur' WHERE user_id=:id"),{'id':lab['actor']})


def test_PG25_wrong_database_target_rejected_before_source_access(lab,monkeypatch):
    from pydantic import SecretStr
    from sitewise.core.config import settings
    mid=create(lab)
    monkeypatch.setattr(settings,'m2_database_url',SecretStr('postgresql+psycopg2://unused@127.0.0.1:1/Final_Location_Analysis'))
    response=lab['request']('GET',f'/assessments/{mid}',503)
    assert response.json()['detail']['code']=='M2_DATABASE_TARGET_UNVERIFIED'


def test_PG26_valid_multi_answer_reconfirmation_and_context_array_readback(lab):
    mid,old_cid,_=confirmed(lab,uncertainty=False)
    answer(lab,mid,'M2-06',['TEST_A','TEST_B'],3)
    lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',json={'expected_revision':4})
    lab['request']('POST',f'/assessments/{mid}/review',json={'expected_revision':4})
    cid=lab['request']('POST',f'/assessments/{mid}/confirm',json={
        'expected_revision':4,'acknowledged_issue_ids':[]}).json()['id']
    assert cid!=old_cid
    bind(lab,mid,cid)
    response=build(lab,mid,cid,revision=4).json()
    declaration=next(a for a in response['packet']['m2_answers'] if a['item_key']=='M2-06')
    assert declaration['value']==['TEST_A','TEST_B']
    with lab['db'].connect() as independent:
        assert independent.execute(text('SELECT value_json FROM m2_answer_revisions WHERE id=:id'),
            {'id':declaration['answer_revision_id']}).scalar_one()==['TEST_A','TEST_B']
        assert independent.execute(text('SELECT assessment_revision FROM m2_business_contexts WHERE context_id=:id'),
            {'id':response['context_id']}).scalar_one()==4


def test_PG34_initial_M2_entry_without_confirmation_and_persisted_source(lab):
    catalogue=lab['request']('GET','/instruments').json()['items']
    assert any(i['id']==str(lab['iid']) for i in catalogue)
    mid=create(lab)
    draft=lab['request']('GET','/assessments/'+mid).json()
    assert draft['assessment']['confirmed_revision'] is None and not draft['current_confirmation_valid']
    assert draft['instrument']['id']==str(lab['iid']) and draft['items']
    answer(lab,mid,'M2-04','An entrepreneur-authored test description.',0)
    initial=lab['request']('GET',f'/assessments/{mid}/source-projection?expected_revision=1').json()
    assert initial['confirmed'] is False and initial['declarations'][0]['value']=='An entrepreneur-authored test description.'
    assert any(a['id']==mid for a in lab['request']('GET','/assessments').json()['items'])
    assert not any(a['id']==mid for a in lab['request']('GET','/assessments',uid=lab['other']).json()['items'])
    with lab['db'].connect() as c:
        row=c.execute(text("SELECT a.value_json,a.assessment_revision FROM m2_answer_revisions a JOIN m2_item_versions i ON a.item_version_id=i.id WHERE a.assessment_id=:id AND i.item_key='M2-04'"),{'id':mid}).one()
        assert row==('An entrepreneur-authored test description.',1)
        assert c.execute(text('SELECT count(*) FROM m2_confirmation_snapshots WHERE assessment_id=:id'),{'id':mid}).scalar_one()==0
    lab['request']('GET',f'/assessments/{mid}/source-projection?expected_revision=0',409)
    lab['request']('GET',f'/assessments/{mid}/source-projection?expected_revision=1',404,uid=lab['other'])


def test_PG35_M2_catalogue_auth_and_unregistered_instrument_hold(lab):
    for path in ('/instruments','/assessments'):
        lab['request']('GET',path,401,uid=None)
        lab['request']('GET',path,403,uid=lab['staff'])
    lab['request']('GET','/instruments?limit=101',422)
    initial=lab['request']('GET','/instruments').json()['items']
    assert any(row['id']==str(lab['iid']) for row in initial)
    with lab['db'].begin() as c:c.execute(text("UPDATE m2_instrument_versions SET approval_state='DRAFT' WHERE id=:id"),{'id':lab['iid']})
    try:
        assert lab['request']('GET','/instruments').json()['items']==[row for row in initial if row['id']!=str(lab['iid'])]
        lab['request']('POST','/assessments',409,json={'instrument_version_id':str(lab['iid'])})
    finally:
        with lab['db'].begin() as c:c.execute(text("UPDATE m2_instrument_versions SET approval_state='AUTHORIZED' WHERE id=:id"),{'id':lab['iid']})


def test_PG36_owned_activity_does_not_require_confirmation(lab):
    mid=create(lab);answer(lab,mid,'M2-04','Persisted before confirmation.',0)
    history=lab['request']('GET',f'/assessments/{mid}/activity').json()
    assert history['scope']=='PERSISTED_M2_ACTIVITY' and len(history['events'])==2
    assert history['events'][0]['kind']=='ANSWER_SAVED'
    with lab['db'].connect() as c:
        assert str(c.execute(text('SELECT id FROM m2_answer_revisions WHERE assessment_id=:id'),{'id':mid}).scalar_one())==history['events'][0]['event_id']
    lab['request']('GET',f'/assessments/{mid}/activity',404,uid=lab['other'])
    lab['request']('GET',f'/assessments/{mid}/activity',401,uid=None)


def test_activity_metadata_currentness_redaction_and_bounded_history(lab):
    mid,cid,uid=confirmed(lab,'PRIVATE DECLARATION: We guarantee profit.')
    bind(lab,mid,cid,uid); build(lab,mid,cid)
    before=lab['request']('GET',f'/assessments/{mid}/activity').json()
    kinds={e['kind'] for e in before['events']}
    assert {'ASSESSMENT_CREATED','CANDIDATE_FINDING_RECORDED','UNCERTAINTY_CONFIRMED',
            'CONTEXT_PERSISTED','BDJ_EVALUATED','CONTEXT_CONFIRMED'} <= kinds
    assert before['authorization_decisions_included'] is False
    assert before['bcb_history_available'] is True
    assert before['bcb_statuses'][0]['status']=='PERSISTED'
    assert 'PRIVATE DECLARATION' not in json.dumps(before)
    assert 'exact_text' not in json.dumps(before) and 'packet_json' not in json.dumps(before)
    assert 'value_json' not in json.dumps(before) and 'snapshot_json' not in json.dumps(before)
    keys=[(e['occurred_at'],e['kind'],e['event_id']) for e in before['events']]
    assert keys==sorted(keys,reverse=True) and len(keys)==len(set(keys))
    original=next(e for e in before['events'] if e['kind']=='CONTEXT_PERSISTED')
    answer(lab,mid,'M2-04','A correction, not a new history outcome.',3)
    after=lab['request']('GET',f'/assessments/{mid}/activity').json()
    historical=next(e for e in after['events'] if e['kind']=='CONTEXT_PERSISTED')
    assert historical['status']==original['status']=='PERSISTED'
    assert historical['event_id']==original['event_id']
    assert historical['source_is_current'] is False
    assert after['bcb_statuses'][0]['source_is_current'] is False
    limited=lab['request']('GET',f'/assessments/{mid}/activity?limit=2').json()
    assert len(limited['events'])==2 and limited['truncated'] is True
    lab['request']('GET',f'/assessments/{mid}/activity',404,uid=lab['other'])
    lab['request']('GET',f'/assessments/{mid}/activity',403,uid=lab['staff'])


def test_activity_missing_optional_bcb_source_preserves_m2_history(lab):
    mid=create(lab)
    with lab['db'].begin() as c:
        c.execute(text('ALTER TABLE m2_business_contexts RENAME TO test_hidden_contexts'))
    try:
        data=lab['request']('GET',f'/assessments/{mid}/activity').json()
        assert data['bcb_history_available'] is False
        assert data['bcb_statuses']==[]
        assert data['events'][0]['kind']=='ASSESSMENT_CREATED'
    finally:
        with lab['db'].begin() as c:
            c.execute(text('ALTER TABLE test_hidden_contexts RENAME TO m2_business_contexts'))


def test_activity_bcb_snapshot_failure_then_recovery_is_not_fake_attempt_history(lab,monkeypatch):
    from sitewise.repositories.business_context_repository import SqlBusinessContextUnit
    mid,cid,uid=confirmed(lab);bind(lab,mid,cid,uid)
    original=SqlBusinessContextUnit.put_context
    def unavailable(self,*args): self.session.execute(text('SELECT 1/0'))
    monkeypatch.setattr(SqlBusinessContextUnit,'put_context',unavailable)
    build(lab,mid,cid,expected=503)
    failed=lab['request']('GET',f'/assessments/{mid}/activity').json()
    assert failed['bcb_statuses'][0]['status']=='FAILED'
    monkeypatch.setattr(SqlBusinessContextUnit,'put_context',original)
    build(lab,mid,cid)
    recovered=lab['request']('GET',f'/assessments/{mid}/activity').json()
    assert recovered['bcb_statuses'][0]['status']=='PERSISTED'
    assert recovered['bcb_statuses'][0]['attempt_count']>=2
    # Existing mutable build store cannot retain past failure details. Do not
    # invent a FAILED timeline event from the counter or latest state.
    assert not any(e.get('status')=='FAILED' for e in recovered['events'])


def test_activity_browser_persisted_metadata_cross_owner_and_unavailable(lab,monkeypatch):
    import subprocess
    if os.environ.get('ACTIVITY_HISTORY_BROWSER')!='1':
        pytest.skip('Explicit isolated compiled Activity History acceptance only.')
    from sitewise.core.config import settings
    from sitewise.db.models.favourite_property import FavouriteProperty
    FavouriteProperty.__table__.create(lab['db'],checkfirst=True)
    mid,cid,uid=confirmed(lab,'PRIVATE-HISTORY-CONTENT: We guarantee profit.')
    bind(lab,mid,cid,uid);build(lab,mid,cid)
    answer(lab,mid,'M2-04','PRIVATE-HISTORY-CONTENT corrected',3)
    other=lab['request']('POST','/assessments',201,uid=lab['other'],
        json={'instrument_version_id':str(lab['iid'])}).json()['id']
    root=Path(__file__).resolve().parents[3]
    output=Path(os.environ['M2_BCB_EVIDENCE'])
    cfg=Path(os.environ['M2_BCB_PRIVATE_CLUSTER'])/'activity_browser_identity.json'
    data={'base':lab['base'],'token':lab['token'](lab['actor']),
          'assessment':mid,'otherAssessment':other,'output':str(output),'historyIncrement':True}
    def browser():
        cfg.write_text(json.dumps(data),encoding='utf-8')
        result=subprocess.run(['node',str(root/'fyp_jaspr_web/tool/part_two_live_http.cjs'),str(cfg)],
            cwd=root,capture_output=True,text=True,encoding='utf-8',timeout=120)
        with (output/'activity_browser.log').open('a',encoding='utf-8') as f:
            f.write(result.stdout+result.stderr)
        assert result.returncode==0,result.stdout+result.stderr
    try:
        browser()
        data['expectUnavailable']=True
        monkeypatch.setattr(settings,'m2_expected_database','unavailable_history_test_target')
        browser()
    finally:cfg.unlink(missing_ok=True)


def test_PG37_actual_Jaspr_M2_controls_to_same_FastAPI_Postgres(lab):
    import subprocess
    if not os.environ.get('PART_TWO_JASPR'):pytest.skip('Set PART_TWO_JASPR=1 for actual Jaspr/HTTP component acceptance.')
    mid=create(lab)
    env=os.environ.copy();env.update(SITEWISE_API_BASE=lab['base'],PART_TWO_M2_ID=mid,
        PART_TWO_M2_TOKEN=lab['token'](lab['actor']),PART_TWO_ACTOR=str(lab['actor']))
    context_mid,context_cid,context_uid=confirmed(lab)
    bind(lab,context_mid,context_cid,context_uid)
    context=build(lab,context_mid,context_cid).json()
    env.update(V13_CONTEXT_ASSESSMENT=context_mid,V13_CONTEXT_CONFIRMATION=context_cid,
               V13_CONTEXT_ID=context['context_id'])
    root=Path(__file__).resolve().parents[3]
    outcome=subprocess.run([str(root/'.fvm/flutter_sdk/bin/dart.bat'),'test','test/m2_entry_http_test.dart','--reporter','expanded'],
        env=env,cwd=root/'fyp_jaspr_web',capture_output=True,text=True,encoding='utf-8',timeout=180)
    (Path(os.environ['M2_BCB_EVIDENCE'])/'jaspr_m2_http.log').write_text(outcome.stdout+outcome.stderr,encoding='utf-8')
    assert outcome.returncode==0,outcome.stdout+outcome.stderr
    with lab['db'].connect() as c:
        stored=c.execute(text('SELECT context_id,assessment_id,confirmation_id,assessment_revision,packet_hash '
            'FROM m2_business_contexts WHERE context_id=:id'),{'id':context['context_id']}).mappings().one()
        (Path(os.environ['M2_BCB_EVIDENCE'])/'v13_context_sql_readback.json').write_text(
            json.dumps({'scope':'PRIVATE_SYNTHETIC_ONLY','context':dict(stored),
                'qj_execution_authorized':context['qj_execution_authorized'],
                'qg_execution_authorized':context['qg_execution_authorized']},default=str,indent=2),encoding='utf-8')
        receipt=json.loads((Path(os.environ['M2_BCB_EVIDENCE'])/'v13_uncertainty_http.json').read_text())
        uncertainty=c.execute(text('SELECT id,confirmation_id,actor_user_id FROM m2_confirmed_uncertainties '
            'WHERE id=:id'),{'id':receipt['uncertainty_id']}).mappings().one()
        assert str(uncertainty['confirmation_id'])==receipt['confirmation_id']
        assert uncertainty['actor_user_id']==lab['actor']
        assert c.execute(text('SELECT count(*) FROM m2_confirmed_uncertainties WHERE confirmation_id=:cid'),
            {'cid':receipt['confirmation_id']}).scalar_one()==1
        (Path(os.environ['M2_BCB_EVIDENCE'])/'v13_uncertainty_sql_readback.json').write_text(
            json.dumps(dict(uncertainty),default=str,indent=2),encoding='utf-8')
    paths=lab['app'].openapi()['paths']
    body=paths['/api/v1/m2/assessments/{assessment_id}/business-context']['post']['responses']
    assert body['200']['content']['application/json']['schema']['$ref'].endswith('/ContextResponse')
    assert body['201']['content']['application/json']['schema']['$ref'].endswith('/ContextResponse')
    assert paths['/api/v1/m2/confirmations/{confirmation_id}/uncertainty']['post']['responses']['200'][
        'content']['application/json']['schema']['$ref'].endswith('/UncertaintyResponse')
    with lab['db'].connect() as c:
        assert c.execute(text('SELECT confirmed_revision FROM m2_assessments WHERE id=:id'),{'id':mid}).scalar_one() is None
        assert c.execute(text("SELECT value_json FROM m2_answer_revisions WHERE assessment_id=:id"),{'id':mid}).scalar_one()=='Saved from actual Jaspr M2 controls.'
        submitted=json.loads((Path(os.environ['M2_BCB_EVIDENCE'])/'jaspr_submission_http.json').read_text())
        submitted_mid=submitted['assessment_id']
        assert c.execute(text('SELECT confirmed_revision FROM m2_assessments WHERE id=:id'),{'id':submitted_mid}).scalar_one()==3
        assert c.execute(text('SELECT count(*) FROM m2_bdj_evaluations WHERE assessment_id=:id'),{'id':submitted_mid}).scalar_one()==1
        snapshot=c.execute(text('SELECT snapshot_json FROM m2_confirmation_snapshots WHERE assessment_id=:id'),{'id':submitted_mid}).scalar_one()
        description=next(a for a in snapshot['answer_revisions'] if a['item_key']=='M2-04')
        assert description['value']=='We guarantee profit.'
        assert len(snapshot['finding_decision_event_refs'])==1
        (Path(os.environ['M2_BCB_EVIDENCE'])/'jaspr_submission_sql_readback.json').write_text(json.dumps({
            'assessment_id':submitted_mid,'confirmation_revision':3,'evaluation_receipts':1,
            'confirmed_description':description,'finding_decision_count':1,'scope':'PRIVATE_POSTGRES_ONLY'},default=str,indent=2))


def test_compiled_browser_M2_submission_and_correction(lab):
    """Browser-only M2 -> BDJ -> confirmation; no BCB/CQ/provider activation."""
    import subprocess
    if os.environ.get('M2_SUBMISSION_BROWSER')!='1':
        pytest.skip('Explicit isolated compiled-browser verification only.')
    assert Path(os.environ['SITEWISE_FRONTEND_DIST']).is_dir()
    from sitewise.db.models.favourite_property import FavouriteProperty
    FavouriteProperty.__table__.create(lab['db'],checkfirst=True)
    mid=create(lab)
    root=Path(__file__).resolve().parents[3]
    output=Path(os.environ['M2_BCB_EVIDENCE'])
    cfg=Path(os.environ['M2_BCB_PRIVATE_CLUSTER'])/'m2_browser_identity.json'
    cfg.write_text(json.dumps({'base':lab['base'],'token':lab['token'](lab['actor']),
        'assessment':mid,'output':str(output),'submitBoundary':True}),encoding='utf-8')
    try:
        result=subprocess.run(['node',str(root/'fyp_jaspr_web/tool/part_two_live_http.cjs'),str(cfg)],
            cwd=root,capture_output=True,text=True,encoding='utf-8',timeout=180)
        (output/'browser_execution.log').write_text(result.stdout+result.stderr,encoding='utf-8')
        assert result.returncode==0,result.stdout+result.stderr
    finally:cfg.unlink(missing_ok=True)
    with lab['db'].connect() as c:
        assert c.execute(text('SELECT confirmed_revision FROM m2_assessments WHERE id=:id'),{'id':mid}).scalar_one()==4
        snapshots=c.execute(text('SELECT assessment_revision,snapshot_json,snapshot_digest FROM m2_confirmation_snapshots WHERE assessment_id=:id ORDER BY assessment_revision'),{'id':mid}).mappings().all()
        assert [s['assessment_revision'] for s in snapshots]==[3,4]
        descriptions=[]
        for snapshot in snapshots:
            assert source_hash(snapshot['snapshot_json'])==snapshot['snapshot_digest']
            descriptions.append(next(a['value'] for a in snapshot['snapshot_json']['answer_revisions'] if a['item_key']=='M2-04'))
        assert descriptions==['We guarantee profit.','An entrepreneur correction after review.']
        receipts=list(c.execute(text('SELECT assessment_revision FROM m2_bdj_evaluations WHERE assessment_id=:id ORDER BY assessment_revision'),{'id':mid}).scalars())
        assert receipts==[3,4]
        (output/'browser_sql_readback.json').write_text(json.dumps({'assessment_id':mid,
            'confirmation_revisions':[3,4],'description_values':descriptions,'evaluation_revisions':receipts,
            'snapshot_digests_verified':True,'database':'project1_m2_bcb_test','production_acceptance':False},indent=2))


def test_PG38_compiled_Jaspr_and_native_Flutter_same_private_backend(lab):
    """Connected technical subset, NOT the unapproved QJ/bank/EE/report chain."""
    import importlib.util
    import subprocess
    if os.environ.get('PART_TWO_CROSS_APP')!='1':
        pytest.skip('Explicit isolated browser/device acceptance only.')
    root=Path(__file__).resolve().parents[3]
    out=Path(os.environ['M2_BCB_EVIDENCE'])
    private=Path(os.environ['M2_BCB_PRIVATE_CLUSTER'])
    assert Path(os.environ['SITEWISE_FRONTEND_DIST']).is_dir()
    # Existing app boot reads its saved list. Reuse the actual model in the
    # disposable DB; no API response interceptions or invented tables.
    from sitewise.db.models.favourite_property import FavouriteProperty
    FavouriteProperty.__table__.create(lab['db'],checkfirst=True)
    invitation_flow=os.environ.get('INVITATION_DEVICE_FLOW')=='1'
    mid=None if invitation_flow else create(lab)
    cfg=private/'browser_test_identity.json'
    cfg.write_text(json.dumps({'base':lab['base'],'token':lab['token'](lab['actor']),
        'assessment':mid or '', 'createViaUI':invitation_flow,'output':str(out)}),encoding='utf-8')
    def browser():
        result=subprocess.run(['node',str(root/'fyp_jaspr_web/tool/part_two_live_http.cjs'),str(cfg)],
            cwd=root,capture_output=True,text=True,encoding='utf-8',timeout=180)
        with (out/'browser_execution.log').open('a',encoding='utf-8') as f:f.write(result.stdout+result.stderr)
        assert result.returncode==0,result.stdout+result.stderr
    try:browser()
    finally:cfg.unlink(missing_ok=True)
    if invitation_flow:
        mid=json.loads((out/'browser_http.json').read_text())['created_assessment_id']
    with lab['db'].connect() as c:
        confirmation=c.execute(text('SELECT id FROM m2_confirmation_snapshots WHERE assessment_id=:id AND assessment_revision=3'),{'id':mid}).scalar_one()
        assert c.execute(text('SELECT count(*) FROM m2_answer_revisions WHERE assessment_id=:id'),{'id':mid}).scalar_one()==3
    cid=str(confirmation);bind(lab,mid,cid);context=build(lab,mid,cid).json()
    # Reuse the already existing private CQ release helper and existing
    # participant/invitations/session delivery; do not add another mechanism.
    spec=importlib.util.spec_from_file_location('private_cq_helpers',Path(__file__).parents[1]/'cq_runtime/test_postgres_api.py')
    helpers=importlib.util.module_from_spec(spec);spec.loader.exec_module(helpers)
    from sitewise.api.v1 import customer_questionnaire as api
    from sitewise.domain.customer_questionnaire import digest
    with lab['db'].begin() as c:
        c.execute(text('CREATE TABLE test_cq_authority(release_id uuid PRIMARY KEY,enabled boolean NOT NULL)'))
    lab['app'].dependency_overrides[api.get_cq_authority]=lambda:helpers.TestOnlyAuthority(
        'project1_m2_bcb_test','M2_BCB_PRIVATE_CLUSTER')
    rid,manifest=helpers.release(lab,mutate=helpers.english_only_manifest if invitation_flow else None)
    traces=[]
    def cq(method,path,actor,expected=200,**kwargs):
        response=httpx.request(method,lab['base']+'/api/v1/cq'+path,
            headers={'Authorization':'Bearer '+lab['token'](actor)},timeout=20,**kwargs)
        traces.append({'method':method,'path':'/api/v1/cq'+path,'actor':str(actor),
            'expected_http':expected,'actual_http':response.status_code,'output':response.json()})
        assert response.status_code==expected,response.text
        return response.json()
    campaign=cq('POST',f'/assessments/{mid}/campaign',lab['actor'],json={'release_id':rid})
    # This active, distinct fixture user is eligible only through the existing
    # participant relationship. No new global customer role is introduced.
    cq('POST',f"/campaigns/{campaign['id']}/participants",lab['actor'],json={'respondent_id':str(lab['other'])})
    invitation=cq('GET','/invitations',lab['other'])
    assert invitation['state']=='ready'
    session=None if invitation_flow else cq('POST','/sessions',lab['other'],json={'campaign_id':campaign['id'],'manifest_hash':digest(manifest),'locale':'BM'})
    if session is not None:cq('GET','/sessions/'+session['session_id'],lab['actor'],404)
    result={'scope':'CONNECTED_TECHNICAL_SUBSET_SYNTHETIC_BINDINGS','assessment_id':mid,
        'confirmation_id':cid,'context_id':context['context_id'],'campaign_id':campaign['id'],
        'session_id':session['session_id'] if session else None,'invitation_delivery_on_device':invitation_flow,'owner_id':str(lab['actor']),'respondent_id':str(lab['other']),
        'same_backend':lab['base'],'database':'project1_m2_bcb_test',
        'qj_to_cq_binding':'NOT_EXECUTED_NO_ADOPTED_MAPPING','aggregate_disclosure':'BLOCKED_REQUIREMENTS_GAP',
        'production_fielding_authorized':False,'native_result':'NOT_EXECUTED'}
    with lab['db'].connect() as c:
        result['independent_sql_before_customer']={
            'database':c.execute(text('SELECT current_database()')).scalar_one(),
            'm2_answer_revisions':c.execute(text('SELECT count(*) FROM m2_answer_revisions WHERE assessment_id=:id'),{'id':mid}).scalar_one(),
            'confirmation_revision':c.execute(text('SELECT assessment_revision FROM m2_confirmation_snapshots WHERE id=:id'),{'id':cid}).scalar_one(),
            'persisted_context_confirmation':str(c.execute(text('SELECT confirmation_id FROM m2_business_contexts WHERE context_id=:id'),{'id':context['context_id']}).scalar_one()),
            'campaign_assessment':str(c.execute(text('SELECT assessment_id FROM cq_campaigns WHERE id=:id'),{'id':campaign['id']}).scalar_one()),
        }
    overview=lab['request']('GET',f'/assessments/{mid}/workflow-overview').json()['projection_data']
    assert any(c['campaign_id']==campaign['id'] and c['receipts']==0 for c in overview['campaigns'])
    assert result['independent_sql_before_customer']=={'database':'project1_m2_bcb_test',
        'm2_answer_revisions':3,'confirmation_revision':3,'persisted_context_confirmation':cid,'campaign_assessment':mid}
    (out/'cross_app_api.json').write_text(json.dumps(traces,indent=2),encoding='utf-8')
    device=os.environ.get('PART_TWO_DEVICE')
    if device:
        adb=Path(os.environ['LOCALAPPDATA'])/'Android/Sdk/platform-tools/adb.exe'
        reverse=subprocess.run([str(adb),'-s',device,'reverse','tcp:62403','tcp:'+lab['base'].rsplit(':',1)[1]],capture_output=True,text=True,check=True)
        defines=private/'native_test_identity.json'
        defines.write_text(json.dumps({'API_BASE_URL':'http://127.0.0.1:62403','CQ_TEST_BASE':'http://127.0.0.1:62403',
            'CQ_TEST_TOKEN':lab['token'](lab['other']),'CQ_TEST_C1_SESSION':session['session_id'] if session else '',
            'CQ_TEST_CAMPAIGN_ID':campaign['id']}),encoding='utf-8')
        env=os.environ.copy();env['SITEWISE_ISOLATED_DEVICE_TEST']='1'
        capture_stop=threading.Event()
        def capture_device():
            seen=set();log=out/'native_flutter.log'
            markers={'FLOW_INVITATION_SCREEN_READY':'device_invitations.png',
                     'FLOW_QUESTION_SCREEN_READY':'device_question.png',
                     'FLOW_RECEIPT_SCREEN_READY':'device_receipt.png'}
            while not capture_stop.wait(.2):
                content=log.read_text(encoding='utf-8',errors='replace') if log.exists() else ''
                for marker,name in markers.items():
                    if marker in seen or marker not in content:continue
                    active=subprocess.run([str(adb),'-s',device,'shell','dumpsys','activity','activities'],capture_output=True,text=True)
                    resumed=[line for line in active.stdout.splitlines() if 'ResumedActivity' in line]
                    if not any('com.example.fyp.parttwotest' in line for line in resumed):continue
                    screen=subprocess.run([str(adb),'-s',device,'exec-out','screencap','-p'],capture_output=True)
                    if screen.returncode==0 and screen.stdout.startswith(b'\x89PNG'):
                        (out/name).write_bytes(screen.stdout);seen.add(marker)
        capture_thread=threading.Thread(target=capture_device,daemon=True)
        if invitation_flow:capture_thread.start()
        try:
            with (out/'native_flutter.log').open('w',encoding='utf-8') as log:
                executed=subprocess.run([str(root/'.fvm/flutter_sdk/bin/flutter.bat'),'test',
                    'integration_test/cq_invitation_delivery_test.dart' if invitation_flow else 'integration_test/part_two_customer_test.dart',
                    '-d',device,'--plain-name='+('invitation delivery EN' if invitation_flow else 'C1 BM manifest'),
                    '--dart-define-from-file='+str(defines),'--no-pub','--no-uninstall'],
                    cwd=root/'fyp_mobile_app',env=env,stdout=log,stderr=log,timeout=780)
            native_log=(out/'native_flutter.log').read_text(encoding='utf-8')
            result['native_exit_code']=executed.returncode
            result['native_result']='PASS' if executed.returncode==0 else (
                'BLOCKED_INSTALLATION' if 'INSTALL_FAILED_USER_RESTRICTED' in native_log else 'FAIL')
            assert executed.returncode==0,native_log[-10000:]
        finally:
            capture_stop.set()
            if invitation_flow:capture_thread.join(timeout=5)
            defines.unlink(missing_ok=True)
            subprocess.run([str(adb),'-s',device,'reverse','--remove','tcp:62403'],capture_output=True)
            (out/'connected_subset.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
        if invitation_flow:
            with lab['db'].connect() as c:
                session={'session_id':str(c.execute(text('SELECT id FROM cq_sessions WHERE campaign_id=:id'),{'id':campaign['id']}).scalar_one())}
            result['session_id']=session['session_id']
            cq('GET','/sessions/'+session['session_id'],lab['actor'],404)
        saved=cq('GET','/sessions/'+session['session_id'],lab['other'])
        assert saved['status']=='SUBMITTED'
        with lab['db'].connect() as c:
            stored=c.execute(text('SELECT payload_json FROM cq_submission_receipts WHERE session_id=:id'),{'id':session['session_id']}).scalar_one()
            assert stored==saved['receipt']
            assert c.execute(text('SELECT assessment_id FROM cq_campaigns WHERE id=:id'),{'id':campaign['id']}).scalar_one()==UUID(mid)
            result['independent_sql']={t:c.execute(text(f'SELECT count(*) FROM {t} WHERE session_id=:id'),{'id':session['session_id']}).scalar_one() for t in ('cq_answer_revisions','cq_effective_answers','cq_stimulus_deliveries','cq_submission_receipts')}
            assert result['independent_sql']=={'cq_answer_revisions':14,'cq_effective_answers':14,'cq_stimulus_deliveries':5,'cq_submission_receipts':1}
        result['receipt_hash']=stored['receipt_hash']
    (out/'cross_app_api.json').write_text(json.dumps(traces,indent=2),encoding='utf-8')
    (out/'connected_subset.json').write_text(json.dumps(result,indent=2),encoding='utf-8')


def test_PG39_existing_activity_layout_survives_actual_source_unavailability(lab,monkeypatch):
    import subprocess
    if os.environ.get('PART_TWO_CROSS_APP')!='1':
        pytest.skip('Explicit isolated browser acceptance only.')
    from sitewise.core.config import settings
    root=Path(__file__).resolve().parents[3]
    output=Path(os.environ['M2_BCB_EVIDENCE'])
    mid=create(lab)
    cfg=Path(os.environ['M2_BCB_PRIVATE_CLUSTER'])/'unavailable_browser_identity.json'
    cfg.write_text(json.dumps({'base':lab['base'],'token':lab['token'](lab['actor']),
        'assessment':mid,'output':str(output),'expectUnavailable':True}),encoding='utf-8')
    # The real target guard returns 503; do not intercept the API or connect
    # to a different database. Other application identity reads remain private.
    monkeypatch.setattr(settings,'m2_expected_database','deliberately_unavailable_test_target')
    try:
        outcome=subprocess.run(['node',str(root/'fyp_jaspr_web/tool/part_two_live_http.cjs'),str(cfg)],
            cwd=root,capture_output=True,text=True,encoding='utf-8',timeout=90)
        (output/'browser_unavailable_execution.log').write_text(outcome.stdout+outcome.stderr,encoding='utf-8')
        assert outcome.returncode==0,outcome.stdout+outcome.stderr
    finally:cfg.unlink(missing_ok=True)

# Supplied source remains test-only; the existing guarded private lab is reused.
from hellop_source_checks import (
    test_HELLOP_source_validation_persistence_and_authority_boundary,
    test_HELLOP_source_conditions_not_silently_claimed_supported,
    test_HELLOP_actual_Jaspr_source_form_revision_and_BDJ_handoff,
)
# Phase 4: production M2-backed bindings, same private lab and real HTTP surface.
from production_binding_checks import (
    test_PG40_production_confirmed_M2_creates_context_without_fixture_bindings,
    test_PG41_production_applicable_BDJ_findings_are_bound,
    test_PG42_production_confirmed_uncertainty_is_bound_from_its_own_record,
    test_PG43_business_description_template_is_deterministic_and_needs_no_provider,
    test_PG44_non_geographic_context_succeeds_without_geo_authority,
    test_PG45_production_authorization_refuses_cross_owner_and_wrong_role,
    test_PG46_production_stale_revision_is_refused,
    test_PG47_production_missing_confirmed_description_holds,
    test_PG48_production_repeated_builds_are_idempotent,
    test_PG49_restricted_principal_owner_reads_own_rows,
    test_PG50_restricted_principal_other_owner_sees_zero_rows,
    test_PG51_role_without_grants_is_refused,
    test_PG52_privileged_effective_principal_is_refused,
    test_PG53_absent_validity_basis_fails_closed,
    test_PG54_freshness_refusals_still_fire,
    test_PG55_confirmation_not_current_is_still_refused,
)
# Connected chain: confirmed M2 -> deterministic BDJ -> BCB -> QJ interface.
from connected_chain_checks import (
    test_CC1_confirmed_M2_is_owner_readable_under_restricted_principal,
    test_CC2_deterministic_BDJ_evaluates_confirmed_data_with_real_ruleset,
    test_CC3_BCB_builds_contract_1_1_context_without_geo_and_with_findings,
    test_CC4_qj_checked_context_accepts_real_BCB_context_interface_only,
    test_CC5_qj_refuses_when_confirmed_uncertainty_is_absent,
    test_CC6_cross_owner_cannot_reach_assessment_context_or_qj_input,
)
