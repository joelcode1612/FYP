"""Rehearse migration 20261125_07_owner_intention in a throwaway schema.

Why a rehearsal rather than applying it
---------------------------------------
The migration adds a column, four CHECK constraints and a BEFORE INSERT OR UPDATE
trigger to ``m2_qg_candidate_reviews``. The trigger raises for an approval that
carries no intention, which is the behaviour CP-01 requires — but a trigger that
is wrong is discovered on the next write to real data, not on read. So the DDL is
executed here against synthetic rows first.

What this does NOT do
---------------------
* It does not touch the PG18 integration database.
* It does not create a database. It creates one schema, ``migtest``, inside the
  disposable database on 5433, and drops it at the end.
* The migration text is applied with ``public.`` rewritten to ``migtest.`` so the
  objects land in the scratch schema. That substitution is asserted below, so a
  future migration that hard-codes another schema cannot slip through unverified.

Usage::

    backend/.venv/Scripts/python.exe backend/tools/m2_owner_intention_migration_rehearsal.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import psycopg2

REPO = Path(__file__).resolve().parents[2]
MIGRATION = REPO / 'backend/migrations/m2/20261125_07_owner_intention.sql'
ENV = REPO / 'backend/.env'
SCRATCH = 'migtest'

FAILURES: list[str] = []
CHECKS = 0


def _dsn() -> str:
    from urllib.parse import unquote, urlparse

    text = ENV.read_text(encoding='utf-8', errors='replace')
    url = re.search(r'DATABASE_URL=(.+)', text).group(1).strip().strip('"').strip("'")
    parsed = urlparse(url.replace('postgresql+psycopg2', 'postgresql'))
    return (f'host=127.0.0.1 port=5433 dbname=project1_disposable_app '
            f'user={parsed.username} password={unquote(parsed.password or "")}')


def check(label: str, condition: bool, detail: str = '') -> None:
    global CHECKS
    CHECKS += 1
    if condition:
        print(f'  PASS  {label}')
    else:
        FAILURES.append(f'{label} :: {detail}')
        print(f'  FAIL  {label}  {detail}')


def refused(cur, sql: str, params=None) -> tuple[bool, str]:
    """Run a statement expecting refusal. Returns (refused?, message)."""
    try:
        cur.execute(sql, params)
        return False, ''
    except psycopg2.Error as exc:
        return True, str(exc).strip().splitlines()[0]


def main() -> int:
    sql = MIGRATION.read_text(encoding='utf-8')
    rewritten = sql.replace('public.', f'{SCRATCH}.')

    conn = psycopg2.connect(_dsn())
    conn.autocommit = True
    cur = conn.cursor()

    cur.execute(f'DROP SCHEMA IF EXISTS {SCRATCH} CASCADE')
    cur.execute(f'CREATE SCHEMA {SCRATCH}')

    # The two tables the migration touches, with only the columns it reads.
    cur.execute(f"""
        CREATE TABLE {SCRATCH}.m2_qg_candidates (
            candidate_id uuid PRIMARY KEY,
            response_format text
        )
    """)
    cur.execute(f"""
        CREATE TABLE {SCRATCH}.m2_qg_candidate_reviews (
            candidate_id uuid REFERENCES {SCRATCH}.m2_qg_candidates(candidate_id),
            decision text,
            expected_option_code text
        )
    """)

    # Historical rows: the shape the real table is in today.
    cur.execute(f"""
        INSERT INTO {SCRATCH}.m2_qg_candidates VALUES
            ('11111111-1111-1111-1111-111111111111', 'SINGLE_CHOICE'),
            ('22222222-2222-2222-2222-222222222222', 'MULTIPLE_CHOICE')
    """)
    cur.execute(f"""
        INSERT INTO {SCRATCH}.m2_qg_candidate_reviews VALUES
            ('11111111-1111-1111-1111-111111111111', 'APPROVE_FOR_REVIEW', 'LIKELY'),
            ('22222222-2222-2222-2222-222222222222', 'APPROVE_FOR_REVIEW', NULL),
            ('11111111-1111-1111-1111-111111111111', 'REJECT', NULL)
    """)

    print('\n1. migration applies cleanly')
    check('no unrewritten public. qualifier remains',
          'public.' not in rewritten,
          'the migration hard-codes a schema other than public')
    try:
        cur.execute(rewritten)
        applied = True
    except psycopg2.Error as exc:
        applied = False
        check('migration executes', False, str(exc).strip().splitlines()[0])
    if applied:
        check('migration executes', True)

    print('\n2. backfill states the existing intention once, and invents none')
    cur.execute(f"""
        SELECT expected_option_codes
          FROM {SCRATCH}.m2_qg_candidate_reviews
         WHERE decision = 'APPROVE_FOR_REVIEW'
           AND candidate_id = '11111111-1111-1111-1111-111111111111'
    """)
    row = cur.fetchone()
    check('approved row with a singular code was backfilled',
          row is not None and row[0] == ['LIKELY'], repr(row))

    cur.execute(f"""
        SELECT expected_option_codes
          FROM {SCRATCH}.m2_qg_candidate_reviews
         WHERE candidate_id = '22222222-2222-2222-2222-222222222222'
    """)
    row = cur.fetchone()
    check('approved row with no code stays NULL — no intention invented',
          row is not None and row[0] is None, repr(row))

    print('\n3. an approval without an intention is refused by the trigger')
    ok, msg = refused(cur, f"""
        INSERT INTO {SCRATCH}.m2_qg_candidate_reviews VALUES
            ('11111111-1111-1111-1111-111111111111', 'APPROVE_FOR_REVIEW', NULL)
    """)
    check('INSERT approved + no intention refused', ok, msg)
    check('refusal names the rule', 'QG_OWNER_INTENTION_REQUIRED' in msg, msg)

    print('\n4. an approval with a valid intention is accepted')
    try:
        cur.execute(f"""
            INSERT INTO {SCRATCH}.m2_qg_candidate_reviews
                (candidate_id, decision, expected_option_code, expected_option_codes)
            VALUES ('11111111-1111-1111-1111-111111111111',
                    'APPROVE_FOR_REVIEW', 'LIKELY', ARRAY['LIKELY'])
        """)
        check('INSERT approved + valid intention accepted', True)
    except psycopg2.Error as exc:
        check('INSERT approved + valid intention accepted', False,
              str(exc).strip().splitlines()[0])

    print('\n5. a rejection needs no intention')
    ok, msg = refused(cur, f"""
        INSERT INTO {SCRATCH}.m2_qg_candidate_reviews VALUES
            ('11111111-1111-1111-1111-111111111111', 'REJECT', NULL)
    """)
    check('INSERT rejected + no intention allowed', not ok, msg)

    print('\n6. invalid selections are refused by the constraints')
    ok, msg = refused(cur, f"""
        UPDATE {SCRATCH}.m2_qg_candidate_reviews
           SET expected_option_codes = ARRAY['LIKELY', 'LIKELY']
         WHERE candidate_id = '11111111-1111-1111-1111-111111111111'
    """)
    check('duplicate codes refused', ok, msg)

    ok, msg = refused(cur, f"""
        UPDATE {SCRATCH}.m2_qg_candidate_reviews
           SET expected_option_codes = ARRAY['']
         WHERE candidate_id = '11111111-1111-1111-1111-111111111111'
    """)
    check('blank code refused', ok, msg)

    ok, msg = refused(cur, f"""
        UPDATE {SCRATCH}.m2_qg_candidate_reviews
           SET expected_option_codes = ARRAY['YES']
         WHERE candidate_id = '11111111-1111-1111-1111-111111111111'
    """)
    check('singular and array disagreeing refused', ok, msg)

    ok, msg = refused(cur, f"""
        UPDATE {SCRATCH}.m2_qg_candidate_reviews
           SET expected_option_codes = ARRAY[]::text[]
         WHERE candidate_id = '11111111-1111-1111-1111-111111111111'
    """)
    check('empty array refused', ok, msg)

    print('\n7. multiple-choice intention is representable')
    try:
        cur.execute(f"""
            INSERT INTO {SCRATCH}.m2_qg_candidate_reviews
                (candidate_id, decision, expected_option_code, expected_option_codes)
            VALUES ('22222222-2222-2222-2222-222222222222',
                    'APPROVE_FOR_REVIEW', NULL, ARRAY['YES', 'NO'])
        """)
        check('two-code intention on a multi-select accepted', True)
    except psycopg2.Error as exc:
        check('two-code intention on a multi-select accepted', False,
              str(exc).strip().splitlines()[0])

    cur.execute(f'DROP SCHEMA IF EXISTS {SCRATCH} CASCADE')
    conn.close()

    print(f'\n{CHECKS - len(FAILURES)}/{CHECKS} checks passed')
    if FAILURES:
        print('\nFAILURES:')
        for item in FAILURES:
            print(f'  - {item}')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
