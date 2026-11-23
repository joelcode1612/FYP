"""Run targeted tests with a verified disposable database identity.

Why this exists
---------------
``backend/.env`` points ``DATABASE_URL`` at ``Final_Location_Analysis@5432``,
which is a protected database with real data. The test suite writes rows and
shells out to the recommender trainer, which used to overwrite a tracked
reference artifact. Both are now guarded:

* ``tests/conftest.py::require_disposable_database`` refuses to start unless the
  server itself reports a disposable database on the disposable port.
* the trainer honours ``SITEWISE_ML_EVAL_DIR`` so its report lands in a
  temporary directory.

This runner makes the intended invocation explicit and reproducible:

1. reads the DB password from ``backend/.env`` (never printed, never copied);
2. builds a URL for the disposable database on port 5433;
3. re-verifies the identity against the SERVER before pytest starts;
4. points the trainer output at a fresh temporary directory;
5. runs the requested test paths and records stdout, exit code, and the
   ``git status`` of every path the run could have touched.

Nothing here contacts ``Dss@5432`` or ``Final_Location_Analysis@5432``.

Usage::

    python tools/p2_isolated_test_runner_20261122.py \
        --db project1_disposable_app \
        tests/api/test_layer2_reuse_and_gate.py
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
DEFAULT_DB = 'project1_disposable_app'
DISPOSABLE_PORT = 5433
DISPOSABLE_DATABASES = {'project1_workflow_tests', 'project1_disposable_app'}
PROTECTED_DATABASES = {'Final_Location_Analysis', 'Dss', 'dss', 'sitesense', 'postgres'}

#: Tracked paths a test run must never modify.
WATCHED_PATHS = (
    'backend/ml_reference/recommender_eval/model_selection_report.json',
    'backend/ml_reference/recommender_eval',
)


def _db_password() -> str:
    text = (BACKEND / '.env').read_text(encoding='utf-8', errors='replace')
    match = re.search(r'^DATABASE_URL=(.*)$', text, re.M)
    if not match:
        raise SystemExit('DATABASE_URL not found in backend/.env')
    url = match.group(1).strip()
    cred = re.match(r'^[^:]+://[^:]+:([^@]+)@', url)
    if not cred:
        raise SystemExit('DATABASE_URL has no inline password')
    return cred.group(1)


def _database_url(password: str, db: str) -> str:
    return f'postgresql+psycopg2://postgres:{password}@127.0.0.1:{DISPOSABLE_PORT}/{db}'


def _verify_server_identity(url: str, expected_db: str) -> dict:
    """Ask the server what it actually is; never trust the URL we just built."""
    from sqlalchemy import create_engine, text

    engine = create_engine(url)
    try:
        with engine.connect() as conn:
            db, port = conn.execute(
                text('SELECT current_database(), inet_server_port()')
            ).one()
    finally:
        engine.dispose()

    if db != expected_db:
        raise SystemExit(f'identity check failed: server reports {db!r}, expected {expected_db!r}')
    if int(port) != DISPOSABLE_PORT:
        raise SystemExit(f'identity check failed: server reports port {port}, expected {DISPOSABLE_PORT}')
    if db in PROTECTED_DATABASES:
        raise SystemExit(f'identity check failed: {db!r} is protected')
    return {'database': db, 'port': int(port)}


def _git_state(paths) -> dict:
    def run(args):
        proc = subprocess.run(
            ['git', *args], cwd=str(REPO), capture_output=True, text=True
        )
        return proc.stdout.strip()

    status = run(['status', '--porcelain', '--', *paths])
    return {
        'status_porcelain': [line for line in status.splitlines() if line.strip()],
        'dirty': bool(status.strip()),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--db', default=DEFAULT_DB)
    parser.add_argument('--evidence', default=None)
    parser.add_argument('tests', nargs='+')
    args = parser.parse_args()

    if args.db not in DISPOSABLE_DATABASES:
        raise SystemExit(f'refusing: {args.db!r} is not a disposable database')

    password = _db_password()
    url = _database_url(password, args.db)
    identity = _verify_server_identity(url, args.db)

    eval_dir = Path(tempfile.mkdtemp(prefix='p2-ml-eval-'))
    # A dedicated basetemp stops pytest from garbage-collecting the shared
    # ``pytest-of-<user>`` root, which trips bulk-delete guards mid-session.
    basetemp = Path(tempfile.mkdtemp(prefix='p2-pytest-bt-'))
    before = _git_state(WATCHED_PATHS)

    env = dict(os.environ)
    env['DATABASE_URL'] = url
    env['SITEWISE_ML_EVAL_DIR'] = str(eval_dir)
    env.pop('SITEWISE_TEST_ISOLATION', None)

    started = datetime.now(timezone.utc)
    proc = subprocess.run(
        [
            sys.executable,
            '-m',
            'pytest',
            *args.tests,
            '-q',
            '--no-header',
            '-p',
            'no:cacheprovider',
            f'--basetemp={basetemp}',
        ],
        cwd=str(BACKEND),
        env=env,
        capture_output=True,
        text=True,
    )
    finished = datetime.now(timezone.utc)

    after = _git_state(WATCHED_PATHS)

    evidence = {
        'checkpoint': 'P2_TEST_ISOLATION',
        'generated_at': finished.isoformat(),
        'identity': identity,
        'database_url_host': f'127.0.0.1:{DISPOSABLE_PORT}',
        'password_source': 'backend/.env (not printed, not copied)',
        'eval_dir': str(eval_dir),
        'eval_dir_contents': sorted(p.name for p in eval_dir.glob('*')),
        'tests': args.tests,
        'exit_code': proc.returncode,
        'duration_seconds': round((finished - started).total_seconds(), 2),
        'tracked_paths_watched': list(WATCHED_PATHS),
        'tracked_paths_before': before,
        'tracked_paths_after': after,
        'tracked_paths_unchanged': before == after,
        'stdout_tail': proc.stdout.strip().splitlines()[-25:],
        'stderr_tail': proc.stderr.strip().splitlines()[-25:],
    }
    print(json.dumps(evidence, indent=2))

    if args.evidence:
        out = Path(args.evidence)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(evidence, indent=2), encoding='utf-8')

    if not evidence['tracked_paths_unchanged']:
        return 98
    return proc.returncode


if __name__ == '__main__':
    sys.exit(main())
