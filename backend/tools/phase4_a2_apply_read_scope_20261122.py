"""Phase A2 — apply the Research Workspace read-scope compatibility migration.

Applies exactly one file, `migrations/m2/20261122_07_workflow_view_read_scope_compat.sql`,
to the disposable cluster. Refuses to run anywhere else.

The migration is additive: SELECT grants plus FOR SELECT owner-scoped policies on
six default-deny tables. It does not touch `m2_assessments.owner_scope`, drops no
existing policy, and adds no write privilege (the append-only INSERT on
`m2_research_objective_sources` from 20261118_06 is preserved and asserted).

Run from ``backend/``::

    python tools/phase4_a2_apply_read_scope_20261122.py --confirm
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re

import psycopg2

BACKEND = pathlib.Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
OUT = REPO / 'deliverables' / 'phase4' / 'a2_read_scope_apply.json'

HOST, PORT, DB = '127.0.0.1', 5433, 'project1_workflow_tests'
RECEIPT = 'project1-p4-a2-read-scope-20261122'
MIGRATION = 'migrations/m2/20261122_07_workflow_view_read_scope_compat.sql'

WATCH = [
    'm2_research_objective_sources',
    'm2_research_clarifications',
    'm2_research_revisions',
    'm2_desired_options',
    'm2_candidate_owner_reviews',
    'm2_review_question_versions',
]


def password() -> str:
    text = (BACKEND / '.env').read_text(encoding='utf-8')
    return re.search(r'^DATABASE_URL=.*://[^:]+:([^@]+)@', text, re.M).group(1)


def connect():
    return psycopg2.connect(host=HOST, port=PORT, user='postgres',
                            password=password(), dbname=DB)


def assert_identity(cur) -> dict:
    cur.execute('SELECT current_database(), inet_server_port(), version()')
    db, port, version = cur.fetchone()
    if db != DB or port != PORT:
        raise SystemExit(f'REFUSED: connected to {db}@{port}, expected {DB}@{PORT}')
    if db in ('Dss', 'Final_Location_Analysis'):
        raise SystemExit('REFUSED: protected database')
    cur.execute('SELECT count(*) FROM public.m2_assessments')
    return {'database': db, 'port': port,
            'server_version': version.split(' ')[1],
            'm2_assessments_rows': cur.fetchone()[0]}


def snapshot(cur) -> dict:
    """Privilege + policy state for the tables this migration touches."""
    state: dict = {}
    for t in WATCH:
        cur.execute('SELECT to_regclass(%s)', (f'public.{t}',))
        if cur.fetchone()[0] is None:
            state[t] = {'exists': False}
            continue
        privs = []
        for p in ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'):
            cur.execute('SELECT has_table_privilege(%s, %s, %s)',
                        ('p1_m2_runtime', f'public.{t}', p))
            if cur.fetchone()[0]:
                privs.append(p)
        cur.execute(
            "SELECT policyname, cmd FROM pg_policies "
            "WHERE schemaname='public' AND tablename=%s ORDER BY policyname", (t,))
        state[t] = {
            'exists': True,
            'p1_m2_runtime_privileges': privs,
            'policies': [{'name': a, 'cmd': b} for a, b in cur.fetchall()],
        }
    return state


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--confirm', action='store_true',
                    help='required: apply for real (no dry-run path)')
    args = ap.parse_args()
    if not args.confirm:
        raise SystemExit('refusing to run without --confirm')

    sql = (BACKEND / MIGRATION).read_text(encoding='utf-8')
    result: dict = {'migration': MIGRATION, 'receipt': RECEIPT}

    conn = connect()
    conn.autocommit = True
    cur = conn.cursor()

    result['identity'] = assert_identity(cur)
    result['before'] = snapshot(cur)

    # The migration's own guard demands these two GUCs. Session scope: the file
    # opens its own transaction, and SET LOCAL would not survive into it.
    cur.execute("SELECT set_config('project1.m2_bcb_migration_target', %s, false)", (DB,))
    cur.execute("SELECT set_config('project1.m2_bcb_migration_receipt', %s, false)", (RECEIPT,))

    try:
        cur.execute(sql)
        result['applied'] = True
    except Exception as exc:  # noqa: BLE001 - the failure text is the evidence
        result['applied'] = False
        result['error'] = f'{type(exc).__name__}: {exc}'.strip()
        result['after'] = snapshot(cur)
        OUT.write_text(json.dumps(result, indent=2), encoding='utf-8')
        print(json.dumps(result, indent=2))
        return 1

    result['after'] = snapshot(cur)
    result['changed'] = {
        t: {
            'privileges_before': result['before'].get(t, {}).get('p1_m2_runtime_privileges'),
            'privileges_after': result['after'].get(t, {}).get('p1_m2_runtime_privileges'),
            'policies_before': [p['name'] for p in result['before'].get(t, {}).get('policies', [])],
            'policies_after': [p['name'] for p in result['after'].get(t, {}).get('policies', [])],
        }
        for t in WATCH
    }

    cur.close()
    conn.close()
    OUT.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps({'applied': result['applied'], 'changed': result['changed'],
                      'identity': result['identity']}, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
