"""Run BDJ receipt tests against a new private PostgreSQL cluster only."""
import os
import argparse
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=55438)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        raise SystemExit('A valid private loopback port is required.')
    root = Path(__file__).resolve().parents[2]
    bins = Path(r'C:\Program Files\PostgreSQL\18\bin')
    for name in ('initdb.exe', 'pg_ctl.exe', 'psql.exe'):
        if not (bins / name).is_file():
            raise SystemExit('Missing private PostgreSQL test binary: ' + name)
    with socket.socket() as check:
        check.bind(('127.0.0.1', args.port))
    lab = Path(tempfile.mkdtemp(prefix='project1_v15_bdj_'))
    print('Private synthetic BDJ lab:', lab, flush=True)
    password = secrets.token_urlsafe(24)
    pwfile = lab / 'init_password'
    pwfile.write_text(password, encoding='ascii')
    env = os.environ.copy()
    env.update(PGHOST='127.0.0.1', PGPORT=str(args.port), PGUSER='postgres',
               PGPASSWORD=password, PGDATABASE='postgres',
               PROJECT1_KEY_CUSTODY_DIR=str(lab / 'key-custody'),
               PROJECT1_BDJ_PRIVATE_PORT=str(args.port))
    started = False
    with (lab / 'setup.log').open('w', encoding='utf-8') as log:
        def run(args):
            subprocess.run(args, env=env, cwd=root, stdout=log, stderr=log, check=True)
        try:
            run([str(bins/'initdb.exe'), '-D', str(lab/'data'), '-U', 'postgres',
                 '--encoding=UTF8', '--locale=C', '-A', 'scram-sha-256',
                 f'--pwfile={pwfile}'])
            pwfile.unlink()
            run([str(bins/'pg_ctl.exe'), '-D', str(lab/'data'), '-l', str(lab/'postgres.log'),
                 '-o', f'-h 127.0.0.1 -p {args.port}', '-w', 'start'])
            started = True
            psql = [str(bins/'psql.exe'), '-v', 'ON_ERROR_STOP=1']
            run(psql + ['-c', 'CREATE DATABASE project1_workflow_tests'])
            env['PGDATABASE'] = 'project1_workflow_tests'
            run(psql + ['-f', str(root/'tests/cp07/fixtures/stage_m2_schema.sql')])
            for migration in ('20261111_01_candidate_ledger.sql',
                              '20261117_01_execution_principal.sql',
                              '20261117_02_finding_provenance.sql',
                              '20261117_03_bdj_result_persistence.sql'):
                run(psql + ['-c', "SET project1.migration_target='project1_workflow_tests'; "
                            "SET project1.migration_receipt='PRIVATE-SYNTHETIC-LAB';", '-f',
                            str(root/'migrations/project1_ai'/migration)])
            # The password is generated for this disposable server only and is
            # never printed. token_urlsafe has no SQL quote characters.
            run(psql + ['-c', f"ALTER ROLE p1ai_engine PASSWORD '{password}'"])
            env['PROJECT1_CLONE_URL'] = (
                f'postgresql+psycopg2://p1ai_engine:{password}@127.0.0.1:{args.port}/project1_workflow_tests')
            env['PROJECT1_CLONE_ADMIN_URL'] = (
                f'postgresql+psycopg2://postgres:{password}@127.0.0.1:{args.port}/project1_workflow_tests')
            result = subprocess.run([sys.executable, '-m', 'pytest',
                'tests/project1/test_model_assisted_route.py', 'tests/project1/test_result_store.py',
                '--confcutdir=tests/project1', '-q'], env=env, cwd=root,
                capture_output=True, text=True)
            (lab/'pytest.log').write_text(result.stdout + result.stderr, encoding='utf-8')
            print(result.stdout + result.stderr, flush=True)
            return result.returncode
        finally:
            if pwfile.exists():
                pwfile.unlink()
            if started:
                run([str(bins/'pg_ctl.exe'), '-D', str(lab/'data'), '-m', 'fast', '-w', 'stop'])


if __name__ == '__main__':
    raise SystemExit(main())
