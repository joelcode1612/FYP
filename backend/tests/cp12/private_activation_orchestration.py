"""Exercise exact migrations on the same private connections holding write locks."""
import json,secrets,subprocess
from pathlib import Path
from uuid import uuid4
import psycopg2
from psycopg2 import sql
ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'artifacts/cp12_20261118'
lab=json.loads((ROOT/'artifacts/cp11_20261118/private_cluster.json').read_text()); runs=json.loads((OUT/'migration_lock_results.json').read_text());assert lab['host']=='127.0.0.1' and lab['port']==55447
dbs={name:runs[name]['private_db'] for name in ('marketplace','dss')};assert all(v.startswith('cp12_migration_lock_') for v in dbs.values())
ctl=Path('C:/Program Files/PostgreSQL/16/bin/pg_ctl.exe');data=Path(lab['cluster'])/'data';connections={};results={}
with (OUT/'activation_orchestration_start.log').open('w') as f:subprocess.run([str(ctl),'-D',str(data),'-l',str(Path(lab['cluster'])/'postgres.log'),'-o','-h 127.0.0.1 -p 55447 -c shared_buffers=16MB -c max_connections=16','-w','start'],stdout=f,stderr=f,check=True)
try:
    for kind in ('marketplace','dss'):
        c=psycopg2.connect(host='127.0.0.1',port=55447,user='postgres',password=lab['password'],dbname=dbs[kind]);connections[kind]=c
        with c.cursor() as q:
            q.execute("SELECT to_regnamespace('cp12') IS NOT NULL")
            if q.fetchone()[0]:
                q.execute("SELECT count(*) FROM cp12.operations");assert q.fetchone()[0]==0
                q.execute("SELECT set_config('project1.cp12_migration_target',%s,false)",(dbs[kind],))
                q.execute("SELECT set_config('project1.cp12_migration_receipt','SYNTHETIC-CLEANUP-EMPTY-JOURNAL',false)")
                q.execute((ROOT/'backend/migrations/cp12'/(kind+'_down.sql')).read_text(encoding='utf-8'))
            q.execute('BEGIN')
            q.execute("SET LOCAL lock_timeout='5s'")
            q.execute("SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_%' AND c.relkind IN ('r','p') ORDER BY 1,2")
            tables=q.fetchall()
            for schema,table in tables:q.execute(sql.SQL('LOCK TABLE {}.{} IN SHARE MODE').format(sql.Identifier(schema),sql.Identifier(table)))
            results[kind]={'locked_tables':len(tables)}
    secret=secrets.token_bytes(32);aid=uuid4();owner=uuid4()
    for kind in ('dss','marketplace'):
        c=connections[kind]
        with c.cursor() as q:
            q.execute("SELECT set_config('project1.cp12_migration_target',%s,false)",(dbs[kind],))
            q.execute("SELECT set_config('project1.cp12_migration_receipt','SYNTHETIC-ORCHESTRATION-ONLY',false)")
            q.execute((ROOT/'backend/migrations/cp12'/(kind+'_up.sql')).read_text(encoding='utf-8'))
        results[kind]['up']='PASS'
    for kind,c in connections.items():
        with c.cursor() as q:
            q.execute('INSERT INTO cp12.handoff_key(secret) VALUES (%s)',(psycopg2.Binary(secret),))
            if kind=='dss':q.execute("UPDATE cp12.policy SET approved=true,external_references_verified=true,receipt='SYNTHETIC-ONLY'")
            else:q.execute("UPDATE cp12.policy SET approved=true,receipt='SYNTHETIC-ONLY'")
            q.execute("INSERT INTO cp12.target_reviews VALUES (%s,%s,'SYNTHETIC-ONLY','SYNTHETIC-ONLY')",(str(aid),str(owner)))
        c.commit()
    for kind in ('marketplace','dss'):
        c=connections[kind]
        with c.cursor() as q:
            q.execute("SELECT set_config('project1.cp12_migration_target',%s,false)",(dbs[kind],))
            q.execute("SELECT set_config('project1.cp12_migration_receipt','SYNTHETIC-ROLLBACK-ONLY',false)")
            q.execute((ROOT/'backend/migrations/cp12'/(kind+'_down.sql')).read_text(encoding='utf-8'))
            q.execute("SELECT to_regnamespace('cp12') IS NULL");assert q.fetchone()[0]
        results[kind]['down']='PASS'
    results['status']='PASS';results['scope']='PRIVATE_SCHEMA_ONLY_NO_REAL_DATA'
    (OUT/'activation_orchestration_results.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results,indent=2))
finally:
    for c in connections.values():c.rollback();c.close()
    with (OUT/'activation_orchestration_stop.log').open('w') as f:subprocess.run([str(ctl),'-D',str(data),'-m','fast','-w','stop'],stdout=f,stderr=f,check=True)
