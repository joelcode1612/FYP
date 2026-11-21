"""Verify the proposed D3 migration against a throwaway PostgreSQL cluster.

Proves, in order:
  1. the forward migration applies to a copy of the M2 schema;
  2. two findings from ONE rule with DIFFERENT sources are now accepted;
  3. replaying the SAME execution is still refused with 23505 (idempotent);
  4. the rollback REFUSES while a duplicate rule/revision group exists;
  5. after clearing that group the rollback applies and the 4-column key returns.

Nothing here touches Dss. The cluster is created in a temp directory and
destroyed at the end.

Run:
    backend/.venv/Scripts/python.exe -B tools/bdj_output_verification/check_d3_migration.py
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(r'C:\Program Files\PostgreSQL\18\bin')
MIGRATION = ROOT / 'migrations/m2/20261121_02_finding_source_identity.sql'
ROLLBACK = ROOT / 'migrations/m2/20261121_02_finding_source_identity_rollback.sql'
FIXTURE = ROOT / 'tests/m2_bcb/fixtures/dss_m2_schema_20261113.sql'
RECEIPT = ("SET project1.m2_bcb_migration_target='project1_m2_bcb_test'; "
           "SET project1.m2_bcb_migration_receipt='D3-DRAFT-CHECK-ONLY';")
INSERT = ("INSERT INTO public.m2_bdj_findings "
          "(id, assessment_id, assessment_revision, rule_id, rule_version, "
          " source_answer_ids, issue_type, explanation, not_proven, next_action, review_state) "
          "VALUES (%s,%s,11,'M2V1_EXPLICIT_PLANNING_UNDECIDED','BDJ-M2V1-IG-0.1-PROP',"
          "%s::json,'INFORMATION_GAP','x','x','x','CANDIDATE')")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def main() -> int:
    for name in ('initdb.exe', 'pg_ctl.exe', 'psql.exe'):
        if not (BIN / name).is_file():
            print(f'MISSING {BIN / name}')
            return 2

    port = free_port()
    lab = Path(tempfile.mkdtemp(prefix='project1_d3_'))
    env = {**os.environ, 'PGHOST': '127.0.0.1', 'PGPORT': str(port),
           'PGUSER': 'postgres', 'PGDATABASE': 'postgres'}
    results: list[tuple[str, bool, str]] = []

    def psql(*args: str, db: str = 'project1_m2_bcb_test') -> subprocess.CompletedProcess:
        # -w: never prompt for a password (a prompt would block forever with no TTY).
        return subprocess.run([str(BIN / 'psql.exe'), '-X', '-q', '-w', '-v', 'ON_ERROR_STOP=1',
                               '-d', db, *args], env=env, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=120)

    def step(name: str) -> None:
        print(f'... {name}', flush=True)

    started = False
    try:
        step('initdb')
        subprocess.run([str(BIN / 'initdb.exe'), '-D', str(lab / 'data'), '-U', 'postgres',
                        '--encoding=UTF8', '--locale=C', '-A', 'trust'],
                       capture_output=True, check=True, stdin=subprocess.DEVNULL, timeout=180)
        step(f'pg_ctl start on {port}')
        # NOT capture_output: pg_ctl launches postgres, which inherits the pipes and
        # never closes them, so a captured run waits for EOF forever. The server's
        # own output goes to -l pg.log.
        subprocess.run([str(BIN / 'pg_ctl.exe'), '-D', str(lab / 'data'),
                        '-l', str(lab / 'pg.log'), '-o', f'-h 127.0.0.1 -p {port}',
                        '-w', 'start'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       check=True, stdin=subprocess.DEVNULL, timeout=120)
        started = True
        step('create database')
        psql('-c', 'CREATE DATABASE project1_m2_bcb_test', db='postgres')
        step('apply schema fixture')
        r = psql('-f', str(FIXTURE))
        results.append(('schema fixture applies', r.returncode == 0, r.stderr.strip()[:120]))

        # --- 1. forward ------------------------------------------------------
        step('apply forward migration')
        r = psql('-c', RECEIPT, '-f', str(MIGRATION))
        results.append(('forward migration applies', r.returncode == 0, r.stderr.strip()[:160]))
        if r.returncode != 0:
            raise SystemExit('forward failed; stopping')

        import psycopg2
        conn = psycopg2.connect(host='127.0.0.1', port=port, user='postgres',
                                dbname='project1_m2_bcb_test')
        conn.autocommit = True
        cur = conn.cursor()
        iid, aid, owner = str(uuid4()), str(uuid4()), str(uuid4())
        cur.execute("INSERT INTO public.users "
                    "(user_id, email, role, account_status, email_verified, "
                    " created_at, updated_at) "
                    "VALUES (%s,'d3@test.invalid','entrepreneur','ACTIVE',true,now(),now())",
                    (owner,))
        cur.execute("INSERT INTO public.m2_instrument_versions "
                    "(id, code, version_tag, approval_state, schema_digest) "
                    "VALUES (%s,'M2V1','M2V1-20261114-1','AUTHORIZED',%s)", (iid, 'a' * 64))
        cur.execute("INSERT INTO public.m2_assessments "
                    "(id, owner_user_id, instrument_id, revision) VALUES (%s,%s,%s,11)",
                    (aid, owner, iid))

        # --- 2. two findings, one rule, different sources --------------------
        cur.execute(INSERT, (str(uuid4()), aid, json.dumps(['ans-01'])))
        cur.execute(INSERT, (str(uuid4()), aid, json.dumps(['ans-02'])))
        cur.execute("SELECT count(*), count(DISTINCT source_identity) FROM public.m2_bdj_findings")
        total, distinct = cur.fetchone()
        results.append(('two sources from one rule accepted', total == 2 and distinct == 2,
                        f'rows={total} identities={distinct}'))

        # --- 3. same execution replayed --------------------------------------
        try:
            cur.execute(INSERT, (str(uuid4()), aid, json.dumps(['ans-01'])))
            results.append(('replay refused (idempotent)', False, 'second insert succeeded'))
        except psycopg2.errors.UniqueViolation as exc:
            results.append(('replay refused (idempotent)', exc.pgcode == '23505', exc.pgcode))

        # --- 4. rollback must refuse -----------------------------------------
        r = psql('-c', RECEIPT, '-f', str(ROLLBACK))
        refused = r.returncode != 0 and 'multiple findings' in (r.stderr or '')
        results.append(('rollback refuses on duplicate group', refused,
                        (r.stderr or '').strip().splitlines()[0][:120] if r.stderr else ''))

        # --- 5. clear the group, rollback must apply -------------------------
        cur.execute("SET session_replication_role = replica")
        cur.execute("DELETE FROM public.m2_bdj_findings WHERE id IN "
                    "(SELECT id FROM public.m2_bdj_findings "
                    " ORDER BY id LIMIT 1)")
        cur.execute("SET session_replication_role = origin")
        r = psql('-c', RECEIPT, '-f', str(ROLLBACK))
        results.append(('rollback applies once cleared', r.returncode == 0,
                        r.stderr.strip()[:160]))
        if r.returncode == 0:
            cur.execute("SELECT conname FROM pg_constraint "
                        "WHERE conrelid='public.m2_bdj_findings'::regclass AND contype='u'")
            names = [row[0] for row in cur.fetchall()]
            cur.execute("SELECT count(*) FROM information_schema.columns "
                        "WHERE table_schema='public' AND table_name='m2_bdj_findings' "
                        "AND column_name='source_identity'")
            gone = cur.fetchone()[0] == 0
            results.append(('old key restored, column dropped',
                            'uq_m2_bdj_rule_revision' in names and gone, str(names)))
        conn.close()
    finally:
        if started:
            subprocess.run([str(BIN / 'pg_ctl.exe'), '-D', str(lab / 'data'),
                            '-m', 'immediate', '-w', 'stop'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           stdin=subprocess.DEVNULL, timeout=120)
        shutil.rmtree(lab, ignore_errors=True)

    width = max(len(n) for n, _, _ in results)
    for name, ok, detail in results:
        print(f'{"PASS" if ok else "FAIL"}  {name.ljust(width)}  {detail}')
    passed = sum(1 for _, ok, _ in results if ok)
    print(f'\n{passed}/{len(results)} checks passed')
    ok = passed == len(results)
    print('VERDICT: ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
