r"""Private PostgreSQL migration/RLS tests. No existing database is touched."""
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    binaries = Path(os.environ.get('CP07_PG_BIN', r'C:\Program Files\PostgreSQL\18\bin'))
    for name in ('initdb.exe','pg_ctl.exe','psql.exe'):
        if not (binaries/name).is_file(): raise SystemExit('Missing PostgreSQL test binary')
    with socket.socket() as check: check.bind(('127.0.0.1',55439))
    lab=Path(tempfile.mkdtemp(prefix='project1_workflow_'))
    print('Private workflow lab: '+str(lab),flush=True)
    password=secrets.token_urlsafe(32)
    pwfile=lab/'init_password'; pwfile.write_text(password,encoding='ascii')
    env=os.environ.copy()
    env.update(PGPASSWORD=password,PGHOST='127.0.0.1',PGPORT='55439',PGUSER='postgres',
               PGDATABASE='postgres')
    started=False
    with (lab/'setup.log').open('w',encoding='utf-8') as log:
        def run(args): subprocess.run(args,env=env,cwd=root,stdout=log,stderr=log,check=True)
        try:
            run([str(binaries/'initdb.exe'),'-D',str(lab/'data'),'-U','postgres',
                 '--encoding=UTF8','--locale=C','-A','scram-sha-256',f'--pwfile={pwfile}'])
            pwfile.unlink()
            run([str(binaries/'pg_ctl.exe'),'-D',str(lab/'data'),'-l',str(lab/'postgres.log'),
                 '-o','-h 127.0.0.1 -p 55439','-w','start'])
            started=True
            run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-c',
                 'CREATE DATABASE project1_workflow_tests'])
            env['PGDATABASE']='project1_workflow_tests'
            run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-f',
                 str(root/'tests/cp07/fixtures/stage_m2_schema.sql')])
            # Test-only explicit operator receipt; production adoption is not implied.
            run([str(binaries/'psql.exe'),'-v','ON_ERROR_STOP=1','-c',
                 "SET project1.migration_target='project1_workflow_tests'; "
                 "SET project1.migration_receipt='SYNTHETIC-PRIVATE-LAB-ONLY';",'-f',
                 str(root/'migrations/project1_ai/20261111_01_candidate_ledger.sql')])
            env['PROJECT1_LAB_URL']=f'postgresql+psycopg2://postgres:{password}@127.0.0.1:55439/project1_workflow_tests'
            env['PROJECT1_LAB_ROOT']=str(lab)
            outcome=subprocess.run([sys.executable,'-m','pytest','tests/project1/test_postgres.py',
                '--confcutdir=tests/project1','-q',f'--junitxml={lab / "pytest.xml"}'],
                env=env,cwd=root,capture_output=True,text=True)
            (lab/'pytest.log').write_text(outcome.stdout+outcome.stderr,encoding='utf-8')
            print(outcome.stdout+outcome.stderr,flush=True)
            return outcome.returncode
        finally:
            if pwfile.exists(): pwfile.unlink()
            if started:
                run([str(binaries/'pg_ctl.exe'),'-D',str(lab/'data'),'-m','fast','-w','stop'])


if __name__=='__main__': raise SystemExit(main())
