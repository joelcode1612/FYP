"""Compare guarded and unguarded synthetic M2 writes; private PG16 only."""
import json, statistics, subprocess, time
from pathlib import Path
from uuid import uuid4
import psycopg2
ROOT=Path(__file__).resolve().parents[3]; OUT=ROOT/'artifacts/cp12_20261118'
lab=json.loads((ROOT/'artifacts/cp11_20261118/private_cluster.json').read_text());assert lab['host']=='127.0.0.1' and lab['port']==55447
active=json.loads((OUT/'postgres_results.json').read_text())['databases'][1]
baseline=json.loads((OUT/'permission_restore_results.json').read_text())['Dss']['private_db']
assert active.startswith('cp12_') and baseline.startswith('cp12_acl_')
ctl=Path('C:/Program Files/PostgreSQL/16/bin/pg_ctl.exe');data=Path(lab['cluster'])/'data';results={}
with (OUT/'performance_start.log').open('w') as f:subprocess.run([str(ctl),'-D',str(data),'-l',str(Path(lab['cluster'])/'postgres.log'),'-o','-h 127.0.0.1 -p 55447 -c shared_buffers=16MB -c max_connections=16','-w','start'],stdout=f,stderr=f,check=True)
try:
    for label,db in (('baseline_without_cp12',baseline),('cp12_installed',active)):
        conn=psycopg2.connect(host='127.0.0.1',port=55447,user='postgres',password=lab['password'],dbname=db)
        try:
            with conn.cursor() as c:
                c.execute("SELECT to_regnamespace('cp12') IS NOT NULL");assert c.fetchone()[0]==(label=='cp12_installed')
                uid,inst,mid=map(str,(uuid4(),uuid4(),uuid4()))
                c.execute("INSERT INTO public.users(user_id,email,role,account_status,email_verified,created_at,updated_at) VALUES(%s,%s,'entrepreneur','active',true,now(),now())",(uid,uid+'@example.test'))
                c.execute("INSERT INTO public.m2_instrument_versions(id,code,version_tag,approval_state,schema_digest) VALUES(%s,%s,'SYNTHETIC','AUTHORIZED',%s)",(inst,'BENCH-'+uid[:8],'a'*64))
                c.execute('INSERT INTO public.m2_assessments(id,owner_user_id,instrument_id,revision) VALUES(%s,%s,%s,0)',(mid,uid,inst))
                c.execute('SET LOCAL ROLE p1_m2_runtime');c.execute("SELECT set_config('project1.actor_id',%s,true)",(uid,))
                samples=[]
                for _ in range(100):
                    start=time.perf_counter();c.execute('UPDATE public.m2_assessments SET revision=revision WHERE id=%s',(mid,));assert c.rowcount==1;samples.append((time.perf_counter()-start)*1000)
                results[label]={'samples':100,'mean_ms':round(statistics.mean(samples),3),'median_ms':round(statistics.median(samples),3),'p95_ms':round(sorted(samples)[94],3),'rolled_back':True}
        finally:conn.rollback();conn.close()
    results['scope']='synthetic_private_postgresql_small_sample_not_a_live_load_or_sla';results['approved_threshold']='NOT_SPECIFIED'
    (OUT/'performance_comparison.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results,indent=2))
finally:
    with (OUT/'performance_stop.log').open('w') as f:subprocess.run([str(ctl),'-D',str(data),'-m','fast','-w','stop'],stdout=f,stderr=f,check=True)
