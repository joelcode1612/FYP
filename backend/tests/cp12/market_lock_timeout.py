"""Focused private-DB test: FLA lock timeout and safe retry after release."""
import json, subprocess, sys, time
from pathlib import Path
from uuid import UUID, uuid4
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL

ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'artifacts/cp12_20261118'
sys.path.insert(0,str(ROOT/'backend/src'))
from sitewise.services.assessment_discard_service import AssessmentDiscardService
from sitewise.core.exceptions import AssessmentError
lab=json.loads((ROOT/'artifacts/cp11_20261118/private_cluster.json').read_text());db=json.loads((OUT/'postgres_results.json').read_text())['databases'];fixture=json.loads((OUT/'two_user_creation_results.json').read_text())
assert lab['host']=='127.0.0.1' and lab['port']==55447 and all(x.startswith('cp12_') for x in db)
def url(name,role='postgres'):
    return URL.create('postgresql+psycopg2',username=role,password=lab['password'] if role=='postgres' else lab['runtime_password'],host='127.0.0.1',port=55447,database=name)
ctl=Path('C:/Program Files/PostgreSQL/16/bin/pg_ctl.exe');data=Path(lab['cluster'])/'data'
with (OUT/'market_lock_start.log').open('w') as f:subprocess.run([str(ctl),'-D',str(data),'-l',str(Path(lab['cluster'])/'postgres.log'),'-o','-h 127.0.0.1 -p 55447 -c shared_buffers=16MB -c max_connections=16','-w','start'],stdout=f,stderr=f,check=True)
try:
    market=create_engine(url(db[0]),hide_parameters=True);dss=create_engine(url(db[1]),hide_parameters=True);runtime=create_engine(url(db[1],'p1_m2_runtime'),hide_parameters=True)
    owner=UUID(fixture['owners'][1]);aid=uuid4()
    with market.begin() as c:c.execute(text("INSERT INTO assessment(assessment_id,user_id,property_id,status,created_at,updated_at) VALUES(:id,:owner,:prop,'in_progress',now(),now())"),{'id':aid,'owner':owner,'prop':'CP12-FLA-LOCK-'+uuid4().hex})
    for e in (market,dss):
        with e.begin() as c:c.execute(text("INSERT INTO cp12.target_reviews VALUES(:id,:owner,'SYNTHETIC-RETENTION','SYNTHETIC-EXTERNAL')"),{'id':aid,'owner':owner})
    held=market.connect();tx=held.begin();held.execute(text('SELECT assessment_id FROM assessment WHERE assessment_id=:id FOR UPDATE'),{'id':aid})
    service=AssessmentDiscardService(market,runtime);start=time.perf_counter()
    try:
        try:service.discard(aid,owner)
        except AssessmentError as exc:
            assert exc.code=='DISCARD_RETRY_REQUIRED' and exc.status_code==503
        else:raise AssertionError('Expected FLA lock timeout')
        elapsed=time.perf_counter()-start
        with market.connect() as c:
            assert c.execute(text('SELECT count(*) FROM assessment WHERE assessment_id=:id'),{'id':aid}).scalar_one()==1
            assert c.execute(text('SELECT count(*) FROM cp12.operations WHERE assessment_id=:id'),{'id':aid}).scalar_one()==0
    finally:tx.rollback();held.close()
    start=time.perf_counter();service.discard(aid,owner);retry=time.perf_counter()-start
    with market.connect() as c:assert c.execute(text('SELECT count(*) FROM assessment WHERE assessment_id=:id'),{'id':aid}).scalar_one()==0
    result={'status':'PASS','scope':'PRIVATE_SYNTHETIC_ONLY','timeout_seconds':round(elapsed,3),'marketplace_row_after_timeout':'PRESENT','journal_after_timeout':'ABSENT','retry_seconds':round(retry,3),'row_after_retry':'ABSENT','migration_sql_modified':False}
    (OUT/'market_lock_timeout_results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
    for e in (market,dss,runtime):e.dispose()
finally:
    with (OUT/'market_lock_stop.log').open('w') as f:subprocess.run([str(ctl),'-D',str(data),'-m','fast','-w','stop'],stdout=f,stderr=f,check=True)
