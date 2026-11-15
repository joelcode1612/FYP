"""Restore read-only Dss schema to a NEW private cluster and test CQ application.

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
    if hasattr(sys.stdout,'reconfigure'): sys.stdout.reconfigure(encoding='utf-8',errors='replace')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.output.resolve()
    if out == root or root in out.parents: raise SystemExit('Evidence must be outside backend.')
    out.mkdir(parents=True, exist_ok=True)
    binaries = Path(r'C:\Program Files\PostgreSQL\18\bin')
    for name in ('initdb.exe','pg_ctl.exe','psql.exe','pg_dump.exe'):
        if not (binaries/name).is_file(): raise SystemExit('Missing installed PostgreSQL binary: '+name)
    with socket.socket() as probe: probe.bind(('127.0.0.1',55443))
    lab = Path(tempfile.mkdtemp(prefix='project1_cq_runtime_'))
    print('NEW private PostgreSQL lab: '+str(lab), flush=True)
    password = secrets.token_urlsafe(32)
    pwfile = lab/'init_password'; pwfile.write_text(password,encoding='ascii')
    env = os.environ.copy()
    env.update(PGHOST='127.0.0.1',PGPORT='55443',PGUSER='postgres',PGPASSWORD=password,PGDATABASE='postgres')
    started = False
    schema = root/'tests/cq_runtime/fixtures/dss_m2_schema_20261113.sql'
    migration = root/'migrations/cq/20261113_01_cq_runtime.sql'
    try:
        with (out/'cluster_setup.log').open('w',encoding='utf-8') as log:
            def run(command): subprocess.run(command,env=env,cwd=root,stdout=log,stderr=log,check=True)
            run([str(binaries/'initdb.exe'),'-D',str(lab/'data'),'-U','postgres','--encoding=UTF8',
                '--locale=C','-A','scram-sha-256','--pwfile='+str(pwfile)])
            pwfile.unlink()
            run([str(binaries/'pg_ctl.exe'),'-D',str(lab/'data'),'-l',str(lab/'postgres.log'),
                '-o','-h 127.0.0.1 -p 55443','-w','start'])
            started=True
            run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-c','CREATE DATABASE project1_cq_runtime_test'])
            env['PGDATABASE']='project1_cq_runtime_test'
            run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-f',str(schema)])
            denied = subprocess.run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-f',str(migration)],
                env=env,cwd=root,capture_output=True,text=True)
            (out/'migration_without_receipt.log').write_text(denied.stdout+denied.stderr,encoding='utf-8')
            if denied.returncode == 0: raise RuntimeError('Migration guard did not reject missing receipt.')
            run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-c',
                "SET project1.cq_migration_target='project1_cq_runtime_test'; SET project1.cq_migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",'-f',str(migration)])
            env.update(DATABASE_URL=f'postgresql+psycopg2://postgres:{password}@127.0.0.1:55443/project1_cq_runtime_test',
                M2_DATABASE_URL=f'postgresql+psycopg2://postgres:{password}@127.0.0.1:55443/project1_cq_runtime_test',
                M2_EXPECTED_DATABASE='project1_cq_runtime_test',
                ANALYTICS_DATABASE_URL=f'postgresql+psycopg2://postgres:{password}@127.0.0.1:55443/project1_cq_runtime_test',
                M2_UPSTREAM_ENABLED='false',M2_BCB_PERSISTENCE_ENABLED='false',CQ_RUNTIME_ENABLED='true',
                PROJECT1_CP07_ENABLED='false',PROJECT1_WORKFLOW_ENABLED='false',TOKENHARBOR_ENABLED='false',
                PYTHONPATH=str(root/'src')+os.pathsep+str(root),PYTHONIOENCODING='utf-8',
                CQ_PRIVATE_CLUSTER=str(lab),CQ_EVIDENCE=str(out),PYTHONDONTWRITEBYTECODE='1')
            outcome = subprocess.run([sys.executable,'-B','-m','pytest','tests/cq_runtime/test_postgres_api.py',
                '--confcutdir=tests/cq_runtime','-q','--junitxml='+str(out/'pytest.xml')],
                env=env,cwd=root,capture_output=True,text=True,encoding='utf-8',timeout=600)
            (out/'pytest.log').write_text(outcome.stdout+outcome.stderr,encoding='utf-8')
            print(outcome.stdout+outcome.stderr,flush=True)
            run([str(binaries/'pg_dump.exe'),'--schema-only','--no-owner','--no-privileges','--file='+str(out/'private_schema_after.sql')])
            (out/'run.json').write_text(json.dumps({'exit_code':outcome.returncode,'cluster':str(lab),
                'database':'project1_cq_runtime_test','port':55443,'source_schema_sha256':hashlib.sha256(schema.read_bytes()).hexdigest(),
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
