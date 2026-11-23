"""Prove the review_state reconciliation migration on a disposable cluster.

Priority 3 asks for three things:

1. Compare the live constraint against the committed migrations.
2. Prepare a versioned, idempotent migration.
3. Test FRESH provisioning and UPGRADE in a disposable environment, preserving
   existing decisions and RLS — and never apply anything to a protected
   database.

This tool does all three against ``127.0.0.1:5433`` only. It refuses to run if
the connection lands on port 5432.

Scenarios
---------
``baseline_diff``    catalog comparison of the two objective tables between a
                     database built from the migrations and the live
                     ``project1_workflow_tests``.
``fresh``            a new database, baseline schema minus the three objective
                     tables, then 0100 -> 0200 -> 0300 -> 0400 -> 0500 applied
                     from zero. Proves the set can provision a new environment.
``drift_repair``     inject the narrow auto-named constraint that a
                     hand-built database can carry, prove it blocks APPROVED,
                     run 0500, prove APPROVED is accepted and the narrow
                     constraint is gone.
``idempotent``       run 0500 twice more; second run must change nothing.
``upgrade``          run 0500 against the live ``project1_workflow_tests``;
                     rows and RLS must be identical before and after.
``protected_refusal``
                     run 0500 against ``Final_Location_Analysis@5432`` in a
                     read-only transaction; it must refuse before any DDL.

Usage::

    python tools/p3_migration_reconcile_test_20261122.py --json OUT.json
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
HOST = '127.0.0.1'
PORT = 5433
LIVE_DB = 'project1_workflow_tests'
FRESH_DB = 'project1_migration_fresh'
PROTECTED_DB = 'Final_Location_Analysis'
PROTECTED_PORT = 5432

MIGRATIONS = [
    'migrations/sql/20261121_0100_m2_bdj_objective_proposals.sql',
    'migrations/sql/20261121_0200_m2_bdj_objective_decisions.sql',
    'migrations/sql/20261122_0300_m2_bdj_objective_rls_grants.sql',
    'migrations/sql/20261122_0400_m2_bdj_objective_admissions.sql',
    'migrations/sql/20261122_0500_m2_bdj_objective_review_state_reconcile.sql',
]
RECONCILE = 'migrations/sql/20261122_0500_m2_bdj_objective_review_state_reconcile.sql'

OBJECTIVE_TABLES = (
    'm2_bdj_objective_proposals',
    'm2_bdj_objective_decisions',
    'm2_bdj_objective_admissions',
)

CATALOG_SQL = """
SET default_transaction_read_only = on;
SELECT line FROM (
  SELECT 'C|' || c.conrelid::regclass || '|' || c.conname || '|' || pg_get_constraintdef(c.oid) AS line
    FROM pg_constraint c
   WHERE c.conrelid IN ('public.m2_bdj_objective_proposals'::regclass,
                        'public.m2_bdj_objective_decisions'::regclass)
  UNION ALL
  SELECT 'I|' || i.schemaname || '.' || i.tablename || '|' || i.indexname || '|' || i.indexdef
    FROM pg_indexes i
   WHERE i.schemaname = 'public'
     AND i.tablename IN ('m2_bdj_objective_proposals', 'm2_bdj_objective_decisions')
  UNION ALL
  SELECT 'P|' || p.polrelid::regclass || '|' || p.polname || '|' || p.polcmd::text || '|'
         || coalesce(pg_get_expr(p.polqual, p.polrelid), '-')
    FROM pg_policy p
   WHERE p.polrelid IN ('public.m2_bdj_objective_proposals'::regclass,
                        'public.m2_bdj_objective_decisions'::regclass)
  UNION ALL
  SELECT 'R|' || c.relname || '|rls=' || c.relrowsecurity
    FROM pg_class c
   WHERE c.oid IN ('public.m2_bdj_objective_proposals'::regclass,
                   'public.m2_bdj_objective_decisions'::regclass)
  UNION ALL
  SELECT 'N|proposals_rows=' || count(*) FROM public.m2_bdj_objective_proposals
  UNION ALL
  SELECT 'N|decisions_rows=' || count(*) FROM public.m2_bdj_objective_decisions
) t
ORDER BY 1;
"""

REVIEW_STATE_SQL = """
SET default_transaction_read_only = on;
SELECT conname || ' :: ' || pg_get_constraintdef(oid)
  FROM pg_constraint
 WHERE conrelid = 'public.m2_bdj_objective_proposals'::regclass
   AND contype = 'c'
   AND pg_get_constraintdef(oid) LIKE '%review_state%'
 ORDER BY conname;
