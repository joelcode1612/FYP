"""Verify 20261121_04_execution_mode.sql against a throwaway cluster.

Uses a minimal stand-in for project1_ai.bdj_results so the test exercises THIS
migration only, not the whole result-persistence schema.

Proves: forward applies; legacy backfill is deterministic and never LIVE; the
CHECK rejects an unknown mode; the dispatch CHECK rejects LIVE without dispatch;
a valid LIVE row is accepted; rollback refuses while a LIVE row exists.
"""
from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(r'C:\Program Files\PostgreSQL\18\bin')
MIG = ROOT / 'migrations/project1_ai/20261121_04_execution_mode.sql'
ROLLBACK = ROOT / 'migrations/project1_ai/20261121_04_execution_mode_rollback.sql'
RECEIPT = ("SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; "
           "SET project1.m2_bcb_migration_receipt='EXEC-MODE-CHECK-ONLY';")
STANDIN = """
CREATE SCHEMA project1_ai;
CREATE TABLE project1_ai.bdj_results (result_id uuid PRIMARY KEY, model_returned text);
INSERT INTO project1_ai.bdj_results VALUES (gen_random_uuid(), NULL), (gen_random_uuid(), 'm');
"""


def main() -> int:
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    lab = Path(tempfile.mkdtemp(prefix='project1_em_'))
    env = {**os.environ, 'PGHOST': '127.0.0.1', 'PGPORT': str(port),
           'PGUSER': 'postgres', 'PGDATABASE': 'postgres'}
    res: list[tuple[str, bool, str]] = []

    def psql(*a, db='project1_m2_bcb_test'):
        return subprocess.run([str(BIN / 'psql.exe'), '-X', '-q', '-w', '-v', 'ON_ERROR_STOP=1',
                               '-d', db, *a], env=env, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=120)

    started = False
    try:
        subprocess.run([str(BIN / 'initdb.exe'), '-D', str(lab / 'data'), '-U', 'postgres',
                        '--encoding=UTF8', '--locale=C', '-A', 'trust'],
                       capture_output=True, check=True, stdin=subprocess.DEVNULL, timeout=180)
        subprocess.run([str(BIN / 'pg_ctl.exe'), '-D', str(lab / 'data'), '-l', str(lab / 'pg.log'),
                        '-o', f'-h 127.0.0.1 -p {port}', '-w', 'start'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True,
                       stdin=subprocess.DEVNULL, timeout=120)
        started = True
        psql('-c', 'CREATE DATABASE project1_m2_bcb_test', db='postgres')
        psql('-c', STANDIN)
        r = psql('-c', RECEIPT, '-f', str(MIG))
        res.append(('forward migration applies', r.returncode == 0, r.stderr.strip()[:200]))
        if r.returncode != 0:
            raise SystemExit('forward failed: ' + (r.stderr or '')[:600])

        import psycopg2
        conn = psycopg2.connect(host='127.0.0.1', port=port, user='postgres',
                                dbname='project1_m2_bcb_test')
        conn.autocommit = True
        cur = conn.cursor()

        cur.execute("SELECT execution_mode, provider_dispatched FROM project1_ai.bdj_results "
                    "ORDER BY model_returned NULLS FIRST")
        rows = cur.fetchall()
        res.append(('legacy backfill: no model -> DETERMINISTIC',
                    rows[0] == ('DETERMINISTIC_RULE_EVALUATION', False), str(rows[0])))
        res.append(('legacy backfill: model recorded -> MOCKED',
                    rows[1] == ('MOCKED_PROVIDER_TEST', False), str(rows[1])))

        def expect(name, sql, code):
            try:
                cur.execute(sql)
                res.append((name, False, 'accepted (should have been refused)'))
            except psycopg2.Error as exc:
                res.append((name, getattr(exc, 'pgcode', None) == code,
                            f'{getattr(exc, "pgcode", None)}'))

        expect('unknown mode refused',
               "INSERT INTO project1_ai.bdj_results VALUES "
               "(gen_random_uuid(),'m','NOT_A_MODE',false,NULL)", '23514')
        expect('LIVE without dispatch refused',
               "INSERT INTO project1_ai.bdj_results VALUES "
               "(gen_random_uuid(),'m','LIVE_PROVIDER_EXECUTION',false,NULL)", '23514')
        expect('dispatch without LIVE refused',
               "INSERT INTO project1_ai.bdj_results VALUES "
               "(gen_random_uuid(),'m','MOCKED_PROVIDER_TEST',true,NULL)", '23514')

        cur.execute("INSERT INTO project1_ai.bdj_results VALUES "
                    "(gen_random_uuid(),'m','LIVE_PROVIDER_EXECUTION',true,200)")
        res.append(('valid LIVE row accepted', True, ''))

        r = psql('-c', RECEIPT, '-f', str(ROLLBACK))
        res.append(('rollback refuses with a LIVE row',
                    r.returncode != 0 and 'LIVE_PROVIDER_EXECUTION' in (r.stderr or ''),
                    (r.stderr or '').strip().splitlines()[0][:100] if r.stderr else ''))
        conn.close()
    finally:
        if started:
            subprocess.run([str(BIN / 'pg_ctl.exe'), '-D', str(lab / 'data'), '-m', 'immediate',
                            '-w', 'stop'], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, timeout=120)
        shutil.rmtree(lab, ignore_errors=True)

    width = max(len(n) for n, _, _ in res)
    for name, ok, detail in res:
        print(f'{"PASS" if ok else "FAIL"}  {name.ljust(width)}  {detail}')
    passed = sum(1 for _, ok, _ in res if ok)
    print(f'\n{passed}/{len(res)} checks passed')
    ok = passed == len(res)
    print('VERDICT: ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
