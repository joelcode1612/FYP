"""Run the clone-only project1 tests with credentials taken from `backend/.env`.

Why this exists
---------------
`tests/project1/test_result_store.py` and `test_model_assisted_route.py` skip at
module level unless two environment variables are present:

    PROJECT1_CLONE_URL        login as p1ai_engine  (then SET ROLE p1ai_runtime)
    PROJECT1_CLONE_ADMIN_URL  superuser, fixture setup only

Both must point at `project1_workflow_tests`. The credentials already exist in
`backend/.env`; nothing about them is secret here. This script derives the two
clone URLs by swapping only the database name, exports them for the test
process, and runs pytest. It never prints a URL or a password.

Refusing non-clone databases
----------------------------
The rewrite below hard-codes `project1_workflow_tests`. If that database is
absent the connection fails loudly rather than silently targeting `Dss`, so
this script cannot be used to point the tests at production.

Usage
-----
    python scripts/run_project1_clone_tests.py tests/project1 -q
    python scripts/run_project1_clone_tests.py tests/project1/test_result_store.py -q
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

CLONE = 'project1_workflow_tests'
ENV_PATH = Path(__file__).resolve().parents[1] / '.env'

# Which .env key supplies which test variable. Both are rewritten to CLONE.
SOURCES = {
    'PROJECT1_CLONE_URL': 'PROJECT1_RUNTIME_DATABASE_URL',   # p1ai_engine
    'PROJECT1_CLONE_ADMIN_URL': 'DATABASE_URL',              # superuser, fixtures
}

_URL = re.compile(r'(postgresql(?:\+\w+)?://[^:]+:[^@]+@[^:/]+:\d+)/[^?]+')


def _read_env() -> dict[str, str]:
    if not ENV_PATH.is_file():
        sys.exit(f'run_project1_clone_tests: {ENV_PATH} not found')
    values: dict[str, str] = {}
    for line in ENV_PATH.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, _, value = line.partition('=')
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def _to_clone(url: str) -> str:
    rewritten, count = _URL.subn(rf'\1/{CLONE}', url)
    if count != 1:
        sys.exit('run_project1_clone_tests: could not parse a database URL from .env')
    return rewritten


def main() -> int:
    env = _read_env()
    missing = [key for key in SOURCES.values() if not env.get(key)]
    if missing:
        sys.exit('run_project1_clone_tests: missing in .env: ' + ', '.join(missing))

    for test_var, env_key in SOURCES.items():
        os.environ[test_var] = _to_clone(env[env_key])

    try:
        import pytest
    except ModuleNotFoundError:
        sys.exit('run_project1_clone_tests: pytest not installed in this interpreter')

    args = sys.argv[1:] or ['tests/project1']
    return pytest.main(args)


if __name__ == '__main__':
    raise SystemExit(main())
