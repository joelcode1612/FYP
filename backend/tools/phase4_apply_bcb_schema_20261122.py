"""Apply the BCB research-workspace schema chain to the disposable database only.

Order is a real dependency chain, not a guess -- each step below refuses to run
until its predecessor's objects exist:

    cp12 base function  ->  20261114_02 (the five research tables)
    20261115_01         ->  20261115_02 (projection objects the grants target)
    20261117_04         ->  20261117_05  ->  20261118_06 (grants + RLS policies)

``public.m2_bcb_reject_mutation()`` normally comes from ``migrations/cp12/dss_up.sql``,
which also creates the whole CP-12 discard schema. Only the function is needed
here: the research tables use it purely as an append-only guard. It is installed
verbatim, and its ``cp12``-dependent branch is short-circuited for every UPDATE
and for DELETE on any table other than the two draft tables, so the absent
``cp12`` schema is never touched on these tables.

Every guard variable the migrations require is set at session scope before the
file runs, because each file opens its own transaction.

Refuses to run anywhere except 127.0.0.1:5433/project1_workflow_tests.

Run from ``backend/``::

    python tools/phase4_apply_bcb_schema_20261122.py --confirm
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

import psycopg2

BACKEND = pathlib.Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
OUT = REPO / 'deliverables' / 'phase4' / 'bcb_schema_apply.json'

HOST, PORT, DB = '127.0.0.1', 5433, 'project1_workflow_tests'
RECEIPT = 'project1-p4-bcb-schema-20261122'

CHAIN = [
    'migrations/m2/20261114_02_research_objective_sources.sql',
    'migrations/m2/20261115_01_candidate_owner_review.sql',
    'migrations/m2/20261115_02_workflow_projection.sql',
    'migrations/m2/20261117_04_workflow_trigger_grant.sql',
    'migrations/m2/20261117_05_workflow_view_read_scope.sql',
    'migrations/m2/20261118_06_research_objective_write.sql',
]


def password() -> str:
    text = (BACKEND / '.env').read_text(encoding='utf-8')
    return re.search(r'^DATABASE_URL=.*://[^:]+:([^@]+)@', text, re.M).group(1)


def connect():
    return psycopg2.connect(host=HOST, port=PORT, user='postgres',
                            password=password(), dbname=DB)


def assert_identity(cur) -> dict:
    cur.execute("SELECT current_database(), inet_server_port(), version()")
    db, port, version = cur.fetchone()
    if db != DB or port != PORT:
        raise SystemExit(f'REFUSED: connected to {db}@{port}, expected {DB}@{PORT}')
    if db in ('Dss', 'Final_Location_Analysis'):
        raise SystemExit('REFUSED: protected database')
    cur.execute("SELECT count(*) FROM public.m2_assessments")
    return {'database': db, 'port': port,
            'server_version': version.split(' ')[1],
            'm2_assessments_rows': cur.fetchone()[0]}


def reject_mutation_sql() -> str:
    """The exact function body from the CP-12 base schema, nothing added."""
    text = (BACKEND / 'migrations/cp12/dss_up.sql').read_text(encoding='utf-8')
    match = re.search(
        r'CREATE OR REPLACE FUNCTION public\.m2_bcb_reject_mutation\(\).*?\nEND \$\$;',
        text, re.S)
    if not match:
        raise SystemExit('could not extract m2_bcb_reject_mutation from dss_up.sql')
    return match.group(0)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--confirm', action='store_true',
                    help='actually apply; without it this is a dry run')
    args = ap.parse_args()

    conn = connect()
    conn.autocommit = True
    cur = conn.cursor()
    report: dict = {'identity': assert_identity(cur), 'steps': []}

    if not args.confirm:
        print(json.dumps(report['identity'], indent=1))
        print('\nDRY RUN -- chain that would be applied:')
        for f in ['migrations/cp12/dss_up.sql#m2_bcb_reject_mutation'] + CHAIN:
            print('  ', f)
        conn.close()
        return 0

    # Guard variables are session-scoped: each migration file opens its own
    # transaction, so a SET LOCAL issued here would be gone by the time the
    # file's DO block evaluates current_setting().
    cur.execute(f"SET project1.m2_bcb_migration_target = '{DB}'")
    cur.execute(f"SET project1.m2_bcb_migration_receipt = '{RECEIPT}'")

    # 1. the append-only guard function
    try:
        cur.execute(reject_mutation_sql())
        report['steps'].append({'step': 'public.m2_bcb_reject_mutation()',
                                'verdict': 'APPLIED'})
    except Exception as exc:  # noqa: BLE001
        report['steps'].append({'step': 'public.m2_bcb_reject_mutation()',
                                'verdict': 'FAILED', 'error': str(exc)[:300]})

    # 2. the chain, in dependency order
    for rel in CHAIN:
        sql = (BACKEND / rel).read_text(encoding='utf-8')
        try:
            cur.execute(sql)
            report['steps'].append({'step': rel, 'verdict': 'APPLIED'})
        except Exception as exc:  # noqa: BLE001
            conn.rollback()
            report['steps'].append({'step': rel, 'verdict': 'FAILED',
                                    'error': str(exc).strip().splitlines()[0][:300]})

    # 3. what the research workspace actually needs
    cur.execute("""
        SELECT n, CASE WHEN to_regclass('public.'||n) IS NULL THEN 'MISSING'
                       ELSE 'present' END
        FROM unnest(ARRAY['m2_research_objective_sources','m2_research_clarifications',
                          'm2_research_revisions','m2_review_question_versions',
                          'm2_desired_options']) AS n
    """)
    report['tables'] = dict(cur.fetchall())
    cur.execute("""
        SELECT p.proname, has_function_privilege('p1_m2_runtime', p.oid, 'EXECUTE')
        FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='public' AND p.proname='m2_bcb_reject_mutation'
    """)
    report['reject_function'] = dict(cur.fetchall())

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(report, indent=2), encoding='utf-8')
    conn.close()

    print(json.dumps(report['identity'], indent=1))
    for s in report['steps']:
        print(f'  [{s["verdict"]}] {s["step"]}')
        if s.get('error'):
            print(f'           {s["error"]}')
    print('\ntables:', report['tables'])
    print('wrote', OUT)
    return 0


if __name__ == '__main__':
    sys.exit(main())
