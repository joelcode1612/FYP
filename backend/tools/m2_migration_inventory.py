"""Inventory: which m2 migrations are applied on a target database?

This is a *reader*. It opens no DDL and changes nothing. Its job is to answer the
question that must be answered before any migration is applied: for each file in
``backend/migrations/m2``, are the objects it creates already present?

Applying twenty migrations "in case they are needed" is how a database acquires a
schema nobody can describe. The migrations themselves are defensive (each one
refuses to re-run), but a refusal discovered halfway through a batch leaves the
caller guessing which of the earlier ones committed. This report makes the gap
explicit first.

What is extracted from each forward migration:

  * ``CREATE TABLE public.<name>``                  → table must exist
  * ``ADD COLUMN <col>`` following an ``ALTER TABLE public.<t>`` → column must exist
  * ``CREATE [OR REPLACE] FUNCTION public.<name>``   → function must exist
  * ``CREATE TRIGGER <name>``                        → trigger must exist somewhere
  * ``CREATE POLICY <name>``                         → policy must exist somewhere

Every object found is classified PRESENT / MISSING, and the migration is
APPLIED (nothing missing), PARTIAL (some missing) or MISSING (none present).
PARTIAL is the interesting case and is never treated as "probably fine".

Usage:
    backend/.venv/Scripts/python.exe tools/m2_migration_inventory.py \
        --db project1_disposable_app --port 5433
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import psycopg2

BACKEND = Path(__file__).resolve().parents[1]
MIGRATIONS = BACKEND / 'migrations/m2'

_TABLE = re.compile(r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?public\.([a-z0-9_]+)',
                    re.I)
_FUNCTION = re.compile(
    r'CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+public\.([a-z0-9_]+)', re.I)
_ALTER = re.compile(r'ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?public\.([a-z0-9_]+)', re.I)
_COLUMN = re.compile(r'\bADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?([a-z0-9_]+)', re.I)
_TRIGGER = re.compile(r'CREATE\s+TRIGGER\s+([a-z0-9_]+)', re.I)
_POLICY = re.compile(r'CREATE\s+POLICY\s+([a-z0-9_]+)', re.I)
_INDEX = re.compile(r'CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?([a-z0-9_]+)',
                    re.I)


def strip_comments(sql: str) -> str:
    """Remove ``--`` comments and block comments.

    Without this, a migration's own docstring — which quotes the statements it is
    about to run — is read as if it were the statements. Several of these files
    discuss ``ALTER TABLE`` in prose before doing it.
    """
    sql = re.sub(r'/\*.*?\*/', ' ', sql, flags=re.S)
    return re.sub(r'--[^\n]*', ' ', sql)


def expected_objects(path: Path) -> dict:
    sql = strip_comments(path.read_text(encoding='utf-8-sig'))
    tables = sorted(set(_TABLE.findall(sql)))
    functions = sorted(set(_FUNCTION.findall(sql)))
    triggers = sorted(set(_TRIGGER.findall(sql)))
    policies = sorted(set(_POLICY.findall(sql)))
    indexes = sorted(set(_INDEX.findall(sql)))

    columns: dict[str, list[str]] = {}
    for match in _ALTER.finditer(sql):
        table = match.group(1)
        # Only the ADD COLUMN tokens between this ALTER and the next semicolon
        # belong to this table.
        end = sql.find(';', match.end())
        body = sql[match.end():end if end != -1 else len(sql)]
        found = _COLUMN.findall(body)
        if found:
            columns.setdefault(table, [])
            columns[table].extend(c for c in found if c not in columns[table])

    return {'tables': tables, 'functions': functions, 'triggers': triggers,
            'policies': policies, 'indexes': indexes, 'columns': columns}


def snapshot(conn) -> dict:
    with conn.cursor() as cur:
        cur.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'")
        tables = {r[0] for r in cur.fetchall()}
        cur.execute("SELECT table_name, column_name FROM information_schema.columns"
                    " WHERE table_schema='public'")
        columns: dict[str, set[str]] = {}
        for table, column in cur.fetchall():
            columns.setdefault(table, set()).add(column)
        cur.execute("SELECT p.proname FROM pg_proc p JOIN pg_namespace n"
                    " ON n.oid=p.pronamespace WHERE n.nspname='public'")
        functions = {r[0] for r in cur.fetchall()}
        cur.execute("SELECT tgname FROM pg_trigger WHERE NOT tgisinternal")
        triggers = {r[0] for r in cur.fetchall()}
        cur.execute("SELECT policyname FROM pg_policies")
        policies = {r[0] for r in cur.fetchall()}
        cur.execute("SELECT indexname FROM pg_indexes WHERE schemaname='public'")
        indexes = {r[0] for r in cur.fetchall()}
    return {'tables': tables, 'columns': columns, 'functions': functions,
            'triggers': triggers, 'policies': policies, 'indexes': indexes}


def classify(expected: dict, actual: dict) -> dict:
    missing: dict[str, list[str]] = {}
    for table in expected['tables']:
        if table not in actual['tables']:
            missing.setdefault('tables', []).append(table)
    for table, columns in expected['columns'].items():
        if table not in actual['tables']:
            continue  # already reported as a missing table
        for column in columns:
            if column not in actual['columns'].get(table, set()):
                missing.setdefault('columns', []).append(f'{table}.{column}')
    for key, pool in (('functions', actual['functions']),
                      ('triggers', actual['triggers']),
                      ('policies', actual['policies']),
                      ('indexes', actual['indexes'])):
        for name in expected[key]:
            if name not in pool:
                missing.setdefault(key, []).append(name)
    total = (len(expected['tables']) + len(expected['functions'])
             + len(expected['triggers']) + len(expected['policies'])
             + len(expected['indexes'])
             + sum(len(v) for v in expected['columns'].values()))
    absent = sum(len(v) for v in missing.values())
    if total == 0:
        status = 'NO-OBJECTS'
    elif absent == 0:
        status = 'APPLIED'
    elif absent == total:
        status = 'MISSING'
    else:
        status = 'PARTIAL'
    return {'status': status, 'expected': total, 'absent': absent,
            'missing': missing}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--db', default='project1_disposable_app')
    parser.add_argument('--port', type=int, default=5433)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()

    import os
    password = os.environ.get('M2_INVENTORY_PASSWORD')
    if not password:
        text = (BACKEND / '.env').read_text(encoding='utf-8', errors='replace')
        match = re.search(r'^DATABASE_URL=[^:]+://[^:]+:([^@]+)@', text, re.M)
        if not match:
            raise SystemExit('no password: set M2_INVENTORY_PASSWORD')
        password = match.group(1)

    conn = psycopg2.connect(host=args.host, port=args.port, dbname=args.db,
                            user='postgres', password=password, connect_timeout=10)
    try:
        with conn.cursor() as cur:
            cur.execute('SELECT current_database(), inet_server_port()')
            database, port = cur.fetchone()
        if database != args.db or int(port) != args.port:
            raise SystemExit(f'refusing: server reports {database}@{port}')
        actual = snapshot(conn)
    finally:
        conn.close()

    report = {'database': database, 'port': port,
              'public_tables': len(actual['tables']), 'migrations': []}
    for path in sorted(MIGRATIONS.glob('*.sql')):
        if path.stem.endswith('_rollback'):
            continue
        result = classify(expected_objects(path), actual)
        report['migrations'].append({'file': path.name, **result})

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    print(f"{report['database']}@{report['port']}  "
          f"({report['public_tables']} public tables)\n")
    width = max(len(m['file']) for m in report['migrations'])
    for m in report['migrations']:
        print(f"{m['file']:<{width}}  {m['status']:<10} "
              f"{m['expected'] - m['absent']:>3}/{m['expected']:<3} present")
        if m['status'] in {'PARTIAL', 'MISSING'} and m['missing']:
            for kind, names in sorted(m['missing'].items()):
                print(f"{'':<{width}}    missing {kind}: {', '.join(names[:8])}"
                      + (' …' if len(names) > 8 else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
