"""Capture and restore-test both local databases while writers are paused.

This script does not apply migrations, change role attributes or delete data.
It holds SHARE locks on application tables until the private restore checks finish.
Backups contain sensitive user data and stay local. Private databases are not
deleted. A failed lock or verification leaves live data unchanged.
"""
import hashlib, json, os, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4
import psycopg2
from psycopg2 import sql
from sqlalchemy.engine import make_url

ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'artifacts/cp12_20261118'
sys.path.insert(0,str(ROOT/'backend/src'))
from sitewise.core.config import Settings
lab=json.loads((ROOT/'artifacts/cp11_20261118/private_cluster.json').read_text())
assert lab['host']=='127.0.0.1' and lab['port']==55447
s=Settings(_env_file=(ROOT/'backend/.env',ROOT/'backend/.env.local'));u=make_url(s.database_url);m=make_url(s.m2_database_url.get_secret_value())
assert u.database=='Final_Location_Analysis' and m.database=='Dss' and u.host in ('127.0.0.1','localhost') and (u.host,u.port)==(m.host,m.port) and (u.port or 5432)==5432
bindir=Path('C:/Program Files/PostgreSQL/16/bin');ctl=bindir/'pg_ctl.exe';data=Path(lab['cluster'])/'data'
out=OUT/('write_paused_backup_'+datetime.now().strftime('%Y%m%d_%H%M%S'));out.mkdir()
result={'scope':'FRESH_BACKUP_UNDER_CROSS_DATABASE_WRITE_PAUSE','started_utc':datetime.now(timezone.utc).isoformat(),'live_data_writes':0,'databases':{}}
connections=[];started=False
def private(db):return psycopg2.connect(host='127.0.0.1',port=55447,user='postgres',password=lab['password'],dbname=db)
try:
    with (out/'private_start.log').open('w') as f:subprocess.run([str(ctl),'-D',str(data),'-l',str(Path(lab['cluster'])/'postgres.log'),'-o','-h 127.0.0.1 -p 55447 -c shared_buffers=16MB -c max_connections=16','-w','start'],stdout=f,stderr=f,check=True)
    started=True
    for db in ('Final_Location_Analysis','Dss'):
        c=psycopg2.connect(host=u.host,port=u.port or 5432,user=u.username,password=u.password,dbname=db)
        connections.append((db,c))
        with c.cursor() as cur:
            cur.execute("SET LOCAL lock_timeout='5s'")
            cur.execute("SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_%' AND c.relkind IN ('r','p') ORDER BY 1,2")
            tables=cur.fetchall()
            for schema,table in tables:cur.execute(sql.SQL('LOCK TABLE {}.{} IN SHARE MODE').format(sql.Identifier(schema),sql.Identifier(table)))
            result['databases'][db]={'locked_tables':len(tables)}
    # Both sets of table locks are now held simultaneously.
    market=connections[0][1];dss=connections[1][1]
    with market.cursor() as c:
        c.execute("SELECT user_id,property_id,status,requirements IS NULL,requirements_saved_at IS NULL,evidence_reviewed_at IS NULL,explanation_reviewed_at IS NULL,report_generated_at IS NULL FROM public.assessment WHERE assessment_id=%s",('d45366fd-b360-4d49-867a-8b7858b37e5a',));row=c.fetchone()
        assert row and str(row[0])=='32ef694a-69b0-4863-a77f-b9cf6c056b56' and row[1]=='MD-02521' and row[2]=='in_progress' and all(row[3:]),'Target eligibility changed'
    with dss.cursor() as c:
        c.execute('SELECT count(*) FROM m2_assessment_links WHERE marketplace_assessment_id=%s',('d45366fd-b360-4d49-867a-8b7858b37e5a',));assert c.fetchone()[0]==0,'Target acquired an M2 link'
    env={**os.environ,'PGHOST':u.host,'PGPORT':str(u.port or 5432),'PGUSER':u.username,'PGPASSWORD':u.password,'PGOPTIONS':'-c default_transaction_read_only=on -c statement_timeout=120000'}
    with (out/'globals.sql').open('w') as f,(out/'globals.log').open('w') as log:subprocess.run([str(bindir/'pg_dumpall.exe'),'--globals-only','--no-role-passwords'],env=env,stdout=f,stderr=log,check=True)
    for db,src in connections:
        archive=out/(db+'.dump')
        with (out/(db+'_dump.log')).open('w') as f:subprocess.run([str(bindir/'pg_dump.exe'),'-Fc','--file',str(archive)],env={**env,'PGDATABASE':db},stdout=f,stderr=f,check=True)
        dest='cp12_paused_restore_'+('fla_' if db=='Final_Location_Analysis' else 'dss_')+uuid4().hex[:8]
        admin=private('postgres');admin.autocommit=True
        with admin.cursor() as c:c.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(dest)))
        admin.close()
        pe={**os.environ,'PGHOST':'127.0.0.1','PGPORT':'55447','PGUSER':'postgres','PGPASSWORD':lab['password'],'PGDATABASE':dest};pe.pop('PGOPTIONS',None)
        with (out/(db+'_restore.log')).open('w') as f:subprocess.run([str(bindir/'pg_restore.exe'),'--exit-on-error','-d',dest,str(archive)],env=pe,stdout=f,stderr=f,check=True)
        clone=private(dest)
        try:
            acl="""SELECT n.nspname,c.relname,pg_get_userbyid(c.relowner),COALESCE(pg_get_userbyid(x.grantee),'PUBLIC'),pg_get_userbyid(x.grantor),x.privilege_type,x.is_grantable FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl,acldefault(CASE WHEN c.relkind='S' THEN 'S'::\"char\" ELSE 'r'::\"char\" END,c.relowner))) x WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema' AND c.relkind IN ('r','p','v','m','S') ORDER BY 1,2,3,4,5,6,7"""
            with src.cursor() as c:c.execute(acl);a=set(c.fetchall())
            with clone.cursor() as c:c.execute(acl);b=set(c.fetchall())
            assert a==b,'Effective relation owner/ACL restore mismatch'
            query=("SELECT count(*),md5(coalesce(string_agg(md5(to_jsonb(r)::text),'' ORDER BY md5(to_jsonb(r)::text)),'')) FROM public.assessment r WHERE user_id='32ef694a-69b0-4863-a77f-b9cf6c056b56'" if db=='Final_Location_Analysis' else "SELECT count(*),md5(coalesce(string_agg(md5(to_jsonb(r)::text),'' ORDER BY md5(to_jsonb(r)::text)),'')) FROM public.m2_answer_revisions r WHERE assessment_id IN ('b438c959-dbb4-4f99-8322-0f841dbba755','7a2f0b5c-6e75-4aa0-934b-a529681b20ac')")
            with src.cursor() as c:c.execute(query);a=c.fetchone()
            with clone.cursor() as c:c.execute(query);b=c.fetchone()
            assert a==b,'Protected record checksum differs after restore'
        finally:clone.close()
        result['databases'][db].update(archive=str(archive),sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),bytes=archive.stat().st_size,private_restore=dest,restore_port=55447,effective_relation_acl_match=True,protected_records_count=a[0],protected_records_checksum=a[1])
        (out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    result['status']='PASS';result['completed_utc']=datetime.now(timezone.utc).isoformat();result['limitations']=['Role passwords excluded from globals; existing live roles are not modified','Locks cover physical application tables, not external systems or administrator role changes','Two independent databases; no distributed atomicity']
    (out/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'status':'PASS','evidence':str(out/'results.json'),'databases':result['databases']},indent=2))
finally:
    for _,connection in reversed(connections):connection.rollback();connection.close()
    if started:
        with (out/'private_stop.log').open('w') as f:subprocess.run([str(ctl),'-D',str(data),'-m','fast','-w','stop'],stdout=f,stderr=f,check=True)
