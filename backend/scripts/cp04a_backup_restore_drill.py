"""CP-04A backup restore drill: prove the PG16 pre-apply dump restores cleanly.

Restores into a throwaway database, compares the result with `Dss`, then drops
it. It never writes to `Dss`. Credentials are passed through the environment and
are never printed.

    python scripts/cp04a_backup_restore_drill.py [--dump PATH]
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cp04a_live_dispatch_probe import read_env            # noqa: E402

PG_BIN = Path(r'C:\Program Files\PostgreSQL\16\bin')
DEFAULT_DUMP = (Path(__file__).resolve().parents[1] / 'backups' / 'cp04a'
                / 'dss_pre_cp04a_pg16_20261117_155626.dump')
DRILL = 'cp04a_restore_drill'
SCHEMA = 'project1_ai'


def url_for(dbname: str):
    return make_url(read_env()['DATABASE_URL']).set(database=dbname)


def admin_engine(dbname: str):
    return create_engine(url_for(dbname), hide_parameters=True, isolation_level='AUTOCOMMIT')


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--dump', default=str(DEFAULT_DUMP))
    args = parser.parse_args()
    dump = Path(args.dump)
    if not dump.is_file():
        print(f'BLOCKED  dump not found: {dump}')
        return 1

    url = url_for('postgres')
    env = {**os.environ, 'PGPASSWORD': url.password or ''}
    common = ['-h', url.host or 'localhost', '-p', str(url.port or 5432),
              '-U', url.username or 'postgres']

    print(f'dump: {dump.name}  ({dump.stat().st_size} bytes)')
    print(f'pg_restore: {subprocess.run([str(PG_BIN / "pg_restore"), "--version"], capture_output=True, text=True).stdout.strip()}')

    # Fresh scratch database.
    engine = admin_engine('postgres')
    with engine.connect() as c:
        c.execute(text(f'DROP DATABASE IF EXISTS {DRILL} WITH (FORCE)'))
        c.execute(text(f'CREATE DATABASE {DRILL}'))
    print(f'scratch database {DRILL!r} created (Dss untouched)')

    rc = 1
    try:
        proc = subprocess.run(
            [str(PG_BIN / 'pg_restore'), *common, '-d', DRILL,
             '--exit-on-error', '--single-transaction', str(dump)],
            capture_output=True, text=True, env=env)
        rc = proc.returncode
        print(f'pg_restore rc={rc}')
        for stream, label in ((proc.stderr, 'stderr'), (proc.stdout, 'stdout')):
            text_out = (stream or '').strip()
            if text_out:
                print(f'  {label}: {text_out[:1500]}')

        # Compare the restored catalog with Dss.
        drill = admin_engine(DRILL)
        with drill.connect() as c:
            tables = [r[0] for r in c.execute(text(
                "select tablename from pg_tables where schemaname=:s order by 1"), {'s': SCHEMA})]
            counts = {t: c.execute(text(f'select count(*) from {SCHEMA}.{t}')).scalar() for t in tables}
            ledger = c.execute(text(
                f'select version from {SCHEMA}.schema_versions order by applied_at')).scalars().all()
            roles = c.execute(text(
                "select count(*) from pg_roles where rolname like 'p1%'")).scalar()
        drill.dispose()

        primary = admin_engine('Dss')
        with primary.connect() as c:
            dss_tables = [r[0] for r in c.execute(text(
                "select tablename from pg_tables where schemaname=:s order by 1"), {'s': SCHEMA})]
            dss_counts = {t: c.execute(text(f'select count(*) from {SCHEMA}.{t}')).scalar()
                          for t in dss_tables}
        primary.dispose()

        print(f'restored {SCHEMA} tables: {tables}')
        print(f'restored row counts: {counts}')
        print(f'restored ledger: {ledger}')
        print(f'Dss     row counts: {dss_counts}')
        same_tables = tables == dss_tables
        same_counts = all(counts.get(t) == n for t, n in dss_counts.items())
        print(f'\n  {"PASS" if same_tables else "BLOCKED"}  B1 restored table set matches Dss')
        print(f'  {"PASS" if same_counts else "BLOCKED"}  B2 restored row counts match Dss')
        print(f'  {"PASS" if rc == 0 else "BLOCKED"}  B3 pg_restore exited 0 with --exit-on-error')
        ok = rc == 0 and same_tables and same_counts
    finally:
        with engine.connect() as c:
            c.execute(text(f'DROP DATABASE IF EXISTS {DRILL} WITH (FORCE)'))
        engine.dispose()
        print(f'scratch database {DRILL!r} dropped')

    print(f'\nOverall: {"PASS" if ok else "BLOCKED"}')
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
