"""Disposable PostgreSQL + real JWT verification + FastAPI; NO fielding authority."""
from copy import deepcopy
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import json,os,socket,threading,time,subprocess
from pathlib import Path
from uuid import UUID,uuid4
import httpx,jwt,pytest,uvicorn
from cryptography.hazmat.primitives.asymmetric import ec
from sqlalchemy import create_engine,text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import DBAPIError

if not os.environ.get('CQ_PRIVATE_CLUSTER'):
    pytest.skip('Use run_isolated.py; existing databases prohibited.',allow_module_level=True)

from sitewise.domain.customer_questionnaire import digest
from sitewise.domain.cq_runtime import CqRefused
from sitewise.services.ports.cq_store_port import CqGrant
from sitewise.services.customer_questionnaire_candidate import load_sources,SOURCE_SHA
from sitewise.db.models import cq_runtime_schema as tables


class TestOnlyAuthority:
    __test__=False
    def __init__(self,database='project1_cq_runtime_test',cluster_environment='CQ_PRIVATE_CLUSTER'):
        self.database,self.cluster_environment=database,cluster_environment
    def authorize(self,unit,release,actor_id,operation):
        c=unit.session
        assert c.execute(text('SELECT current_database()')).scalar_one()==self.database
        assert Path(c.execute(text('SHOW data_directory')).scalar_one()).resolve()==(
            Path(os.environ[self.cluster_environment])/'data').resolve()
        enabled=c.execute(text('SELECT enabled FROM test_cq_authority WHERE release_id=:id FOR SHARE'),
            {'id':release['id']}).scalar_one_or_none()
        if not enabled: raise CqRefused('PRODUCTION_FIELDING_HOLD',503)
        return CqGrant('ISOLATED_TEST','PRIVATE-CLUSTER-TEST-GRANT',False)


def fixture_manifest(mode='C1',q02='SHOW_ALL',optional=True):
    contract,policy,_=load_sources()
    language=json.loads((Path(__file__).parent/'fixtures/language_candidate.json').read_text(encoding='utf-8'))
    # The candidate review document is never an adopted authority.
    lang_items=language['questions']
    if isinstance(lang_items,dict): lang_items=list(lang_items.values())
    translated={q.get('id',q.get('question_id')):q for q in lang_items}
    dependencies={'Q03':['concept'],'Q05':['concept'],'Q06':['concept','menu'],
        'Q07':['offer'],'Q09':['concept','occasion'],'Q10':['concept','features']}
    result={'contract_version':'cq-manifest/1','lane':'BASELINE','mode':mode,
        'version':'SYNTHETIC-'+str(uuid4()),'policy_version':policy['version'],
        'policy_hash':digest(policy),'bank_version':'SYNTHETIC-BANK-'+str(uuid4()),'source_hash':SOURCE_SHA,
        'title':'Isolated questionnaire test','locales':['EN','BM'],
        'consent_version':'SYNTHETIC-CONSENT-1',
        'consent_text':{'EN':'Synthetic isolated test. No customer fielding.','BM':'Ujian sintetik sahaja.'},
        'q02_policy':q02,'optional_context':optional,
        'authorized_question_ids':['Q01','Q02','Q04'] if mode=='C0' else [q['id'] for q in contract['items']],
        'stimuli':{},'stimulus_order':[],'questions':[]}
    if mode=='C1':
        result['stimulus_order']=['concept','menu','offer','occasion','features']
        result['stimuli']={k:{'version':'SYNTHETIC-'+k+'-1','text':{'EN':'SYNTHETIC TEST '+k,'BM':'UJIAN '+k}}
            for k in ('concept','menu','offer','occasion','features')}
    for item in contract['items']:
        q=item['id'];l=translated[q]
        result['questions'].append({'id':q,'version':'SYNTHETIC-LANGUAGE-CANDIDATE-01:'+q,
            'type':item['type'],'codes':item['codes'],'validation':deepcopy(item),
            'wording':{'EN':l['source_en_stem'],'BM':l['draft_bm_stem']},
            'labels':{code:{o['source_code']:o['draft_'+code.lower()+'_label'] for o in l['options']} for code in ('EN','BM')},
            'required_for_presentation':True,'required_for_answer':q=='Q01',
            'dependencies':[] if q=='Q01' else ['Q01']+(['Q04'] if q=='Q08' else []),
            'stimulus_dependencies':dependencies.get(q,[]),
            'feature_ids':['SYN-F1','SYN-F2'] if q=='Q10' and mode=='C1' else []})
    return result,deepcopy(policy)


