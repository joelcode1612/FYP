"""Read-only physical-table UUID scan for the explicit Option B target."""
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT/'backend/src'))
from sitewise.core.config import Settings

TARGET = 'd45366fd-b360-4d49-867a-8b7858b37e5a'
OWNER = '32ef694a-69b0-4863-a77f-b9cf6c056b56'
OUT = ROOT/'artifacts/cp12_20261118/fiesta_dependency_preflight.json'

def main():
    s=Settings(_env_file=(ROOT/'backend/.env',ROOT/'backend/.env.local'))
    u=make_url(s.database_url); m=make_url(s.m2_database_url.get_secret_value())
    assert u.host in ('localhost','127.0.0.1') and u.database=='Final_Location_Analysis'
    assert m.database=='Dss' and (u.host,u.port)==(m.host,m.port)
    result={'time_utc':datetime.now(timezone.utc).isoformat(),'target':TARGET,'owner':OWNER,
            'scope':'READ_ONLY_PHYSICAL_TABLE_UUID_SCAN','external_files_systems_and_retention':'UNVERIFIED',
            'cross_database_atomic_snapshot':False,'databases':{}}
    try:
        for db in ('Final_Location_Analysis','Dss'):
            e=create_engine(u.set(database=db),hide_parameters=True,connect_args={'options':'-c default_transaction_read_only=on -c statement_timeout=20000'})
            try:
                with e.connect().execution_options(isolation_level='REPEATABLE READ') as c:
                    identity=dict(c.execute(text("SELECT current_database() database,current_user role,inet_server_port() port,current_setting('transaction_read_only') read_only")).mappings().one())
                    tables=c.execute(text("SELECT quote_ident(n.nspname)||'.'||quote_ident(p.relname) FROM pg_class p JOIN pg_namespace n ON n.oid=p.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_%' AND p.relkind IN ('r','p') ORDER BY 1")).scalars().all()
                    refs={}
                    for name in tables:
                        count=c.execute(text(f'SELECT count(*) FROM {name} r WHERE lower(to_jsonb(r)::text) LIKE :needle'),{'needle':'%'+TARGET+'%'}).scalar_one()
                        if count: refs[name]=count
                    result['databases'][db]={'identity':identity,'tables_scanned':len(tables),'matches':refs}
            finally: e.dispose()
        result['outcome']='PHYSICAL_SCAN_COMPLETE_RETENTION_AND_EXTERNAL_REFS_UNVERIFIED'
    finally:
        OUT.write_text(json.dumps(result,indent=2,default=str)+'\n')
    print(json.dumps(result,indent=2))
if __name__=='__main__': main()
