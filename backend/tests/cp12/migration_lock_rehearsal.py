"""New private schema-only clones: migration timeout, rollback and clean retry."""
import json, os, subprocess, time
from pathlib import Path
from uuid import uuid4
import psycopg2
from psycopg2 import sql
ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'artifacts/cp12_20261118'
lab=json.loads((ROOT/'artifacts/cp11_20261118/private_cluster.json').read_text())
assert lab['host']=='127.0.0.1' and lab['port']==55447
bindir=Path('C:/Program Files/PostgreSQL/16/bin');ctl=bindir/'pg_ctl.exe';data=Path(lab['cluster'])/'data';results={}
with (OUT/'migration_lock_start.log').open('w') as f:subprocess.run([str(ctl),'-D',str(data),'-l',str(Path(lab['cluster'])/'postgres.log'),'-o','-h 127.0.0.1 -p 55447 -c shared_buffers=16MB -c max_connections=16','-w','start'],stdout=f,stderr=f,check=True)
try:
    for kind in ('marketplace','dss'):
        db='cp12_migration_lock_'+kind+'_'+uuid4().hex[:8]
        admin=psycopg2.connect(host='127.0.0.1',port=55447,user='postgres',password=lab['password'],dbname='postgres');admin.autocommit=True
        with admin.cursor() as c:c.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(db)))
        admin.close()
        env={**os.environ,'PGHOST':'127.0.0.1','PGPORT':'55447','PGUSER':'postgres','PGPASSWORD':lab['password'],'PGDATABASE':db};env.pop('PGOPTIONS',None)
        schema=OUT/'Final_Location_Analysis_schema_current.sql' if kind=='marketplace' else OUT/'Dss_schema_current.sql'
        def run(path,label,timeout=False):
            en={**env};
            if timeout:en['PGOPTIONS']='-c lock_timeout=1000'
            with (OUT/(kind+'_migration_'+label+'.log')).open('w') as f:
                return subprocess.run([str(bindir/'psql.exe'),'-X','-v','ON_ERROR_STOP=1','-c',f"SET project1.cp12_migration_target='{db}'; SET project1.cp12_migration_receipt='SYNTHETIC-LOCK-ONLY';",'-f',str(path)],env=en,stdout=f,stderr=f)
        assert run(schema,'schema').returncode==0
        lock=psycopg2.connect(host='127.0.0.1',port=55447,user='postgres',password=lab['password'],dbname=db)
        with lock.cursor() as c:c.execute('LOCK TABLE public.assessment IN ROW EXCLUSIVE MODE' if kind=='marketplace' else 'LOCK TABLE public.m2_assessments IN ROW EXCLUSIVE MODE')
        migration=ROOT/'backend/migrations/cp12'/(kind+'_up.sql');start=time.perf_counter()
        blocked=run(migration,'blocked',True);blocked_elapsed=time.perf_counter()-start
        assert blocked.returncode!=0 and 'lock timeout' in (OUT/(kind+'_migration_blocked.log')).read_text().lower()
        check=psycopg2.connect(host='127.0.0.1',port=55447,user='postgres',password=lab['password'],dbname=db)
        with check.cursor() as c:c.execute("SELECT to_regnamespace('cp12') IS NULL");assert c.fetchone()[0]
        check.close();lock.rollback();lock.close()
        start=time.perf_counter();retry=run(migration,'retry');retry_elapsed=time.perf_counter()-start;assert retry.returncode==0
        check=psycopg2.connect(host='127.0.0.1',port=55447,user='postgres',password=lab['password'],dbname=db)
        with check.cursor() as c:c.execute("SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgname='cp12_barrier'");count=c.fetchone()[0];assert count>0
        check.close();assert run(ROOT/'backend/migrations/cp12'/(kind+'_down.sql'),'rollback').returncode==0
        results[kind]={'status':'PASS','private_db':db,'conflicting_writer_timeout_seconds':round(blocked_elapsed,3),'failed_attempt_left_cp12_schema':False,'retry_seconds':round(retry_elapsed,3),'installed_trigger_count':count,'empty_journal_down':'PASS'}
        (OUT/'migration_lock_results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(results,indent=2))
finally:
    with (OUT/'migration_lock_stop.log').open('w') as f:subprocess.run([str(ctl),'-D',str(data),'-m','fast','-w','stop'],stdout=f,stderr=f,check=True)
