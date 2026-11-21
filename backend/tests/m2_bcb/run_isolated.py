"""Restore read-only Dss schema to a NEW private cluster and test M2 → BCB.

Never connects to an existing server. No source/approval data is cloned.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile


def main():
    if hasattr(sys.stdout,'reconfigure'):sys.stdout.reconfigure(encoding='utf-8',errors='replace')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--suite', choices=['regression','current-instrument'], default='regression')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.output.resolve()
    if out == root or root in out.parents: raise SystemExit('Evidence must be outside backend.')
    out.mkdir(parents=True, exist_ok=True)
    binaries = Path(r'C:\Program Files\PostgreSQL\18\bin')
    for name in ('initdb.exe','pg_ctl.exe','psql.exe','pg_dump.exe'):
        if not (binaries/name).is_file(): raise SystemExit('Missing installed PostgreSQL binary: '+name)
    with socket.socket() as probe: probe.bind(('127.0.0.1',55441))
    lab = Path(tempfile.mkdtemp(prefix='project1_m2_bcb_'))
    print('NEW private PostgreSQL lab: '+str(lab), flush=True)
    password = secrets.token_urlsafe(32)
    pwfile = lab/'init_password'; pwfile.write_text(password,encoding='ascii')
    env = os.environ.copy()
    env.update(PGHOST='127.0.0.1',PGPORT='55441',PGUSER='postgres',PGPASSWORD=password,PGDATABASE='postgres')
    started = False
    schema = root/'tests/m2_bcb/fixtures/dss_m2_schema_20261113.sql'
    migration = root/'migrations/m2/20261113_01_confirmed_context_persistence.sql'
    try:
        with (out/'cluster_setup.log').open('w',encoding='utf-8') as log:
            def run(command): subprocess.run(command,env=env,cwd=root,stdout=log,stderr=log,check=True)
            run([str(binaries/'initdb.exe'),'-D',str(lab/'data'),'-U','postgres','--encoding=UTF8',
                '--locale=C','-A','scram-sha-256','--pwfile='+str(pwfile)])
            pwfile.unlink()
            run([str(binaries/'pg_ctl.exe'),'-D',str(lab/'data'),'-l',str(lab/'postgres.log'),
                '-o','-h 127.0.0.1 -p 55441','-w','start'])
            started=True
            run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-c','CREATE DATABASE project1_m2_bcb_test'])
            env['PGDATABASE']='project1_m2_bcb_test'
            run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-f',str(schema)])
            denied = subprocess.run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-f',str(migration)],
                env=env,cwd=root,capture_output=True,text=True)
            (out/'migration_without_receipt.log').write_text(denied.stdout+denied.stderr,encoding='utf-8')
            if denied.returncode == 0: raise RuntimeError('Migration guard did not reject missing receipt.')
            run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-c',
                "SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; SET project1.m2_bcb_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",'-f',str(migration)])
            run([str(binaries/'psql.exe'), '-v', 'ON_ERROR_STOP=1', '-c',
                 "SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; SET project1.m2_bcb_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",
                 '-f', str(root/'migrations/m2/20261114_02_research_objective_sources.sql')])
            run([str(binaries/'psql.exe'), '-v', 'ON_ERROR_STOP=1', '-c',
                 "SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; SET project1.m2_bcb_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",
                 '-f', str(root/'migrations/m2/20261115_01_candidate_owner_review.sql')])
            run([str(binaries/'psql.exe'), '-v', 'ON_ERROR_STOP=1', '-c',
                 "SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; SET project1.m2_bcb_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",
                 '-f', str(root/'migrations/m2/20261115_02_workflow_projection.sql')])
            if env.get('PART_TWO_CROSS_APP')=='1':
                run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-c',
                    "SET project1.cq_migration_target='project1_m2_bcb_test'; SET project1.cq_migration_receipt='SYNTHETIC-PRIVATE-CROSS-APP-ONLY';",'-f',str(root/'migrations/cq/20261113_01_cq_runtime.sql')])
                run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-c',
                    "SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; SET project1.m2_bcb_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",
                    '-f',str(root/'migrations/m2/20261115_03_workflow_cq_bridge.sql')])
                env.update(CQ_RUNTIME_ENABLED='true',CQ_PRIVATE_CLUSTER=str(lab))
            env.update(DATABASE_URL=f'postgresql+psycopg2://postgres:{password}@127.0.0.1:55441/project1_m2_bcb_test',
                M2_DATABASE_URL=f'postgresql+psycopg2://postgres:{password}@127.0.0.1:55441/project1_m2_bcb_test',
                M2_EXPECTED_DATABASE='project1_m2_bcb_test',
                ANALYTICS_DATABASE_URL=f'postgresql+psycopg2://postgres:{password}@127.0.0.1:55441/project1_m2_bcb_test',
                M2_UPSTREAM_ENABLED='true',M2_BCB_PERSISTENCE_ENABLED='true',
                PROJECT1_CP07_ENABLED='false',PROJECT1_WORKFLOW_ENABLED='false',TOKENHARBOR_ENABLED='false',
                PYTHONPATH=str(root/'src')+os.pathsep+str(root),PYTHONIOENCODING='utf-8',
                M2_BCB_PRIVATE_CLUSTER=str(lab),M2_BCB_EVIDENCE=str(out),PYTHONDONTWRITEBYTECODE='1')
            outcome = subprocess.run([sys.executable,'-B','-m','pytest',
                'tests/m2_bcb/test_adopted_m2_v1.py' if args.suite=='current-instrument' else 'tests/m2_bcb/test_postgres_api.py',
                '--confcutdir=tests/m2_bcb','-q','--junitxml='+str(out/'pytest.xml')],
                env=env,cwd=root,capture_output=True,text=True,encoding='utf-8',timeout=1200 if env.get('PART_TWO_CROSS_APP')=='1' else 240)
            (out/'pytest.log').write_text(outcome.stdout+outcome.stderr,encoding='utf-8')
            print(outcome.stdout+outcome.stderr,flush=True)
            run([str(binaries/'pg_dump.exe'),'--schema-only','--no-owner','--no-privileges','--file='+str(out/'private_schema_after.sql')])
            # Exercise removal only inside the disposable database, after capturing its schema.
            rollback = '''
            BEGIN;
            DO $$ DECLARE t record; BEGIN
              FOR t IN SELECT tgname,tgrelid::regclass AS relation FROM pg_trigger
                       WHERE tgfoid IN ('public.m2_workflow_change()'::regprocedure,to_regprocedure('public.m2_workflow_cq_change()')) LOOP
                EXECUTE format('DROP TRIGGER %I ON %s',t.tgname,t.relation);
              END LOOP;
            END $$;
            DROP FUNCTION public.m2_workflow_change();
            DROP FUNCTION public.refresh_m2_workflow(uuid);
            DROP VIEW public.m2_workflow_summary;
            DROP VIEW public.m2_workflow_campaigns;
            DROP FUNCTION IF EXISTS public.m2_workflow_cq_change();
            DROP TABLE public.assessment_workflow_projection;
            COMMIT;
            SELECT to_regclass('public.assessment_workflow_projection') IS NULL
                   AND to_regclass('public.m2_assessments') IS NOT NULL;
            '''
            check = subprocess.run([str(binaries/'psql.exe'),'-XAt','-v','ON_ERROR_STOP=1','-c',rollback],
                                   env=env,cwd=root,capture_output=True,text=True,check=True)
            (out/'projection_rollback.log').write_text(check.stdout)
            if check.stdout.strip().splitlines()[-1] != 't':
                raise RuntimeError('Isolated projection removal failed.')
            (out/'run.json').write_text(json.dumps({'exit_code':outcome.returncode,'cluster':str(lab),
                'database':'project1_m2_bcb_test','port':55441,'source_schema_sha256':hashlib.sha256(schema.read_bytes()).hexdigest(),
                'migration_sha256':hashlib.sha256(migration.read_bytes()).hexdigest(),
                'migration_without_receipt_rejected':True,'live_database_writes':False,
                'data':'explicit synthetic instrument and authority fixtures; actual PostgreSQL persistence',
                'lifespan':'off','production_acceptance':False},indent=2),encoding='utf-8')
            return outcome.returncode
    finally:
        if pwfile.exists(): pwfile.unlink()
        if started:
            subprocess.run([str(binaries/'pg_ctl.exe'),'-D',str(lab/'data'),'-m','fast','-w','stop'],
                env=env,capture_output=True,check=True)
            print('Private cluster stopped; live Dss was not written.',flush=True)


if __name__=='__main__': raise SystemExit(main())
