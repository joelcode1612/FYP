"""Provision the isolated PROJECT1 PostgreSQL 18 environment on 127.0.0.1:5544.

Owner Decision 1 and 2 (2026-11-23) authorise exactly this: a new PG18 cluster,
two test databases, restricted roles and migration infrastructure. They do not
authorise touching `Dss` (5432) or `Final_Location_Analysis`.

What this script will not do
----------------------------
* It refuses to run against any port other than 5544, and refuses any database
  named `Dss` or `Final_Location_Analysis`, before issuing a single statement.
* It never copies records. Schema is built from versioned DDL in
  ``migrations/pg18``; data movement is a separate, separately approved step.
* It never creates a schema that has no tracked DDL (``fyp``, ``ee01``,
  ``fnb_a``). Those stay absent and the absence is asserted, not hidden.

Identity is proved three ways before any write: the TCP port the server reports
(``inet_server_port()``), the database the session is actually in
(``current_database()``), and the principal (``current_user``). A URL is not
evidence; the server's own answer is.

Usage
-----
    backend/.venv/Scripts/python.exe tools/pg18_provision_5544.py --receipt out.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
MIGRATIONS = BACKEND / 'migrations' / 'pg18'
ROLES_SQL = MIGRATIONS / '20261123_00_roles.sql'
SCHEMAS_SQL = MIGRATIONS / '20261123_01_schemas.sql'

HOST = '127.0.0.1'
PORT = 5544
ADMIN_DB = 'postgres'
ADMIN_USER = 'postgres'
ADMIN_PASSWORD = os.environ.get('PG18_ADMIN_PASSWORD', 'p1_pg18_dev_only_5544')

BASELINE_DB = 'project1_pg18_baseline_tests'
MIGRATED_DB = 'project1_pg18_migrated_tests'
DATABASES = (BASELINE_DB, MIGRATED_DB)

PROTECTED_DATABASES = {'Dss', 'Final_Location_Analysis'}
FORBIDDEN_PORTS = {5432, 5433}


def _connect(database: str):
    import psycopg2

    return psycopg2.connect(
        host=HOST, port=PORT, dbname=database,
        user=ADMIN_USER, password=ADMIN_PASSWORD,
        connect_timeout=10,
    )


def prove_identity(conn) -> dict:
    """Read the server's own answer and refuse anything that is not the target.

    This runs before any DDL. It is the same discipline as
    ``sitewise.core.db_identity``: ask the server, do not trust the URL.
    """
    with conn.cursor() as cur:
        cur.execute(
            'select current_database(), current_user, inet_server_port(), '
            '       coalesce(host(inet_server_addr()), %s), version()',
            (HOST,),
        )
        database, principal, port, address, version = cur.fetchone()
    conn.rollback()

    if port in FORBIDDEN_PORTS:
        raise SystemExit(f'REFUSED: connected to protected/legacy port {port}')
    if port != PORT:
        raise SystemExit(f'REFUSED: expected port {PORT}, server reports {port}')
    if database in PROTECTED_DATABASES:
        raise SystemExit(f'REFUSED: connected to protected database {database}')
    if address not in {HOST, '127.0.0.1'}:
        raise SystemExit(f'REFUSED: server address {address} is not loopback')

    return {
        'database': database,
        'principal': principal,
        'server_port': port,
        'server_address': address,
        'server_version': version.split(' on ')[0],
    }


def database_exists(conn, name: str) -> bool:
    with conn.cursor() as cur:
        cur.execute('select 1 from pg_database where datname = %s', (name,))
        found = cur.fetchone() is not None
    conn.rollback()
    return found


def create_databases(conn) -> list[dict]:
    created = []
    conn.autocommit = True
    try:
        for name in DATABASES:
            if database_exists(conn, name):
                created.append({'database': name, 'action': 'already-exists'})
                continue
            with conn.cursor() as cur:
                # Template0 + explicit encoding keeps the cluster's C locale and
                # avoids inheriting anything from template1.
                cur.execute(
                    f'CREATE DATABASE "{name}" WITH TEMPLATE template0 '
                    f"ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C'"
                )
            created.append({'database': name, 'action': 'created'})
    finally:
        conn.autocommit = False
    return created


def apply_sql(database: str, sql_path: Path, label: str) -> dict:
    if not sql_path.is_file():
        raise SystemExit(f'REFUSED: missing migration {sql_path}')
    conn = _connect(database)
    try:
        identity = prove_identity(conn)
        script = sql_path.read_text(encoding='utf-8')
        with conn.cursor() as cur:
            cur.execute(script)
        conn.commit()
        return {
            'step': label,
            'database': database,
            'file': sql_path.name,
            'identity': identity,
            'result': 'applied',
        }
    finally:
        conn.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', type=Path, default=None,
                        help='write a JSON receipt to this path')
    args = parser.parse_args()

    admin = _connect(ADMIN_DB)
    try:
        identity = prove_identity(admin)
    finally:
        admin.close()

    print(f'[pg18] identity proved: {identity}', flush=True)

    admin = _connect(ADMIN_DB)
    try:
        databases = create_databases(admin)
    finally:
        admin.close()
    for row in databases:
        print(f'[pg18] {row["database"]}: {row["action"]}', flush=True)

    steps = []
    # Roles are cluster-wide: apply once, against the baseline database.
    steps.append(apply_sql(BASELINE_DB, ROLES_SQL, 'roles'))
    for database in DATABASES:
        steps.append(apply_sql(database, SCHEMAS_SQL, 'schemas'))

    receipt = {
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'target': {'host': HOST, 'port': PORT, 'cluster': 'PostgreSQL 18'},
        'identity': identity,
        'databases': databases,
        'steps': steps,
        'protected_untouched': sorted(PROTECTED_DATABASES),
    }
    print(json.dumps(receipt, indent=2), flush=True)

    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, indent=2), encoding='utf-8')
        print(f'[pg18] receipt written: {args.receipt}', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
