"""Verify the proposed S1 migration against a throwaway PostgreSQL cluster.

Proves: forward applies; a review row is accepted; a second decision for the same
(confirmation, finding) is refused; an UPDATE is refused as append-only; the
rollback refuses while a decision exists; and it applies once cleared.

Run: backend/.venv/Scripts/python.exe -B tools/bdj_output_verification/check_s1_migration.py
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(r'C:\Program Files\PostgreSQL\18\bin')
MIG = ROOT / 'migrations/m2/20261121_03_finding_reviews.sql'
ROLLBACK = ROOT / 'migrations/m2/20261121_03_finding_reviews_rollback.sql'
FIXTURE = ROOT / 'tests/m2_bcb/fixtures/dss_m2_schema_20261113.sql'
RECEIPT = ("SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; "
           "SET project1.m2_bcb_migration_receipt='S1-DRAFT-CHECK-ONLY';")
REVIEW = ("INSERT INTO public.m2_finding_reviews "
          "(id, finding_id, assessment_id, assessment_revision, confirmation_id, "
          " actor_user_id, decision, finding_hash, request_id) "
          "VALUES (%s,%s,%s,11,%s,%s,'WORTH_RESEARCHING',%s,%s)")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def main() -> int:
    port, lab = free_port(), Path(tempfile.mkdtemp(prefix='project1_s1_'))
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
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       check=True, stdin=subprocess.DEVNULL, timeout=120)
        started = True
        psql('-c', 'CREATE DATABASE project1_m2_bcb_test', db='postgres')
        psql('-f', str(FIXTURE))
        # The runtime role is normally created by run_isolated.py; the migration
        # grants to it, so it must exist here too.
        psql('-c', 'CREATE ROLE p1_m2_runtime LOGIN NOINHERIT NOSUPERUSER '
                   'NOCREATEDB NOCREATEROLE NOBYPASSRLS')
        r = psql('-c', RECEIPT, '-f', str(MIG))
        res.append(('forward migration applies', r.returncode == 0, r.stderr.strip()[:150]))
        if r.returncode != 0:
            raise SystemExit('forward failed: ' + (r.stderr or r.stdout or '')[:800])

        import psycopg2
        conn = psycopg2.connect(host='127.0.0.1', port=port, user='postgres',
                                dbname='project1_m2_bcb_test')
        conn.autocommit = True
        cur = conn.cursor()
        owner, iid, aid, cid, fid = (str(uuid4()) for _ in range(5))
        cur.execute("INSERT INTO public.users (user_id,email,role,account_status,email_verified,"
                    "created_at,updated_at) VALUES (%s,'s1@test.invalid','entrepreneur','ACTIVE',"
                    "true,now(),now())", (owner,))
        cur.execute("INSERT INTO public.m2_instrument_versions (id,code,version_tag,approval_state,"
                    "schema_digest) VALUES (%s,'M2V1','M2V1-20261114-1','AUTHORIZED',%s)",
                    (iid, 'a' * 64))
        cur.execute("INSERT INTO public.m2_assessments (id,owner_user_id,instrument_id,revision) "
                    "VALUES (%s,%s,%s,11)", (aid, owner, iid))
        cur.execute("INSERT INTO public.m2_confirmation_snapshots (id,assessment_id,"
                    "assessment_revision,actor_user_id,snapshot_json,snapshot_digest,"
                    "acknowledged_issue_ids) VALUES (%s,%s,11,%s,'{}'::json,%s,'[]'::json)",
                    (cid, aid, owner, 'b' * 64))
        cur.execute("INSERT INTO public.m2_bdj_findings (id,assessment_id,assessment_revision,"
                    "rule_id,rule_version,source_answer_ids,issue_type,explanation,not_proven,"
                    "next_action,review_state) VALUES (%s,%s,11,'R','V','[]'::json,'INFORMATION_GAP',"
                    "'x','x','x','CANDIDATE')", (fid, aid))

        cur.execute(REVIEW, (str(uuid4()), fid, aid, cid, owner, 'c' * 64, str(uuid4())))
        res.append(('review row accepted', True, ''))

        try:
            cur.execute(REVIEW, (str(uuid4()), fid, aid, cid, owner, 'c' * 64, str(uuid4())))
            res.append(('second decision refused', False, 'insert succeeded'))
        except psycopg2.errors.UniqueViolation as exc:
            res.append(('second decision refused', exc.pgcode == '23505', exc.pgcode))

        try:
            cur.execute("UPDATE public.m2_finding_reviews SET decision='WORTH_RESEARCHING'")
            res.append(('update refused (append-only)', False, 'update succeeded'))
        except psycopg2.Error as exc:
            res.append(('update refused (append-only)',
                        getattr(exc, 'pgcode', None) == '55000',
                        f'{getattr(exc, "pgcode", None)} {str(exc).splitlines()[0][:60]}'))

        r = psql('-c', RECEIPT, '-f', str(ROLLBACK))
        res.append(('rollback refuses with a decision present',
                    r.returncode != 0 and 'would be destroyed' in (r.stderr or ''),
                    (r.stderr or '').strip().splitlines()[0][:110] if r.stderr else ''))

        cur.execute("SET session_replication_role = replica")
        cur.execute("DELETE FROM public.m2_finding_reviews")
        cur.execute("SET session_replication_role = origin")
        r = psql('-c', RECEIPT, '-f', str(ROLLBACK))
        res.append(('rollback applies once cleared', r.returncode == 0, r.stderr.strip()[:150]))
        if r.returncode == 0:
            cur.execute("SELECT to_regclass('public.m2_finding_reviews')")
            res.append(('table dropped', cur.fetchone()[0] is None, ''))
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
