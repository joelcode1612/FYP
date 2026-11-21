"""Print the current BDJ result for an assessment, for terminal inspection.

Read-only. Opens no provider connection, writes nothing.

Usage:
    python tools/bdj_output_verification/print_current_bdj.py [assessment_id]

Defaults to b28cd847-89f6-4994-adad-f79846f77c2e. Prints the latest result
row, its findings, the source references carried in the sealed payload, and
the link rows — so the difference between "the model's refs" and "the row's
source_answer_ids" is visible in one screen.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

import psycopg2

DEFAULT_AID = 'b28cd847-89f6-4994-adad-f79846f77c2e'
ROOT = Path(__file__).resolve().parents[2]


def dsn() -> str:
    url = os.environ.get('DATABASE_URL')
    if not url:
        for line in (ROOT / '.env').read_text(encoding='utf-8', errors='replace').splitlines():
            m = re.match(r'\s*DATABASE_URL\s*=\s*(.+)', line)
            if m:
                url = m.group(1).strip().strip('"\'')
                break
    if not url:
        raise SystemExit('DATABASE_URL not found')
    # Same server, M2 database.
    return re.sub(r'^postgresql\+\w+://', 'postgresql://', url).replace(
        '/Final_Location_Analysis', '/Dss')


def main() -> int:
    aid = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_AID
    conn = psycopg2.connect(dsn(), connect_timeout=5)
    conn.autocommit = True
    cur = conn.cursor()

    cur.execute('SELECT revision, confirmed_revision FROM public.m2_assessments WHERE id=%s', (aid,))
    row = cur.fetchone()
    if not row:
        print(f'assessment {aid} not found'); return 1
    rev, conf = row
    print(f'assessment {aid}')
    print(f'  revision={rev}  confirmed={conf}  current={rev == conf}')

    cur.execute("""
        SELECT result_id, assessment_revision, execution_outcome, review_outcome,
               validation_status, finding_authority, finding_count,
               model_requested, model_returned, source_fingerprint, ruleset_version
          FROM project1_ai.bdj_results WHERE assessment_id=%s
         ORDER BY created_at DESC LIMIT 3""", (aid,))
    results = cur.fetchall()
    print(f'\nresults ({len(results)}):')
    for r in results:
        print(f'  rev={r[1]} {r[2]}/{r[3]}/{r[4]} count={r[6]}')
        print(f'    model_requested={r[7]}')
        print(f'    model_returned ={r[8]}')
        print(f'    fingerprint    ={str(r[9])[:16]}…  ruleset={r[10]}')
        if r[1] == rev:
            print('    ^ at the current revision')

    cur.execute("""
        SELECT f.rule_id, f.review_state, f.rule_version,
               json_array_length(f.source_answer_ids::json), l.authority
          FROM public.m2_bdj_findings f
          JOIN project1_ai.bdj_result_findings l ON l.finding_id = f.id
         WHERE f.assessment_id=%s AND f.assessment_revision=%s
         ORDER BY f.rule_id""", (aid, rev))
    findings = cur.fetchall()
    print(f'\nfindings at rev {rev} ({len(findings)}):')
    for f in findings:
        flag = 'OK' if f[3] else 'EMPTY  <-- mapping defect'
        print(f'  {f[0]}')
        print(f'    state={f[1]} ruleset={f[2]} link_authority={f[4]}')
        print(f'    source_answer_ids: {flag}')

    cur.execute("""
        SELECT result_payload FROM project1_ai.bdj_results
         WHERE assessment_id=%s AND assessment_revision=%s
         ORDER BY created_at DESC LIMIT 1""", (aid, rev))
    p = cur.fetchone()
    print(f'\nsource refs in the sealed payload (rev {rev}):')
    if p and isinstance(p[0], dict):
        for f in (p[0].get('findings') or [])[:4]:
            refs = f.get('source_refs') or []
            keys = ', '.join(r.get('item_key', '?') for r in refs) or '(none)'
            print(f"  {f.get('rule_id')}: {keys}")
        print('  note: these are the model\'s refs after validation; compare with the')
        print('        source_answer_ids above — empty there means the copy step drops them.')
    else:
        print('  payload not readable as plain JSON (sealed envelope)')

    conn.close()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
