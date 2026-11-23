"""P3 regression evidence: run the suite under the isolated identity with JUnit XML.

``tools/p2_isolated_test_runner_20261122.py`` prints only the last 25 lines, which
is enough to prove a run happened but not enough to compare failure *identities*
against a baseline. This script reuses that runner's identity check verbatim and
adds ``--junitxml``, so the failing node-ids can be diffed rather than counted.

It does not weaken any guard: it calls ``_db_password()``, builds the same
port-5433 URL, and re-verifies the identity against the server before pytest
starts. ``tests/conftest.py::require_disposable_database`` still runs.

Usage::

    backend/.venv/Scripts/python.exe scripts/p3_regression_junit.py \
        --out ../var/evidence/p3_full.xml tests/project1
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
RUNNER = BACKEND / 'tools' / 'p2_isolated_test_runner_20261122.py'


def load_runner():
    spec = importlib.util.spec_from_file_location('p2_runner', RUNNER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--db', default='project1_disposable_app')
    parser.add_argument('--out', required=True)
    parser.add_argument('tests', nargs='+')
    args = parser.parse_args(argv)

    runner = load_runner()
    if args.db not in runner.DISPOSABLE_DATABASES:
        raise SystemExit(f'refusing: {args.db!r} is not a disposable database')

    password = runner._db_password()
    url = runner._database_url(password, args.db)
    identity = runner._verify_server_identity(url, args.db)
    print(f"identity verified: {identity['database']}@{identity['port']}")

    eval_dir = Path(tempfile.mkdtemp(prefix='p3-ml-eval-'))
    basetemp = Path(tempfile.mkdtemp(prefix='p3-pytest-bt-'))

    env = dict(os.environ)
    env['DATABASE_URL'] = url
    env['SITEWISE_ML_EVAL_DIR'] = str(eval_dir)
    env.pop('SITEWISE_TEST_ISOLATION', None)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    proc = subprocess.run(
        [sys.executable, '-m', 'pytest', *args.tests, '-q', '--no-header',
         '-p', 'no:cacheprovider', f'--basetemp={basetemp}',
         f'--junitxml={out}'],
        cwd=str(BACKEND), env=env, capture_output=True, text=True)

    tail = proc.stdout.strip().splitlines()[-4:]
    print('\n'.join(tail))
    print(f'junit: {out}')
    return proc.returncode


if __name__ == '__main__':
    raise SystemExit(main())
