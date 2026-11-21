"""Read-only live CP12 protection sentinel. Never mutates either database."""
import argparse
import json
import sys
from pathlib import Path
from datetime import datetime, timezone
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'backend/src'))
from sitewise.core.config import Settings

def main():
    p=argparse.ArgumentParser(); p.add_argument('label'); args=p.parse_args()
    assert args.label in ('before','after')
    s=Settings(_env_file=(ROOT/'backend/.env',ROOT/'backend/.env.local'))
    url=make_url(s.database_url)
    assert url.database=='Final_Location_Analysis' and url.host in ('localhost','127.0.0.1')
    patterns=['%'+x+'%' for x in ('0a79fba2-3a39-4bd1-96b0-f245a1b2c0a7','b438c959-dbb4-4f99-8322-0f841dbba755','ffa8c0a3-fcd9-4e12-afa1-b7ce6392cc1b','7a2f0b5c-6e75-4aa0-934b-a529681b20ac')]
    data={'observed_at':datetime.now(timezone.utc).isoformat(),'scope':'READ_ONLY_LIVE_INTEGRITY','database_writes':0,'databases':{}}
    for db in ('Final_Location_Analysis','Dss'):
        engine=create_engine(url.set(database=db),hide_parameters=True,connect_args={'options':'-c default_transaction_read_only=on -c statement_timeout=20000'})
        with engine.connect().execution_options(isolation_level='REPEATABLE READ') as c:
            identity=dict(c.execute(text("SELECT current_database() AS database,current_user AS role,inet_server_port() AS port,current_setting('transaction_read_only') AS read_only")).mappings().one())
            installed=c.execute(text("SELECT to_regnamespace('cp12') IS NOT NULL")).scalar_one()
            tables=c.execute(text("SELECT quote_ident(n.nspname)||'.'||quote_ident(c.relname) AS name FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_%' AND c.relkind IN ('r','p') ORDER BY 1")).scalars().all()
            hashes={}
            for table in tables:
                rows=c.execute(text(f"SELECT md5(to_jsonb(r)::text) FROM {table} r WHERE lower(to_jsonb(r)::text) LIKE ANY(:patterns) ORDER BY 1"),{'patterns':patterns}).scalars().all()
                if rows: hashes[table]=rows
            info={'identity':identity,'cp12_schema_installed':installed,'related_row_hashes':hashes}
            if db=='Final_Location_Analysis':
                info['assessments']=[dict(r) for r in c.execute(text("SELECT assessment_id,property_id,status,created_at,updated_at FROM assessment WHERE assessment_id IN ('0a79fba2-3a39-4bd1-96b0-f245a1b2c0a7','ffa8c0a3-fcd9-4e12-afa1-b7ce6392cc1b')")).mappings()]
                # Restart must not launch unrelated pending durable jobs.
                table=c.execute(text("SELECT to_regclass('public.ml_explanation_cache')")).scalar()
                if table: info['pending_explanation_jobs']=c.execute(text("SELECT count(*) FROM ml_explanation_cache WHERE status='pending'")).scalar_one()
            else:
                info['m2_records']=[dict(r) for r in c.execute(text("SELECT a.id,a.revision,a.confirmed_revision,(SELECT count(*) FROM m2_answer_revisions r WHERE r.assessment_id=a.id) AS answer_revisions FROM m2_assessments a WHERE a.id IN ('b438c959-dbb4-4f99-8322-0f841dbba755','7a2f0b5c-6e75-4aa0-934b-a529681b20ac')")).mappings()]
            data['databases'][db]=info
        engine.dispose()
    out=ROOT/'artifacts/cp12_20261118'/('live_integrity_'+args.label+'.json')
    out.write_text(json.dumps(data,indent=2,default=str)+'\n')
    if args.label=='after':
        before=json.loads(out.with_name('live_integrity_before.json').read_text())
        comparison={db:before['databases'][db]['related_row_hashes']==x['related_row_hashes'] for db,x in data['databases'].items()}
        out.with_name('live_integrity_comparison.json').write_text(json.dumps(comparison,indent=2)+'\n')
        assert all(comparison.values()), 'Live target sentinel changed: inspect before proceeding'
    print(json.dumps({'evidence':str(out),'database_writes':0,'databases':{db:{k:v for k,v in d.items() if k!='related_row_hashes'} for db,d in data['databases'].items()}},default=str))
if __name__=='__main__': main()