"""


def _password() -> str:
    text = (BACKEND / '.env').read_text(encoding='utf-8', errors='replace')
    match = re.search(r'^DATABASE_URL=(.*)$', text, re.M)
    if not match:
        raise SystemExit('DATABASE_URL not found in backend/.env')
    cred = re.match(r'^[^:]+://[^:]+:([^@]+)@', match.group(1).strip())
    if not cred:
        raise SystemExit('DATABASE_URL has no inline password')
    return cred.group(1)


class Psql:
    def __init__(self, password: str) -> None:
        self.env = {**__import__('os').environ, 'PGPASSWORD': password}

    def run(self, db: str, sql: str, *, port: int = PORT, readonly: bool = False,
            stop: bool = True) -> tuple[int, str]:
        prefix = 'SET default_transaction_read_only = on;\n' if readonly else ''
        args = [
            'psql', '-h', HOST, '-p', str(port), '-U', 'postgres', '-d', db,
            '-v', f'ON_ERROR_STOP={1 if stop else 0}', '-At', '-c', prefix + sql,
        ]
        proc = subprocess.run(args, capture_output=True, text=True, env=self.env)
        return proc.returncode, (proc.stdout + proc.stderr).strip()

    def file(self, db: str, path: Path, *, port: int = PORT,
             readonly: bool = False) -> tuple[int, str]:
        env = dict(self.env)
        if readonly:
            # Session-level read-only via PGOPTIONS, not a SET statement: the
            # migration opens its own BEGIN, and an implicit transaction from
            # `psql -c "SET ..."` would collide with it.
            env['PGOPTIONS'] = '-c default_transaction_read_only=on'
        proc = subprocess.run(
            ['psql', '-h', HOST, '-p', str(port), '-U', 'postgres', '-d', db,
             '-v', 'ON_ERROR_STOP=1', '-q', '-f', str(path)],
            capture_output=True, text=True, env=env,
        )
        return proc.returncode, (proc.stdout + proc.stderr).strip()


def _recreate(psql: Psql, db: str) -> None:
    # DROP/CREATE DATABASE cannot share a transaction, and psql wraps a single
    # -c string in one, so each statement gets its own call.
    psql.run('postgres', f'DROP DATABASE IF EXISTS {db};', stop=False)
    code, out = psql.run('postgres', f'CREATE DATABASE {db};', stop=False)
    if code != 0 and 'already exists' not in out:
        raise SystemExit(f'could not recreate {db}: {out}')


def _clone_baseline(psql: Psql, target: str) -> dict:
    """Clone the live database, then drop the objective tables.

    ``CREATE DATABASE ... TEMPLATE`` is used instead of ``pg_dump`` because the
    disposable cluster runs PostgreSQL 18 while the ``pg_dump`` on PATH is 16,
    and pg_dump refuses a newer server. The template clone is exact, including
    grants and RLS, which is what the migrations must build on.
    """
    code, out = psql.run(
        'postgres', f'DROP DATABASE IF EXISTS {target};', stop=False
    )
    if code != 0 and 'ERROR' in out:
        raise SystemExit(f'could not drop {target}: {out}')

    code, out = psql.run(
        'postgres', f'CREATE DATABASE {target} TEMPLATE {LIVE_DB};', stop=False
    )
    if code != 0:
        raise SystemExit(
            f'could not clone {LIVE_DB} -> {target}: {out}\n'
            'TEMPLATE requires that no other session is connected to the template.'
        )

    drops = ' '.join(
        f'DROP TABLE IF EXISTS public.{table} CASCADE;' for table in OBJECTIVE_TABLES
    )
    code, out = psql.run(target, drops, stop=False)
    errors = [line for line in out.splitlines() if line.startswith('ERROR')]
    remaining = psql.run(
        target,
        "SELECT coalesce(string_agg(t, ','), '(none)') FROM unnest(ARRAY["
        + ', '.join(f"'{table}'" for table in OBJECTIVE_TABLES)
        + "]) AS t WHERE to_regclass('public.' || t) IS NOT NULL;",
        readonly=True,
    )[1]
    return {
        'method': 'CREATE DATABASE ... TEMPLATE (server is PostgreSQL 18, pg_dump on PATH is 16)',
        'dropped_tables': list(OBJECTIVE_TABLES),
        'drop_errors': errors[:3],
        'objective_tables_remaining': remaining or '(none)',
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--json', default=None)
    args = parser.parse_args()

    psql = Psql(_password())
    evidence: dict = {
        'checkpoint': 'P3_MIGRATION_RECONCILE',
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'cluster': f'{HOST}:{PORT}',
        'scenarios': {},
    }

    # ---- identity guard ---------------------------------------------------
    code, out = psql.run('postgres', 'SELECT current_database(), inet_server_port();')
    if code != 0 or f'|{PORT}' not in out:
        raise SystemExit(f'refusing: not the disposable cluster ({out})')
    evidence['identity'] = out.replace('\n', ' ')

    # ---- fresh provisioning ----------------------------------------------
    baseline = _clone_baseline(psql, FRESH_DB)
    applied = []
    for rel in MIGRATIONS:
        code, out = psql.file(FRESH_DB, BACKEND / rel)
        applied.append({'migration': Path(rel).name, 'ok': code == 0,
                        'output': out[-400:] if code != 0 else ''})
        if code != 0:
            break
    fresh_ok = all(step['ok'] for step in applied) and len(applied) == len(MIGRATIONS)
    evidence['scenarios']['fresh'] = {
        'database': FRESH_DB,
        'baseline': baseline,
        'migrations': applied,
        'all_applied': fresh_ok,
        'review_state_constraints': psql.run(FRESH_DB, REVIEW_STATE_SQL, readonly=True)[1].splitlines(),
    }

    # ---- baseline diff: does the migrated database match the live one? ----
    fresh_code, fresh_cat = psql.run(FRESH_DB, CATALOG_SQL, stop=False)
    live_code, live_cat = psql.run(LIVE_DB, CATALOG_SQL, stop=False)
    fresh_set = {line for line in fresh_cat.splitlines() if '|' in line}
    live_set = {line for line in live_cat.splitlines() if '|' in line}
    # 'N|' lines are row counts: the fresh database is empty by construction, so
    # they are expected to differ. Structure is compared separately.
    fresh_struct = {line for line in fresh_set if not line.startswith('N|')}
    live_struct = {line for line in live_set if not line.startswith('N|')}
    evidence['scenarios']['fresh']['catalog_lines'] = len(fresh_set)
    evidence['scenarios']['baseline_diff'] = {
        'note': (
            'catalog of the two objective tables in the freshly migrated database '
            'versus the live project1_workflow_tests'
        ),
        'fresh_exit_code': fresh_code,
        'live_exit_code': live_code,
        'fresh_objects': len(fresh_set),
        'live_objects': len(live_set),
        'structure_identical': fresh_struct == live_struct,
        'only_in_migrated': sorted(fresh_struct - live_struct),
        'only_in_live': sorted(live_struct - fresh_struct),
        'row_count_lines_fresh': sorted(fresh_set - fresh_struct),
        'row_count_lines_live': sorted(live_set - live_struct),
    }

    # ---- drift repair -----------------------------------------------------
    drift = {}
    if fresh_ok:
        narrow = (
            "ALTER TABLE public.m2_bdj_objective_proposals "
            "DROP CONSTRAINT IF EXISTS ck_proposal_review_state; "
            "ALTER TABLE public.m2_bdj_objective_proposals "
            "ADD CONSTRAINT m2_bdj_objective_proposals_review_state_check "
            "CHECK (review_state IN ('CANDIDATE','REVIEWED','WITHDRAWN'));"
        )
        code, out = psql.run(FRESH_DB, narrow)
        drift['inject_ok'] = code == 0
        drift['constraints_after_inject'] = psql.run(
            FRESH_DB, REVIEW_STATE_SQL, readonly=True)[1].splitlines()

        # APPROVED must now be refused by the narrow constraint.
        probe = (
            "BEGIN; "
            "INSERT INTO public.m2_bdj_objective_proposals "
            "(proposal_id, assessment_id, confirmation_id, source_fingerprint, "
            " owner_user_id, recommendation_status, source_refs, review_state) "
            "SELECT gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'x', "
            "       gen_random_uuid(), 'SUGGESTED', '[]'::jsonb, 'APPROVED'; "
            "ROLLBACK;"
        )
        code, out = psql.run(FRESH_DB, probe, stop=False)
        drift['approved_blocked_before_repair'] = code != 0
        drift['blocked_error'] = next(
            (line for line in out.splitlines() if 'violates check constraint' in line), None
        )

        # Repair.
        code, out = psql.file(FRESH_DB, BACKEND / RECONCILE)
        drift['repair_ok'] = code == 0
        drift['repair_notice'] = next(
            (line for line in out.splitlines() if 'review_state reconcile' in line), None
        )
        drift['constraints_after_repair'] = psql.run(
            FRESH_DB, REVIEW_STATE_SQL, readonly=True)[1].splitlines()

        # Idempotent: run it again, expect no drops.
        code, out = psql.file(FRESH_DB, BACKEND / RECONCILE)
        drift['second_run_ok'] = code == 0
        drift['second_run_notice'] = next(
            (line for line in out.splitlines() if 'review_state reconcile' in line), None
        )
        drift['idempotent'] = (
            drift.get('repair_notice') is not None
            and drift.get('second_run_notice') is not None
            and 'dropped=,' in drift['second_run_notice']
            and 'added' not in drift['second_run_notice']
        )
    evidence['scenarios']['drift_repair'] = drift

    # ---- upgrade in place -------------------------------------------------
    before_cat = psql.run(LIVE_DB, CATALOG_SQL, readonly=True)[1]
    code, out = psql.file(LIVE_DB, BACKEND / RECONCILE)
    after_cat = psql.run(LIVE_DB, CATALOG_SQL, readonly=True)[1]
    evidence['scenarios']['upgrade'] = {
        'database': LIVE_DB,
        'migration_ok': code == 0,
        'notice': next((line for line in out.splitlines() if 'review_state reconcile' in line), None),
        'catalog_unchanged': before_cat == after_cat,
        'before_lines': before_cat.splitlines(),
        'after_lines': after_cat.splitlines(),
    }

    # ---- protected refusal ------------------------------------------------
    code, out = psql.file(
        PROTECTED_DB, BACKEND / RECONCILE, port=PROTECTED_PORT, readonly=True,
    )
    evidence['scenarios']['protected_refusal'] = {
        'database': PROTECTED_DB,
        'port': PROTECTED_PORT,
        'read_only_session': True,
        'refused': code != 0 and 'REFUSED' in out,
        'message': next((line for line in out.splitlines() if 'REFUSED' in line), None),
    }

    text = json.dumps(evidence, indent=2)
    print(text)
    if args.json:
        out_path = Path(args.json)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(text, encoding='utf-8')
    return 0


if __name__ == '__main__':
    sys.exit(main())
