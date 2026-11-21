"""Test CP12 writer roles and unrelated-lock recovery on private PostgreSQL."""
import json, subprocess, sys, time
from pathlib import Path
from uuid import uuid4
import psycopg2
from sqlalchemy import create_engine,text
from sqlalchemy.engine import URL

ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'artifacts/cp12_20261118'
sys.path.insert(0,str(ROOT/'backend/src'))
from sitewise.services.assessment_discard_service import AssessmentDiscardService
from sitewise.core.exceptions import AssessmentError
lab=json.loads((ROOT/'artifacts/cp11_20261118/private_cluster.json').read_text());db=json.loads((OUT/'postgres_results.json').read_text())['databases']; fixture=json.loads((OUT/'two_user_creation_results.json').read_text())
assert lab['port']==55447 and lab['host']=='127.0.0.1' and all(x.startswith('cp12_') for x in db)
def url(name,role='postgres'):
    return URL.create('postgresql+psycopg2',username=role,password=lab['password'] if role=='postgres' else lab['runtime_password'],host='127.0.0.1',port=55447,database=name)
ctl=Path('C:/Program Files/PostgreSQL/16/bin/pg_ctl.exe');data=Path(lab['cluster'])/'data';results={}
with (OUT/'lock_role_start.log').open('w') as f:subprocess.run([str(ctl),'-D',str(data),'-l',str(Path(lab['cluster'])/'postgres.log'),'-o','-h 127.0.0.1 -p 55447 -c shared_buffers=16MB -c max_connections=16','-w','start'],stdout=f,stderr=f,check=True)
try:
    market=create_engine(url(db[0]),hide_parameters=True); dss=create_engine(url(db[1]),hide_parameters=True); runtime=create_engine(url(db[1],'p1_m2_runtime'),hide_parameters=True)
    # Use a CQ/EE fixture created in an earlier isolated test, without changing
    # it: the extra snapshot is inserted and then rolled back.
    with dss.connect() as c:
        row=c.execute(text("SELECT owner_user_id,assessment_id,campaign_id,release_id,slot_id,question_version FROM ee01_measurement_snapshots WHERE scope='ISOLATED_TEST' LIMIT 1")).mappings().one()
    c=dss.connect();tx=c.begin()
    try:
        c.execute(text('SET LOCAL ROLE p1_ee01_runtime'))
        c.execute(text("SELECT set_config('project1.actor_id',:actor,true)"),{'actor':str(row['owner_user_id'])})
        start=time.perf_counter()
        inserted=c.execute(text("""INSERT INTO public.ee01_measurement_snapshots(id,owner_user_id,assessment_id,campaign_id,release_id,slot_id,question_version,cutoff,fingerprint,rules_hash,source_hash,scope,status,q,s,a,v,metadata_json,counts_json) VALUES(:id,:owner,:assessment,:campaign,:release,:slot,:version,now(),:fingerprint,:hash,:hash,'ISOLATED_TEST','WITHHELD_NOT_AUTHORIZED',0,0,0,0,'{}','{}') RETURNING id"""),{'id':uuid4(),'owner':row['owner_user_id'],'assessment':row['assessment_id'],'campaign':row['campaign_id'],'release':row['release_id'],'slot':row['slot_id'],'version':row['question_version'],'fingerprint':uuid4().hex*2,'hash':'e'*64}).scalar_one()
        results['ee01_runtime_write']={'status':'PASS','role':'p1_ee01_runtime','elapsed_ms':round((time.perf_counter()-start)*1000,3),'rolled_back':True}
    finally:tx.rollback();c.close()
    owner=fixture['owners'][1]; mid=fixture['m2_ids'][1]
    c=dss.connect();tx=c.begin()
    try:
        c.execute(text('SET LOCAL ROLE p1ai_runtime'))
        c.execute(text("SELECT set_config('project1.actor_id',:actor,true)"),{'actor':owner})
        start=time.perf_counter()
        c.execute(text("INSERT INTO project1_ai.runs(id,owner_user_id,assessment_id,assessment_revision,source_fingerprint,policy_fingerprint,work_identity) VALUES(:id,:owner,:assessment,1,:hash,:hash,:work)"),{'id':uuid4(),'owner':owner,'assessment':mid,'hash':'f'*64,'work':uuid4().hex*2})
        results['ai_runtime_write']={'status':'PASS','role':'p1ai_runtime','elapsed_ms':round((time.perf_counter()-start)*1000,3),'rolled_back':True}
    finally:tx.rollback();c.close()
    # This unrelated table lock represents an existing writer. CP12 must time
    # out, retain intent, and finish the same target after the lock is released.
    aid=uuid4()
    with market.begin() as c:
        c.execute(text("INSERT INTO assessment(assessment_id,user_id,property_id,status,created_at,updated_at) VALUES(:id,:owner,:prop,'in_progress',now(),now())"),{'id':aid,'owner':owner,'prop':'CP12-LOCK-'+uuid4().hex})
    for e in (market,dss):
        with e.begin() as c:c.execute(text("INSERT INTO cp12.target_reviews VALUES(:id,:owner,'SYNTHETIC-RETENTION','SYNTHETIC-EXTERNAL')"),{'id':aid,'owner':owner})
    held=dss.connect();held_tx=held.begin();held.execute(text('LOCK TABLE public.ee01_measurement_snapshots IN ROW EXCLUSIVE MODE'))
    service=AssessmentDiscardService(market,runtime);start=time.perf_counter()
    try:
        try:service.discard(aid,__import__('uuid').UUID(owner))
        except AssessmentError as exc:
            assert exc.code=='DISCARD_RETRY_REQUIRED' and exc.status_code==503
        else:raise AssertionError('Expected lock timeout')
        waited=time.perf_counter()-start
        with market.connect() as c:
            pending=c.execute(text('SELECT phase FROM cp12.operations WHERE assessment_id=:id'),{'id':aid}).scalar_one()
            still=c.execute(text('SELECT count(*) FROM assessment WHERE assessment_id=:id'),{'id':aid}).scalar_one()
        assert pending=='PREPARED' and still==1
    finally:held_tx.rollback();held.close()
    start_retry=time.perf_counter();service.discard(aid,__import__('uuid').UUID(owner));retry=time.perf_counter()-start_retry
    with market.connect() as c:assert c.execute(text('SELECT count(*) FROM assessment WHERE assessment_id=:id'),{'id':aid}).scalar_one()==0
    results['unrelated_writer_lock_timeout_and_retry']={'status':'PASS','timeout_seconds':round(waited,3),'intent_before_retry':pending,'retry_seconds':round(retry,3)}
    # Trivial M2 writes measured with active barriers. No adopted production
    # latency target is inferred from these small isolated samples.
    c=dss.connect();tx=c.begin()
    try:
        start=time.perf_counter()
        for _ in range(50):c.execute(text('UPDATE m2_assessments SET revision=revision WHERE id=:id'),{'id':mid})
        duration=time.perf_counter()-start
        results['m2_write_microbenchmark']={'samples':50,'total_ms':round(duration*1000,3),'mean_ms':round(duration*1000/50,3),'scope':'synthetic_private_cluster_no_production_threshold','rolled_back':True}
    finally:tx.rollback();c.close()
    for e in (market,dss,runtime):e.dispose()
    (OUT/'lock_role_results.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results,indent=2))
finally:
    with (OUT/'lock_role_stop.log').open('w') as f:subprocess.run([str(ctl),'-D',str(data),'-m','fast','-w','stop'],stdout=f,stderr=f,check=True)