@pytest.fixture(scope='module')
def lab():
    url=make_url(os.environ['DATABASE_URL'])
    assert (url.host,url.port,url.database)==('127.0.0.1',55443,'project1_cq_runtime_test')
    db=create_engine(url,hide_parameters=True)
    with db.connect() as c:
        assert Path(c.execute(text('SHOW data_directory')).scalar_one()).resolve()==(Path(os.environ['CQ_PRIVATE_CLUSTER'])/'data').resolve()
    key=ec.generate_private_key(ec.SECP256R1());jwk=jwt.algorithms.ECAlgorithm.to_jwk(key.public_key(),as_dict=True)
    jwk.update(kid='private-cq',use='sig',alg='ES256')
    class Keys(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers()
            self.wfile.write(json.dumps({'keys':[jwk]}).encode())
        def do_POST(self):
            # Native tests are uninstalled by Flutter at completion. Preserve
            # captures before teardown through this private test-only server.
            try:
                jwt.decode(self.headers.get('Authorization','').removeprefix('Bearer '),key.public_key(),
                           algorithms=['ES256'],audience='authenticated',issuer='http://cq.test/auth/v1')
                name=self.path.removeprefix('/capture/')
                if name not in {'cq_paused','cq_resumed','cq_receipt','cq_before_consent'}: raise ValueError()
                size=int(self.headers['Content-Length'])
                if not 0<size<5000000: raise ValueError()
                data=self.rfile.read(size)
                if not data.startswith(b'\x89PNG'): raise ValueError()
                (Path(os.environ['CQ_EVIDENCE'])/(name+'.png')).write_bytes(data)
                self.send_response(204);self.end_headers()
            except (ValueError,jwt.PyJWTError):
                self.send_response(403);self.end_headers()
        def log_message(self,*args): pass
    keys=ThreadingHTTPServer(('127.0.0.1',0),Keys);kt=threading.Thread(target=keys.serve_forever,daemon=True);kt.start()
    os.environ.update(SUPABASE_URL='http://cq.test',SUPABASE_JWKS_URL=f'http://127.0.0.1:{keys.server_port}/keys')
    from sitewise.main import app
    from sitewise.api.v1 import customer_questionnaire as api
    from sitewise.db.models.user import User
    from sitewise.db.models.m2_schema import instruments
    owner,respondent,other,suspended=[uuid4() for _ in range(4)];iid=uuid4()
    with db.begin() as c:
        for uid,role,status in [(owner,'entrepreneur','active'),(respondent,'customer','active'),
                (other,'entrepreneur','active'),(suspended,'customer','suspended')]:
            c.execute(User.__table__.insert().values(user_id=uid,email=f'{uid}@test.invalid',role=role,account_status=status,email_verified=True))
        c.execute(instruments.insert().values(id=iid,code='SYNTHETIC-CQ',version_tag='TEST-ONLY',approval_state='DRAFT',schema_digest='0'*64))
        c.execute(text('CREATE TABLE test_cq_authority(release_id uuid PRIMARY KEY,enabled boolean NOT NULL)'))
    app.dependency_overrides[api.get_cq_authority]=lambda:TestOnlyAuthority()
    bound=socket.socket();bound.bind(('127.0.0.1',0));bound.listen(128)
    base=f'http://127.0.0.1:{bound.getsockname()[1]}'
    server=uvicorn.Server(uvicorn.Config(app,lifespan='off',log_level='error',access_log=False))
    thread=threading.Thread(target=server.run,kwargs={'sockets':[bound]},daemon=True);thread.start()
    deadline=time.monotonic()+15
    while not server.started and thread.is_alive() and time.monotonic()<deadline: time.sleep(.02)
    assert server.started
    client=httpx.Client(base_url=base+'/api/v1/cq',timeout=20)
    state={'db':db,'app':app,'owner':owner,'respondent':respondent,'other':other,'suspended':suspended,
        'iid':iid,'case':'setup','traces':[],'base':base,'readbacks':[],
        'capture_base':f'http://127.0.0.1:{keys.server_port}'}
    def token(uid):
        now=int(time.time())
        return jwt.encode({'sub':str(uid),'email':f'{uid}@test.invalid','email_verified':True,
            'iss':'http://cq.test/auth/v1','aud':'authenticated','iat':now,'exp':now+1800},key,algorithm='ES256',headers={'kid':'private-cq'})
    def request(method,path,expected=200,uid=respondent,**kwargs):
        response=client.request(method,path,headers={} if uid is None else {'Authorization':'Bearer '+token(uid)},**kwargs)
        accepted=expected if isinstance(expected,tuple) else (expected,)
        data=response.json();readback={'kind':'NO_CQ_WRITE','result':'NOT_APPLICABLE'};used=[]
        if response.status_code==200:
            with db.connect() as c:
                sid=data.get('session_id')
                if sid:
                    root=dict(c.execute(text('SELECT * FROM cq_sessions WHERE id=:id'),{'id':sid}).mappings().one())
                    used=['cq_sessions'];assert root['revision']>=data.get('revision',0)
                    if data.get('receipt'):
                        assert c.execute(text('SELECT payload_json FROM cq_submission_receipts WHERE session_id=:id'),{'id':sid}).scalar_one()==data['receipt']
                        used.append('cq_submission_receipts')
                    counts={t:c.execute(text(f'SELECT count(*) FROM {t} WHERE session_id=:id'),{'id':sid}).scalar_one() for t in
                        ('cq_consent_events','cq_stimulus_deliveries','cq_routing_decisions','cq_presentations','cq_answer_revisions','cq_effective_answers','cq_submission_receipts')}
                    used+=list(counts)
                    readback={'kind':'INDEPENDENT_SQL_CONNECTION','session_id':sid,'revision':root['revision'],'status':root['state'],
                        'counts':counts,'result':'PASS'}
                elif data.get('contract_version')=='cq-release/1':
                    assert c.execute(text('SELECT manifest_json FROM cq_manifest_releases WHERE id=:id'),{'id':data['release_id']}).scalar_one()==data['manifest']
                    used=['cq_manifest_releases','cq_bank_versions','cq_question_assignments'];readback={'kind':'INDEPENDENT_MANIFEST_READBACK','result':'PASS'}
                elif 'assessment_id' in data and not data.get('contract_version'):
                    assert str(c.execute(text('SELECT assessment_id FROM cq_campaigns WHERE id=:id'),{'id':data['id']}).scalar_one())==data['assessment_id']
                    used=['m2_assessments','cq_campaigns'];readback={'kind':'INDEPENDENT_CAMPAIGN_READBACK','result':'PASS'}
                elif 'respondent_id' in data:
                    assert c.execute(text('SELECT count(*) FROM cq_participants WHERE campaign_id=:id AND respondent_user_id=:uid'),
                        {'id':data['campaign_id'],'uid':data['respondent_id']}).scalar_one()==1
                    used=['cq_campaigns','cq_participants'];readback={'kind':'INDEPENDENT_PARTICIPANT_READBACK','result':'PASS'}
        state['traces'].append({'test_id':state['case'],'method':method,'path':'/api/v1/cq'+path,
            'route_registered':True,'feature_flag':'cq_runtime_enabled','authentication':'none' if uid is None else 'verified signed private JWT + active DB profile',
            'authorization':'private-cluster-only test authority; respondent ownership/consent; no production fielding',
            'expected_http':expected,'actual_http':response.status_code,'input':kwargs,'response_contract':response.json().get('contract_version'),
            'database_tables':used,'independent_readback':readback,
            'output':data,'result':'PASS' if response.status_code in accepted else 'FAIL'})
        assert response.status_code in accepted,response.text
        return response.json()
    state.update(request=request,token=token)
    try: yield state
    finally:
        out=Path(os.environ['CQ_EVIDENCE'])
        with db.connect() as c:
            snapshots={t.name:[dict(r) for r in c.execute(t.select()).mappings()] for t in tables.metadata.tables.values()}
            registered=[{'path':path,'methods':list(operations)} for path,operations in app.openapi()['paths'].items() if path.startswith('/api/v1/cq')]
            physical=[dict(r) for r in c.execute(text("SELECT cl.relname,con.conname,pg_get_constraintdef(con.oid) AS definition FROM pg_constraint con JOIN pg_class cl ON cl.oid=con.conrelid WHERE cl.relname LIKE 'cq_%' ORDER BY 1,2")).mappings()]
        for filename,data in [('api_execution.json',state['traces']),('independent_readback.json',snapshots),
                ('registered_routes.json',registered),('physical_constraints.json',physical),('asserted_readbacks.json',state['readbacks'])]:
            (out/filename).write_text(json.dumps(data,indent=2,ensure_ascii=False,default=str),encoding='utf-8')
        client.close();server.should_exit=True;thread.join(timeout=15);bound.close();keys.shutdown();keys.server_close();kt.join(5)
        app.dependency_overrides.clear();db.dispose()


@pytest.fixture(autouse=True)
def case_name(request,lab): lab['case']=request.node.name


def english_only_manifest(manifest,policy):
    """New private test release; do not edit an existing version or source text."""
    manifest['locales']=['EN']
    manifest['consent_text']={'EN':manifest['consent_text']['EN']}
    for question in manifest['questions']:
        question['wording']={'EN':question['wording']['EN']}
        question['labels']={'EN':question['labels']['EN']}
    for stimulus in manifest['stimuli'].values():
        stimulus['text']={'EN':stimulus['text']['EN']}


def release(lab,mode='C1',q02='SHOW_ALL',optional=True,mutate=None,release_id=None):
    m,p=fixture_manifest(mode,q02,optional)
    if mutate: mutate(m,p)
    rid=release_id or uuid4()
    with lab['db'].begin() as c:
        c.execute(tables.banks.insert().values(version=m['bank_version'],content_hash=digest(m['questions']),questions_json=m['questions']))
        c.execute(tables.releases.insert().values(id=rid,manifest_hash=digest(m),policy_hash=digest(p),
            manifest_json=m,policy_json=p,source_class='SYNTHETIC_FIXTURE'))
        for q in m['questions']:
            slots=[q['id']+':'+f for f in q['feature_ids']] if q['feature_ids'] else [q['id']]
            for slot in slots:
                c.execute(tables.assignments.insert().values(release_id=rid,slot_id=slot,question_id=q['id'],
                    question_version=q['version'],bank_version=m['bank_version'],content_hash=digest(q)))
        c.execute(text('INSERT INTO test_cq_authority VALUES(:id,true)'),{'id':rid})
    return str(rid),m


def session(lab,mode='C1',q02='SHOW_ALL',optional=True,consent=True,locale='EN'):
    from sitewise.db.models.m2_schema import assessments
    rid,m=release(lab,mode,q02,optional);aid=uuid4()
    with lab['db'].begin() as c: c.execute(assessments.insert().values(id=aid,owner_user_id=lab['owner'],instrument_id=lab['iid'],revision=0))
    campaign=lab['request']('POST',f'/assessments/{aid}/campaign',uid=lab['owner'],json={'release_id':rid})
    lab['request']('POST',f"/campaigns/{campaign['id']}/participants",uid=lab['owner'],json={'respondent_id':str(lab['respondent'])})
    s=lab['request']('POST','/sessions',json={'campaign_id':campaign['id'],'manifest_hash':digest(m),'locale':locale})
    if consent:
        s=post(lab,s,'consent',{'request_id':str(uuid4()),'consented':True,'consent_version':m['consent_version']})
    return s


def version(s): return {'expected_revision':s['revision'],'manifest_hash':s['manifest_hash']}
def post(lab,s,action,data=None,expected=200,**kwargs):
    return lab['request']('POST',f"/sessions/{s['session_id']}/{action}",expected,json={**version(s),**(data or {})},**kwargs)
def row(s,slot): return next(r for r in s['routing'] if r['slot_id']==slot)
def respond(lab,s,value,edit=None,expected=200):
    display=post(lab,s,'presentations',{'edit_slot_id':edit})
    return post(lab,display,'answers',{'request_id':str(uuid4()),'display_id':display['presentation']['display_id'],
        'slot_id':display['presentation']['slot_id'],'value':value},expected)
def deliver(lab,s):
    while s['next_stimulus_kind']: s=post(lab,s,'stimuli',{'kind':s['next_stimulus_kind']})
    return s
def complete(lab,s):
    for _ in range(40):
        s=deliver(lab,s)
        if s['can_submit']: return s
        q=next(q for q in s['manifest']['questions'] if q['id']==s['next_slot_id'].split(':')[0])
        code='LIVE' if q['id']=='Q01' else 'ONE' if q['id']=='Q04' else q['validation']['substantive_codes'][0]
        value=[code] if q['type'].startswith('multi_select') else code
        s=respond(lab,s,value)
    raise AssertionError('No completion')


def test_CQ01_baseline_persist_resume_submit_and_once_only(lab):
    s=session(lab,'C0');assert s['next_slot_id']=='Q01'
    rid=s['release_id'];got=lab['request']('GET','/manifests/'+rid);assert got['manifest']==s['manifest']
    assert lab['request']('GET','/invitations')['state']=='ready'
    s=complete(lab,s);assert [r['slot_id'] for r in s['routing'] if r['verdict']=='SHOWN']==['Q01','Q02','Q04']
    resumed=lab['request']('GET','/sessions/'+s['session_id']);assert resumed==s
    original=dict(s);request={'request_id':str(uuid4())};s=post(lab,s,'submit',request)
    assert s['status']=='SUBMITTED' and s['receipt']['execution_scope']=='ISOLATED_TEST'
    assert post(lab,original,'submit',request)['receipt']==s['receipt']
    assert post(lab,s,'submit',{'request_id':str(uuid4())})['receipt']==s['receipt']
    with lab['db'].connect() as c:
        sid=s['session_id']
        assert c.execute(text('SELECT count(*) FROM cq_submission_receipts WHERE session_id=:sid'),{'sid':sid}).scalar_one()==1
        effective=c.execute(text('SELECT count(DISTINCT answer_event_id) FROM cq_effective_answers WHERE session_id=:sid'),{'sid':sid}).scalar_one()
        assert effective==3
        stored=c.execute(text('SELECT payload_json FROM cq_submission_receipts WHERE session_id=:sid'),{'sid':sid}).scalar_one()
        assert stored==s['receipt'];body=dict(stored);assert body.pop('receipt_hash')==digest(body)
    lab['readbacks'].append({'test_id':lab['case'],'session_id':sid,'receipt':stored,'distinct_effective_answers':effective,'result':'PASS'})


def test_CQ02_C1_all_questions_feature_cells_and_deliveries(lab):
    s=complete(lab,session(lab));assert all(r['verdict']=='SHOWN' for r in s['routing'])
    assert len(s['routing'])==14 and len([r for r in s['routing'] if r['question_id']=='Q10'])==2
    s=post(lab,s,'submit',{'request_id':str(uuid4())})
    with lab['db'].connect() as c:
        for table,count in [('cq_answer_revisions',14),('cq_stimulus_deliveries',5),('cq_effective_answers',14)]:
            assert c.execute(text(f'SELECT count(*) FROM {table} WHERE session_id=:sid'),{'sid':s['session_id']}).scalar_one()==count
    lab['readbacks'].append({'test_id':lab['case'],'session_id':s['session_id'],'questions':13,'cells':14,'deliveries':5,'result':'PASS'})


@pytest.mark.parametrize('screen', ['RARELY','NEVER','NOT_SURE'])
@pytest.mark.parametrize('policy',['SHOW_ALL','ELIGIBLE_ONLY','UNDECIDED'])
def test_CQ03_screenout_Q02_policy_candidate(lab,screen,policy):
    s=respond(lab,session(lab,q02=policy),[screen]);assert s['screen_disposition'] in {'AREA_OUTSIDE','AREA_UNKNOWN'}
    assert row(s,'Q02')['verdict']==('SHOWN' if policy=='SHOW_ALL' else 'NOT_SHOWN')
    assert all(r['verdict']=='NOT_SHOWN' for r in s['routing'] if r['question_id'] not in {'Q01','Q02'})
    s=complete(lab,s);post(lab,s,'submit',{'request_id':str(uuid4())})


@pytest.mark.parametrize('value,state,shown',[('ZERO','ANSWERED_SUBSTANTIVE',False),('ONE','ANSWERED_SUBSTANTIVE',True),
    ('CANNOT_REMEMBER','ANSWERED_NON_SUBSTANTIVE',False),('PREFER_NOT_TO_ANSWER','REFUSED',False),(None,'SKIPPED',False)])
def test_CQ04_Q04_Q08_applicability_and_nonanswers(lab,value,state,shown):
    s=deliver(lab,respond(lab,session(lab),['LIVE']))
    while s['next_slot_id']!='Q04':
        q=next(q for q in s['manifest']['questions'] if q['id']==s['next_slot_id']);code=q['codes'][0]
        s=respond(lab,s,code)
    s=respond(lab,s,value);assert row(s,'Q04')['state']==state
    assert row(s,'Q08')['verdict']==('SHOWN' if shown else 'NOT_SHOWN')
    assert row(s,'Q08')['facts']['Q04_ANSWER']==('SUBSTANTIVE_NONZERO' if shown else 'ZERO' if value=='ZERO' else state)


def test_CQ05_revisions_invalidate_dependents_no_resurrection(lab):
    s=complete(lab,session(lab));old=row(s,'Q08')['event_id']
    s=respond(lab,s,'ZERO',edit='Q04');assert row(s,'Q08')['state']=='NOT_SHOWN'
    s=respond(lab,s,'ONE',edit='Q04');assert row(s,'Q08')['state']=='PENDING'
    s=respond(lab,s,['STUDY']);assert row(s,'Q08')['event_id']!=old
    s=respond(lab,s,['NEVER'],edit='Q01');assert row(s,'Q04')['state']=='NOT_SHOWN'
    s=respond(lab,s,['LIVE'],edit='Q01');assert row(s,'Q04')['state']=='PENDING'
    history=lab['request']('GET',f"/sessions/{s['session_id']}/history")['answers']
    assert len([a for a in history if a['slot_id']=='Q08'])==2
    with lab['db'].connect() as c:
        assert c.execute(text("SELECT answer_event_id FROM cq_effective_answers WHERE session_id=:id AND slot_id='Q04'"),{'id':s['session_id']}).scalar_one() is None


def test_CQ06_auth_ownership_consent_and_forbidden_presentation(lab):
    s=session(lab,'C0',consent=False)
    lab['request']('GET','/availability',401,uid=None)
    lab['request']('GET','/availability',403,uid=lab['suspended'])
    lab['request']('GET','/sessions/'+s['session_id'],404,uid=lab['other'])
    post(lab,s,'presentations',expected=403)
    post(lab,s,'consent',{'request_id':str(uuid4()),'consented':True,'consent_version':'WRONG'},409)
    s=post(lab,s,'consent',{'request_id':str(uuid4()),'consented':True,'consent_version':s['manifest']['consent_version']})
    post(lab,s,'presentations',{'edit_slot_id':'Q07'},409)
    post(lab,s,'submit',{'request_id':str(uuid4())},409)
    post(lab,s,'answers',{'request_id':str(uuid4()),'display_id':str(uuid4()),'slot_id':'Q07','value':'VERY_ACCEPTABLE'},409)
    d=post(lab,s,'presentations')
    data={'request_id':str(uuid4()),'display_id':d['presentation']['display_id'],'slot_id':'Q01','value':['LIVE','NEVER']}
    post(lab,d,'answers',data,422)
    post(lab,d,'answers',{**data,'request_id':str(uuid4()),'value':['MADE_UP']},422)
    post(lab,d,'answers',{**data,'request_id':str(uuid4()),'value':None},422)
    post(lab,d,'answers',{**data,'value':['LIVE'],'manifest_hash':'0'*64},409)
    post(lab,d,'answers',{**data,'value':['LIVE'],'expected_revision':999},409)
    post(lab,d,'answers',{**data,'value':['LIVE'],'owner_id':str(lab['owner'])},422)


def test_CQ07_campaign_session_uniqueness_and_scope(lab):
    s=session(lab,'C0')
    with lab['db'].connect() as c: aid=c.execute(text('SELECT assessment_id FROM cq_campaigns WHERE id=:id'),{'id':s['campaign_id']}).scalar_one()
    path=f'/assessments/{aid}/campaign'
    assert lab['request']('POST',path,uid=lab['owner'],json={'release_id':s['release_id']})['id']==s['campaign_id']
    rid,_=release(lab)
    lab['request']('POST',path,409,uid=lab['owner'],json={'release_id':rid})
    lab['request']('POST',path,404,uid=lab['other'],json={'release_id':rid})
    lab['request']('POST',path,403,json={'release_id':rid})
    assert lab['request']('POST','/sessions',json={'campaign_id':s['campaign_id'],'manifest_hash':s['manifest_hash'],'locale':'EN'})['session_id']==s['session_id']
    lab['request']('POST','/sessions',404,uid=lab['other'],json={'campaign_id':s['campaign_id'],'manifest_hash':s['manifest_hash'],'locale':'EN'})
    lab['request']('POST','/sessions',409,json={'campaign_id':s['campaign_id'],'manifest_hash':s['manifest_hash'],'locale':'BM'})


def test_CQ08_duplicate_answers_concurrency_and_transaction_rollback(lab,monkeypatch):
    from sitewise.repositories.cq_repository import CqUnit
    s=session(lab,'C0');d=post(lab,s,'presentations')
    data={'request_id':str(uuid4()),'display_id':d['presentation']['display_id'],'slot_id':'Q01','value':['LIVE']}
    original=CqUnit.insert_answer
    def fail(self,**row): original(self,**row);self.session.execute(text('SELECT 1/0'))
    monkeypatch.setattr(CqUnit,'insert_answer',fail);post(lab,d,'answers',data,503)
    with lab['db'].connect() as c:
        assert c.execute(text('SELECT count(*) FROM cq_answer_revisions WHERE session_id=:id'),{'id':s['session_id']}).scalar_one()==0
        assert c.execute(text('SELECT revision FROM cq_sessions WHERE id=:id'),{'id':s['session_id']}).scalar_one()==s['revision']
    monkeypatch.setattr(CqUnit,'insert_answer',original)
    barrier=threading.Barrier(2)
    def send(_): barrier.wait(5);return post(lab,d,'answers',{**data,'request_id':str(uuid4())},(200,409))
    with ThreadPoolExecutor(2) as pool: outcomes=list(pool.map(send,range(2)))
    assert sum('detail' not in x for x in outcomes)==1
    current=lab['request']('GET','/sessions/'+s['session_id']);d=post(lab,current,'presentations')
    data={'request_id':str(uuid4()),'display_id':d['presentation']['display_id'],'slot_id':'Q02','value':'DAYS_1_3'}
    first=post(lab,d,'answers',data);assert post(lab,d,'answers',data)==first
    post(lab,d,'answers',{**data,'value':'NONE'},409)


def test_CQ09_revoked_authority_default_hold_and_withdrawal(lab):
    from sitewise.api.v1.customer_questionnaire import get_cq_authority
    from sitewise.core.config import settings
    s=complete(lab,session(lab,'C0'));s=post(lab,s,'submit',{'request_id':str(uuid4())})
    override=lab['app'].dependency_overrides.pop(get_cq_authority)
    try:
        got=lab['request']('GET','/sessions/'+s['session_id'],503);assert got['detail']['code']=='PRODUCTION_FIELDING_HOLD'
        assert lab['request']('GET','/availability')['production_fielding_authorized'] is False
    finally: lab['app'].dependency_overrides[get_cq_authority]=override
    with lab['db'].begin() as c: c.execute(text('UPDATE test_cq_authority SET enabled=false WHERE release_id=:id'),{'id':s['release_id']})
    lab['request']('GET','/sessions/'+s['session_id'],503)
    withdrawn=post(lab,s,'withdraw',{'request_id':str(uuid4())});assert withdrawn['status']=='WITHDRAWN'
    with lab['db'].connect() as c:
        assert c.execute(text('SELECT count(answer_event_id) FROM cq_effective_answers WHERE session_id=:id'),{'id':s['session_id']}).scalar_one()==0
        assert c.execute(text('SELECT count(*) FROM cq_submission_receipts WHERE session_id=:id'),{'id':s['session_id']}).scalar_one()==1
    settings.cq_runtime_enabled=False
    try:
        assert lab['request']('GET','/invitations')['invitations']==[]
        lab['request']('GET','/manifests/'+s['release_id'],503)
    finally: settings.cq_runtime_enabled=True


def test_CQ20_withdrawal_current_answers_and_session_identity_guard(lab):
    s=complete(lab,session(lab,'C0'));post(lab,s,'withdraw',{'request_id':str(uuid4())})
    got=lab['request']('GET','/sessions/'+s['session_id'])
    assert all(r['state']=='NOT_SHOWN' and r['value'] is None and r['event_id'] is None for r in got['routing'])
    post(lab,got,'presentations',expected=409)
    with lab['db'].connect() as c:
        for statement in ["UPDATE cq_sessions SET locale='BM',revision=revision+1 WHERE id=:id",
                "UPDATE cq_sessions SET state='ACTIVE',revision=revision+1 WHERE id=:id"]:
            with pytest.raises(DBAPIError): c.execute(text(statement),{'id':s['session_id']})
            c.rollback()


@pytest.mark.parametrize('kind',['dependency','const','codebook','entrepreneur','unknown_gate','no_q01','stimulus_order'])
def test_CQ10_invalid_release_and_upstream_hold(lab,kind):
    def corrupt(m,p):
        if kind=='dependency': m['questions'][0]['dependencies']=['Q13']
        elif kind=='const': p['gate']['token_predicates']['ALWAYS']['clauses'][0]['value']=False;m['policy_hash']=digest(p)
        elif kind=='codebook': m['questions'][0]['codes']=['MADE_UP']
        elif kind=='entrepreneur': m['lane']='ENTREPRENEUR_SPECIFIC'
        elif kind=='unknown_gate': p['item_show_gate']['Q08']='UNKNOWN';m['policy_hash']=digest(p)
        elif kind=='no_q01': m['authorized_question_ids']=[]
        elif kind=='stimulus_order': m['stimulus_order']=['unknown']
    rid,_=release(lab,mutate=corrupt)
    got=lab['request']('GET','/manifests/'+rid,(409,503));assert 'detail' in got


def test_CQ11_immutable_integrity_and_default_deny_database_role(lab):
    s=complete(lab,session(lab,'C0'));s=post(lab,s,'submit',{'request_id':str(uuid4())})
    with lab['db'].connect() as c:
        for table in ('cq_manifest_releases','cq_question_assignments','cq_campaigns','cq_participants',
                'cq_consent_events','cq_routing_decisions','cq_presentations','cq_answer_revisions','cq_submission_receipts'):
            with pytest.raises(DBAPIError): c.execute(text(f'DELETE FROM {table}'))
            c.rollback()
        record=dict(c.execute(tables.receipts.select().where(tables.receipts.c.session_id==UUID(s['session_id']))).mappings().one())
        record.update(id=uuid4(),receipt_hash='0'*64)
        with pytest.raises(DBAPIError): c.execute(tables.receipts.insert().values(**record))
        c.rollback()
    with lab['db'].begin() as c:
        c.execute(text('CREATE ROLE cq_no_policy NOLOGIN NOSUPERUSER NOBYPASSRLS'))
        c.execute(text('GRANT USAGE ON SCHEMA public TO cq_no_policy'))
        c.execute(text('GRANT SELECT ON ALL TABLES IN SCHEMA public TO cq_no_policy'))
        c.execute(text('SET LOCAL ROLE cq_no_policy'))
        assert c.execute(text('SELECT count(*) FROM cq_sessions')).scalar_one()==0


def test_CQ12_optional_context_and_no_stimuli_remain_held(lab):
    s=respond(lab,session(lab,optional=False),['LIVE'])
    for q in ('Q03','Q05','Q06','Q07','Q09','Q10:SYN-F1','Q11','Q12','Q13'): assert row(s,q)['verdict']=='NOT_SHOWN'
    s=deliver(lab,s)
    for q in ('Q03','Q05','Q06','Q07','Q09','Q10:SYN-F1'): assert row(s,q)['verdict']=='SHOWN'
    for q in ('Q11','Q12','Q13'): assert row(s,q)['verdict']=='NOT_SHOWN'


def test_CQ13_duplicate_final_submit_concurrency_stale_and_receipt_integrity(lab):
    s=complete(lab,session(lab,'C0'));barrier=threading.Barrier(2)
    def send(_): barrier.wait(5);return post(lab,s,'submit',{'request_id':str(uuid4())})
    with ThreadPoolExecutor(2) as pool: responses=list(pool.map(send,range(2)))
    assert responses[0]['receipt']==responses[1]['receipt']
    post(lab,{**s,'revision':0},'submit',{'request_id':str(uuid4())},409)
    with lab['db'].begin() as c:
        c.execute(text('ALTER TABLE cq_submission_receipts DISABLE TRIGGER cq_append_only'))
        c.execute(text("UPDATE cq_submission_receipts SET payload_json=jsonb_set(payload_json,'{decision_hash}','\"tampered\"') WHERE session_id=:id"),{'id':s['session_id']})
        c.execute(text('ALTER TABLE cq_submission_receipts ENABLE TRIGGER cq_append_only'))
    got=lab['request']('GET','/sessions/'+s['session_id'],503);assert got['detail']['code']=='CQ_RECEIPT_INTEGRITY_INVALID'


def test_CQ14_Flutter_FastAPI_widget_exchange(lab):
    if not os.environ.get('CQ_RUN_FLUTTER'): pytest.skip('Set CQ_RUN_FLUTTER=1 for actual widget/FastAPI acceptance.')
    s=session(lab,'C0',consent=False)
    c1=session(lab,'C1',consent=False,locale='BM')
    env=os.environ.copy();env.update(CQ_TEST_TOKEN=lab['token'](lab['respondent']),CQ_TEST_SESSION=s['session_id'],
        CQ_TEST_C1_SESSION=c1['session_id'],CQ_TEST_BASE=lab['base'])
    root=Path(__file__).resolve().parents[3]
    # Reuse the application's default CQ composition, not a provider override.
    # Short-lived private credentials never enter source, public assets or logs.
    defines=Path(os.environ['CQ_PRIVATE_CLUSTER'])/'flutter_test_defines.json'
    injected=os.environ.get('CQ_WIDGET_PROVIDER_INJECTION')=='1'
    # Existing widget fixture supports an explicit repository override. This
    # verifies real signed HTTP without weakening packaged auth/test-access guards.
    print('CQ_WIDGET_SCOPE='+('EXPLICIT_TEST_REPOSITORY' if injected else 'DEFAULT_PRIVATE_COMPOSITION'),flush=True)
    defines.write_text(json.dumps({'API_BASE_URL':lab['base'],'CQ_TEST_BASE':lab['base'],
        'CQ_TEST_TOKEN':env['CQ_TEST_TOKEN'],'CQ_TEST_SESSION':s['session_id'],
        'CQ_TEST_C1_SESSION':c1['session_id'],'CQ_CAPTURE_BASE':lab['capture_base'],'SITEWISE_DEV_AUTH_BYPASS':not injected,
        'SITEWISE_ISOLATED_CQ_TEST':not injected}),encoding='utf-8')
    native=os.environ.get('CQ_NATIVE_DEVICE')
    target='test/cq_runtime/cq_api_widget_test.dart'
    device_args=[]
    if native:
        adb=Path(os.environ['LOCALAPPDATA'])/'Android/Sdk/platform-tools/adb.exe'
        subprocess.run([str(adb),'-s',native,'reverse','tcp:'+lab['base'].rsplit(':',1)[1],
            'tcp:'+lab['base'].rsplit(':',1)[1]],check=True,capture_output=True)
        capture_port=lab['capture_base'].rsplit(':',1)[1]
        subprocess.run([str(adb),'-s',native,'reverse','tcp:'+capture_port,'tcp:'+capture_port],check=True,capture_output=True)
        env['SITEWISE_ISOLATED_DEVICE_TEST']='1'
        target='integration_test/part_two_customer_test.dart';device_args=['-d',native]
    try:
        outcome=subprocess.run([str(root/'.fvm/flutter_sdk/bin/flutter.bat'),'test','--no-pub',target,
            *device_args,'--dart-define-from-file='+str(defines)],
            cwd=root/'fyp_mobile_app',env=env,capture_output=True,text=True,encoding='utf-8',timeout=900)
        if native:
            for name in ('cq_paused','cq_resumed','cq_receipt','cq_before_consent'):
                shot=subprocess.run([str(adb),'-s',native,'exec-out','run-as','com.example.fyp.parttwotest',
                    'cat','files/cq_evidence/'+name+'.png'],capture_output=True)
                if shot.returncode==0 and shot.stdout.startswith(b'\x89PNG'):
                    (Path(os.environ['CQ_EVIDENCE'])/(name+'.png')).write_bytes(shot.stdout)
    finally: defines.unlink(missing_ok=True)
    (Path(os.environ['CQ_EVIDENCE'])/'flutter_api_widget.log').write_text(outcome.stdout+outcome.stderr,encoding='utf-8')
    assert outcome.returncode==0,outcome.stdout+outcome.stderr
    with lab['db'].connect() as c:
        assert c.execute(text('SELECT state FROM cq_sessions WHERE id=:id'),{'id':s['session_id']}).scalar_one()=='SUBMITTED'
        assert c.execute(text('SELECT count(*) FROM cq_answer_revisions WHERE session_id=:id'),{'id':s['session_id']}).scalar_one()==4
        assert c.execute(text('SELECT count(*) FROM cq_submission_receipts WHERE session_id=:id'),{'id':s['session_id']}).scalar_one()==1
        assert c.execute(text('SELECT count(*) FROM cq_answer_revisions WHERE session_id=:id'),{'id':c1['session_id']}).scalar_one()==14
        assert c.execute(text('SELECT state FROM cq_sessions WHERE id=:id'),{'id':c1['session_id']}).scalar_one()=='SUBMITTED'
    lab['readbacks'].append({'test_id':lab['case'],'session_id':s['session_id'],'Flutter_answer_revisions':4,'receipt_count':1,'result':'PASS'})
    lab['readbacks'].append({'test_id':lab['case'],'session_id':c1['session_id'],'Flutter_answer_revisions':14,'receipt_count':1,'locale':'BM','result':'PASS'})


def test_CQ15_registered_routes_and_auth_dependency_execution(lab):
    paths={p:ops for p,ops in lab['app'].openapi()['paths'].items() if p.startswith('/api/v1/cq')}
    assert sum(len(ops) for ops in paths.values())==19
    for path,ops in paths.items():
        for method in ops:
            concrete=path
            for param in ('release_id','assessment_id','campaign_id','session_id','snapshot_id'):
                concrete=concrete.replace('{'+param+'}',str(uuid4()))
            lab['request'](method.upper(),concrete.removeprefix('/api/v1/cq'),401,uid=None,
                **({'json':{}} if method=='post' else {}))


@pytest.mark.parametrize('missing,hidden',[('concept',['Q03','Q05','Q06','Q09','Q10:SYN-F1']),
    ('menu',['Q06']),('offer',['Q07']),('occasion',['Q09']),('features',['Q10:SYN-F1'])])
def test_CQ16_each_candidate_stimulus_negative_branch(lab,missing,hidden):
    s=respond(lab,session(lab),['LIVE'])
    # Deliver all other immutable test stimuli independently. This deliberately
    # exercises the reference predicate for each missing source, not a mock gate.
    with lab['db'].begin() as c:
        for kind,stimulus in s['manifest']['stimuli'].items():
            if kind!=missing:
                c.execute(tables.exposures.insert().values(id=uuid4(),session_id=UUID(s['session_id']),
                    revision=0,kind=kind,stimulus_hash=digest(stimulus)))
    got=lab['request']('GET','/sessions/'+s['session_id'])
    for slot in hidden: assert row(got,slot)['verdict']=='NOT_SHOWN'


def test_CQ17_global_bank_rebinding_and_assignment_tamper_are_refused(lab):
    rid,m=release(lab)
    with lab['db'].connect() as c:
        with pytest.raises(DBAPIError): c.execute(tables.banks.insert().values(
            version=m['bank_version'],content_hash='0'*64,questions_json=[]))
        c.rollback()
    with lab['db'].begin() as c:
        c.execute(text('ALTER TABLE cq_question_assignments DISABLE TRIGGER cq_append_only'))
        c.execute(text("UPDATE cq_question_assignments SET question_version='TAMPER' WHERE release_id=:id AND slot_id='Q01'"),{'id':rid})
        c.execute(text('ALTER TABLE cq_question_assignments ENABLE TRIGGER cq_append_only'))
    got=lab['request']('GET','/manifests/'+rid,503);assert got['detail']['code']=='CQ_ASSIGNMENT_VERSION_INVALID'


def test_CQ18_reconstruct_every_persisted_decision_from_event_history(lab):
    from sitewise.domain.cq_runtime import route
    s=complete(lab,session(lab));s=respond(lab,s,'ZERO',edit='Q04');s=respond(lab,s,'ONE',edit='Q04');s=complete(lab,s)
    s=post(lab,s,'submit',{'request_id':str(uuid4())})
    _,policy,reference=load_sources()
    with lab['db'].connect() as c:
        sid=UUID(s['session_id'])
        history=[dict(x) for x in c.execute(tables.answers.select().where(tables.answers.c.session_id==sid).order_by(tables.answers.c.revision)).mappings()]
        exposures=[dict(x) for x in c.execute(tables.exposures.select().where(tables.exposures.c.session_id==sid)).mappings()]
        decisions=c.execute(tables.decisions.select().where(tables.decisions.c.session_id==sid)).mappings().all()
        for d in decisions:
            latest={a['slot_id']:a for a in history if a['revision']<=d['revision']}
            delivered={e['kind']:e['stimulus_hash'] for e in exposures if e['revision']<=d['revision']}
            reconstructed,_=route(s['manifest'],policy,latest,delivered,reference)
            assert reconstructed==d['decision_json'] and digest(reconstructed)==d['decision_hash']
    lab['readbacks'].append({'test_id':lab['case'],'session_id':s['session_id'],'reconstructed_decisions':len(decisions),'result':'PASS'})


def test_CQ19_failed_final_receipt_write_rolls_back_and_withdrawal_survives_flag(lab,monkeypatch):
    from sitewise.repositories.cq_repository import CqUnit
    from sitewise.core.config import settings
    s=complete(lab,session(lab,'C0'));original=CqUnit.insert_receipt
    def fail(self,**row): original(self,**row);self.session.execute(text('SELECT 1/0'))
    monkeypatch.setattr(CqUnit,'insert_receipt',fail);post(lab,s,'submit',{'request_id':str(uuid4())},503)
    with lab['db'].connect() as c:
        assert c.execute(text('SELECT count(*) FROM cq_submission_receipts WHERE session_id=:id'),{'id':s['session_id']}).scalar_one()==0
        assert c.execute(text('SELECT state,revision FROM cq_sessions WHERE id=:id'),{'id':s['session_id']}).one()==('ACTIVE',s['revision'])
    monkeypatch.setattr(CqUnit,'insert_receipt',original)
    s=post(lab,s,'submit',{'request_id':str(uuid4())})
    settings.cq_runtime_enabled=False
    try:
        withdrawn=post(lab,s,'withdraw',{'request_id':str(uuid4())});assert withdrawn['status']=='WITHDRAWN'
    finally: settings.cq_runtime_enabled=True


def test_CQ21_english_only_release_does_not_require_BM_and_refuses_BM_start(lab):
    from sitewise.db.models.m2_schema import assessments
    rid,manifest=release(lab,mutate=english_only_manifest)
    aid=uuid4()
    with lab['db'].begin() as c:
        c.execute(assessments.insert().values(id=aid,owner_user_id=lab['owner'],instrument_id=lab['iid'],revision=0))
    campaign=lab['request']('POST',f'/assessments/{aid}/campaign',uid=lab['owner'],json={'release_id':rid})
    lab['request']('POST',f"/campaigns/{campaign['id']}/participants",uid=lab['owner'],json={'respondent_id':str(lab['respondent'])})
    delivered=lab['request']('GET','/manifests/'+rid)['manifest']
    assert delivered['locales']==['EN']
    assert all(set(q['wording'])==set(q['labels'])=={'EN'} for q in delivered['questions'])
    request={'campaign_id':campaign['id'],'manifest_hash':digest(manifest),'locale':'BM'}
    refused=lab['request']('POST','/sessions',422,json=request)
    assert refused['detail']['code']=='CQ_LOCALE_NOT_AUTHORIZED'
    with lab['db'].connect() as c:
        assert c.execute(text('SELECT count(*) FROM cq_sessions WHERE campaign_id=:id'),{'id':campaign['id']}).scalar_one()==0
    s=lab['request']('POST','/sessions',json={**request,'locale':'EN'})
    assert s['locale']=='EN' and s['manifest']['locales']==['EN']
    s=post(lab,s,'consent',{'request_id':str(uuid4()),'consented':True,'consent_version':manifest['consent_version']})
    s=complete(lab,s)
    s=post(lab,s,'submit',{'request_id':str(uuid4())})
    readback=lab['request']('GET','/sessions/'+s['session_id'])
    assert readback['receipt']==s['receipt'] and readback['status']=='SUBMITTED'
    with lab['db'].connect() as c:
        assert c.execute(text('SELECT locale,state FROM cq_sessions WHERE id=:id'),{'id':s['session_id']}).one()==('EN','SUBMITTED')
        counts={table:c.execute(text(f'SELECT count(*) FROM {table} WHERE session_id=:id'),{'id':s['session_id']}).scalar_one() for table in ('cq_answer_revisions','cq_stimulus_deliveries','cq_submission_receipts')}
        assert counts=={'cq_answer_revisions':14,'cq_stimulus_deliveries':5,'cq_submission_receipts':1}
    lab['readbacks'].append({'test_id':lab['case'],'session_id':s['session_id'],'locales':['EN'],
        'BM_start_rejected_http':422,'counts':counts,'receipt':s['receipt'],'result':'PASS','data':'ISOLATED_FIXTURE_ONLY'})


@pytest.mark.parametrize('locales',[[],['BM'],['EN','EN'],['EN','XX'],'EN'])
def test_CQ22_english_only_change_does_not_authorize_invalid_locale_manifests(lab,locales):
    from sitewise.db.models.m2_schema import assessments
    rid,_=release(lab,mutate=lambda m,p:m.update(locales=locales))
    aid=uuid4()
    with lab['db'].begin() as c:
        c.execute(assessments.insert().values(id=aid,owner_user_id=lab['owner'],instrument_id=lab['iid'],revision=0))
    refused=lab['request']('POST',f'/assessments/{aid}/campaign',409,uid=lab['owner'],json={'release_id':rid})
    assert refused['detail']['code']=='CQ_QUESTION_AUTHORITY_INVALID'


from pause_checks import (test_CQ23_pause_resume_same_session_idempotency_and_storage,
    test_CQ24_pause_write_failure_rolls_back_and_withdraw_is_available,
    test_CQ25_render_ack_not_prepared_delivery_and_invalid_audit)

from ee01_checks import (test_EE01_persisted_cutoff_reference_security_and_held_report,
    test_EE02_zero_denominator_and_snapshot_transaction_rollback,
    test_EE03_multiselect_distinct_units_and_feature_denominators)

from persistence_verification_checks import (
    test_VP01_Q01_Q13_revisions_pause_submit_to_saved_EE_context,
    test_VP02_independent_eligibility_vs_area_and_termination_evidence)
