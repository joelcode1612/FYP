"""Match selected role attributes/memberships on the PRIVATE cluster only.

Fresh random passwords remain in this process. Live access is strictly read-only.
"""
import json, secrets, subprocess, sys
from pathlib import Path
import psycopg2
from psycopg2 import sql
from sqlalchemy.engine import make_url

ROOT=Path(__file__).resolve().parents[3]; OUT=ROOT/'artifacts/cp12_20261118'
sys.path.insert(0,str(ROOT/'backend/src'))
from sitewise.core.config import Settings

lab=json.loads((ROOT/'artifacts/cp11_20261118/private_cluster.json').read_text())
assert lab['host']=='127.0.0.1' and lab['port']==55447
s=Settings(_env_file=(ROOT/'backend/.env',ROOT/'backend/.env.local')); live=make_url(s.database_url)
assert live.host in ('localhost','127.0.0.1') and live.database=='Final_Location_Analysis'
role_names=['p1_m2_runtime','p1_ee01_runtime','p1ai_runtime','p1ai_owner','p1ai_engine']
restore=json.loads((OUT/'permission_restore_results.json').read_text())['Dss']['private_db']
tested=json.loads((OUT/'two_user_creation_results.json').read_text()); db=json.loads((OUT/'postgres_results.json').read_text())['databases'][1]
assert restore.startswith('cp12_acl_dss_') and db.startswith('cp12_')
ctl=Path('C:/Program Files/PostgreSQL/16/bin/pg_ctl.exe'); data=Path(lab['cluster'])/'data'; result={}
with (OUT/'private_role_start.log').open('w') as f:
    subprocess.run([str(ctl),'-D',str(data),'-l',str(Path(lab['cluster'])/'postgres.log'),'-o','-h 127.0.0.1 -p 55447 -c shared_buffers=16MB -c max_connections=16','-w','start'],stdout=f,stderr=f,check=True)
try:
    a=psycopg2.connect(host=live.host,port=live.port or 5432,user=live.username,password=live.password,dbname='Dss',options='-c default_transaction_read_only=on')
    z=psycopg2.connect(host='127.0.0.1',port=55447,user='postgres',password=lab['password'],dbname=restore)
    assert z.info.port==55447 and z.info.host=='127.0.0.1'
    q="SELECT rolname,rolcanlogin,rolinherit,rolsuper,rolbypassrls,rolcreatedb,rolcreaterole,rolreplication FROM pg_roles WHERE rolname=ANY(%s) ORDER BY rolname"
    mq="SELECT r.rolname,m.rolname,a.admin_option FROM pg_auth_members a JOIN pg_roles r ON r.oid=a.roleid JOIN pg_roles m ON m.oid=a.member WHERE r.rolname=ANY(%s) OR m.rolname=ANY(%s) ORDER BY 1,2"
    with a.cursor() as c:
        c.execute(q,(role_names,)); source=c.fetchall(); c.execute(mq,(role_names,role_names)); memberships=c.fetchall()
    assert len(source)==len(role_names)
    passwords={'p1_m2_runtime':lab['runtime_password'],'p1_ee01_runtime':secrets.token_urlsafe(32),'p1ai_engine':secrets.token_urlsafe(32)}
    with z.cursor() as c:
        c.execute('SHOW log_statement'); assert c.fetchone()[0]=='none'
        for name,login,inherit,superuser,bypass,createdb,createrole,repl in source:
            assert not any((superuser,bypass,createdb,createrole,repl)), 'Privileged source role requires review'
            statement=sql.SQL('ALTER ROLE {} {} {} NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION').format(sql.Identifier(name),sql.SQL('LOGIN' if login else 'NOLOGIN'),sql.SQL('INHERIT' if inherit else 'NOINHERIT'))
            c.execute(statement)
            if login and name!='p1_m2_runtime':
                c.execute(sql.SQL('ALTER ROLE {} PASSWORD {}').format(sql.Identifier(name),sql.Literal(passwords[name])))
        c.execute(mq,(role_names,role_names)); current=c.fetchall()
        if set(current)-set(memberships):raise RuntimeError('Unexpected private membership; refuse automatic removal')
        for parent,member,admin in set(memberships)-set(current):
            c.execute(sql.SQL('GRANT {} TO {}{}').format(sql.Identifier(parent),sql.Identifier(member),sql.SQL(' WITH ADMIN OPTION' if admin else '')))
        c.execute(q,(role_names,)); restored=c.fetchall();c.execute(mq,(role_names,role_names)); restored_memberships=c.fetchall()
    z.commit();a.close();z.close()
    assert source==restored and memberships==restored_memberships
    result['role_attributes_match']=True;result['memberships_match']=True
    result['scope']='PRIVATE_CLUSTER_ONLY'; result['live_role_writes']=0
    connections={}
    for name in ('p1_m2_runtime','p1_ee01_runtime','p1ai_engine'):
        c=psycopg2.connect(host='127.0.0.1',port=55447,user=name,password=passwords[name],dbname=db)
        try:
            with c.cursor() as cur:
                cur.execute('SELECT current_user,session_user');who=cur.fetchone();assert who==(name,name)
                if name=='p1_m2_runtime':
                    cur.execute("SELECT has_function_privilege(current_user,'cp12.inspect(uuid)','EXECUTE')"); assert cur.fetchone()[0]
                elif name=='p1_ee01_runtime':
                    cur.execute("SELECT has_table_privilege(current_user,'public.ee01_measurement_snapshots','INSERT')"); assert cur.fetchone()[0]
                    cur.execute("SELECT has_schema_privilege(current_user,'cp12','USAGE')"); assert not cur.fetchone()[0]
                else:
                    cur.execute('SET ROLE p1ai_runtime')
                    cur.execute("SELECT has_table_privilege(current_user,'project1_ai.runs','INSERT')"); assert cur.fetchone()[0]
                connections[name]='PASS'
        finally: c.close()
    result['test_credential_connectivity']=connections
    result['note']='p1_ee01_runtime does not call the CP12 functions but its writes traverse CP12 triggers; trigger behavior remains a separate test.'
    (OUT/'private_role_rehearsal.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
finally:
    with (OUT/'private_role_stop.log').open('w') as f:subprocess.run([str(ctl),'-D',str(data),'-m','fast','-w','stop'],stdout=f,stderr=f,check=True)
