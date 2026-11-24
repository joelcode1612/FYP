"""Serve the real SiteWise FastAPI application against the isolated PG18 cluster.

Target: ``project1_pg18_migrated_tests`` @ ``127.0.0.1:5544``, HTTP on ``8093``.
Owner Decision 1/2/4, 2026-11-23.

Differences from ``ex05_serve_disposable_20261123.py``
----------------------------------------------------
That launcher targets ``project1_workflow_tests@5433``, substitutes a local GoTrue
stub, injects the stub's JWKS bytes and replaces the admin service with an
in-memory fake. None of that applies here:

* identity is the **real** Supabase project, because the compiled frontend's
  ``auth-config.json`` points at it and the operator signs in through the normal
  login screen (Owner Decision 4/5);
* the database is a real PostgreSQL 18 cluster on 5544, not 5433.

What is kept
------------
The identity discipline. ``assert_target`` reads the server's own answer and
refuses to bind if it is not the declared database on the declared port with a
non-privileged principal. A URL is a claim; ``current_database()`` is evidence.

Usage
-----
    backend/.venv/Scripts/python.exe tools/pg18_serve_8093.py --port 8093
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
ENV_FILE = BACKEND / 'var' / 'e2e' / 'pg18' / 'app_pg18.env'

EXPECTED_DATABASE = 'project1_pg18_migrated_tests'
EXPECTED_PORT = 5544
FORBIDDEN_DATABASES = {'Dss', 'Final_Location_Analysis'}
FORBIDDEN_PORTS = {5432, 5433}

sys.path.insert(0, str(BACKEND / 'src'))
sys.path.insert(0, str(BACKEND))
sys.path.insert(0, str(BACKEND / 'tools'))


def load_environment(path: Path) -> int:
    if not path.is_file():
        raise SystemExit(f'REFUSED: configuration not found: {path}')
    applied = 0
    for raw in path.read_text(encoding='utf-8', errors='replace').splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        key = key.strip()
        if not key.replace('_', '').isalnum():
            continue
        os.environ[key] = value.strip().strip('"').strip("'")
        applied += 1
    return applied


def assert_target() -> dict:
    """Prove the engines resolve to PG18 before a socket is bound."""
    from sqlalchemy import text
    from sitewise.db.m2_session import get_m2_engine

    engine = get_m2_engine()
    with engine.connect() as conn:
        row = conn.execute(text(
            'select current_database(), current_user, inet_server_port(), '
            '       coalesce(host(inet_server_addr()), \'127.0.0.1\'), '
            '       (select rolsuper or rolbypassrls from pg_roles '
            '         where rolname = current_user)'
        )).one()
        conn.rollback()
    database, principal, port, address, privileged = row

    if database in FORBIDDEN_DATABASES:
        raise SystemExit(f'REFUSED: connected to protected database {database}')
    if port in FORBIDDEN_PORTS:
        raise SystemExit(f'REFUSED: connected to protected/legacy port {port}')
    if database != EXPECTED_DATABASE or port != EXPECTED_PORT:
        raise SystemExit(
            f'REFUSED: expected {EXPECTED_DATABASE}@{EXPECTED_PORT}, '
            f'server reports {database}@{port}')
    if privileged:
        raise SystemExit(f'REFUSED: principal {principal} holds superuser/BYPASSRLS')

    return {
        'database': database, 'principal': principal,
        'port': port, 'address': address,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8093)
    args = parser.parse_args()

    applied = load_environment(ENV_FILE)
    print(f'[pg18-serve] env: {applied} entries from {ENV_FILE.name}', flush=True)

    # One shared guard, not a third private copy.
    from dead_proxy_guard import drop_unreachable_proxies
    drop_unreachable_proxies()

    identity = assert_target()
    print(f'[pg18-serve] target proved: {identity}', flush=True)
    print(f'[pg18-serve] tokenharbor_enabled={os.environ.get("TOKENHARBOR_ENABLED")} '
          f'cq_runtime_enabled={os.environ.get("CQ_RUNTIME_ENABLED", "<unset>")}', flush=True)

    from sitewise.main import app
    import uvicorn

    print(f'[pg18-serve] binding http://{args.host}:{args.port}', flush=True)
    uvicorn.run(app, host=args.host, port=args.port,
                log_level=os.environ.get('LOG_LEVEL', 'info').lower())
    return 0


if __name__ == '__main__':
    sys.exit(main())
