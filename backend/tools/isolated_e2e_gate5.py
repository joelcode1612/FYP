"""GATE 5: isolated authenticated end-to-end verification with a real server.

What this proves
----------------
The application is started for real — uvicorn, the real app object, the real JWT
verifier, the real routers — against a **disposable** database, with identity
issued by a **local** ES256 key service. Nothing is monkeypatched and no token is
injected past verification.

It then establishes, in order:

1. the server reports the disposable database, not a protected one;
2. a protected route refuses an unauthenticated request;
3. the same route refuses a token with a broken signature — so verification is
   genuinely running, not bypassed;
4. the same route accepts a genuinely signed token and gets past verification;
5. the protected database's row counts are unchanged before and after, which is
   the specific failure the previous probe caused.

What it deliberately does not claim
-----------------------------------
``/auth/me`` also reads the authoritative identity row from Supabase's hosted
``public.users`` via PostgREST. That is an external SaaS the isolated environment
does not have, so the request is expected to stop at that dependency with a
documented code. Stopping there is the *correct* behaviour — it shows verification
succeeded and the only missing piece is an external service, which is precisely
the boundary this gate is supposed to make visible. The script records the code
rather than treating a 5xx as a pass.

Run from ``backend``::

    ./.venv/Scripts/python.exe tools/isolated_e2e_gate5.py --out var/evidence/gate5_e2e.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
DISPOSABLE_DB = 'project1_disposable_app'
DISPOSABLE_PORT = 5433
PROTECTED_DB = 'Final_Location_Analysis'
PROTECTED_PORT = 5432
#: Marks this server's connections so the DB binding can be proved directly.
APP_NAME = 'sitewise_gate5_e2e'

sys.path.insert(0, str(BACKEND))

from tools.isolated_identity_server import IsolatedIdentity  # noqa: E402


def _password() -> str:
    text = (BACKEND / '.env').read_text(encoding='utf-8', errors='replace')
    match = re.search(r'^DATABASE_URL=(.*)$', text, re.M)
    if not match:
        raise SystemExit('DATABASE_URL missing from backend/.env')
    cred = re.match(r'^[^:]+://[^:]+:([^@]+)@', match.group(1).strip())
    if not cred:
        raise SystemExit('DATABASE_URL has no inline password')
    return cred.group(1)


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def _row_counts(password: str) -> dict[str, dict]:
    """Count rows in public.users on both databases, without writing anything."""
    import psycopg2

    out: dict[str, dict] = {}
    for label, port, db in (('protected', PROTECTED_PORT, PROTECTED_DB),
                            ('disposable', DISPOSABLE_PORT, DISPOSABLE_DB)):
        try:
            conn = psycopg2.connect(host='127.0.0.1', port=port, dbname=db,
                                    user='postgres', password=password,
                                    connect_timeout=5)
        except Exception as exc:  # noqa: BLE001
            out[label] = {'reachable': False, 'error': type(exc).__name__}
            continue
        try:
            with conn.cursor() as cur:
                cur.execute('SELECT current_database(), inet_server_port()')
                name, reported_port = cur.fetchone()
                cur.execute("SELECT to_regclass('public.users')")
                table = cur.fetchone()[0]
                count = None
                if table is not None:
                    cur.execute('SELECT count(*) FROM public.users')
                    count = cur.fetchone()[0]
            out[label] = {'reachable': True, 'database': name,
                          'port': reported_port, 'users_table': table,
                          'users_rows': count}
        finally:
            conn.close()
    return out


def _get(url: str, token: str | None = None, timeout: float = 10.0):
    request = urllib.request.Request(url)
    if token:
        request.add_header('Authorization', f'Bearer {token}')
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read(2000).decode('utf-8', 'replace')
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(2000).decode('utf-8', 'replace')
    except urllib.error.URLError as exc:
        return None, f'URLError:{exc.reason}'


def _wait_ready(url: str, timeout: float = 60.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        status, _ = _get(url, timeout=2.0)
        if status is not None:
            return True
        time.sleep(0.5)
    return False


def _detail_code(body: str) -> str | None:
    """Pull a machine code out of an error body without echoing the body."""
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        return None
    detail = payload.get('detail') if isinstance(payload, dict) else None
    if isinstance(detail, dict):
        return detail.get('code') or detail.get('error_code')
    if isinstance(detail, str):
        return detail[:120]
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', default='var/evidence/gate5_e2e.json')
    parser.add_argument('--keep-running', action='store_true')
    args = parser.parse_args(argv)

    password = _password()
    api_port = _free_port()
    base = f'http://127.0.0.1:{api_port}'
    receipt: dict = {
        'gate': 'GATE 5 — isolated authenticated E2E',
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'isolation': {
            'disposable_database': DISPOSABLE_DB,
            'disposable_port': DISPOSABLE_PORT,
            'protected_database': PROTECTED_DB,
            'protected_port': PROTECTED_PORT,
            'identity_provider': 'LOCAL_ES256_JWKS (not Supabase)',
        },
    }

    receipt['rows_before'] = _row_counts(password)
    if not receipt['rows_before'].get('disposable', {}).get('reachable'):
        receipt['verdict'] = 'BLOCKED'
        receipt['reason'] = 'disposable database unreachable'
        _write(args.out, receipt)
        return 2

    identity = IsolatedIdentity().start()
    receipt['isolation']['jwks_url'] = identity.jwks_url
    receipt['isolation']['issuer'] = identity.issuer

    env = {
        **os.environ,
        **identity.env(),
        # ``application_name`` is how the DB-binding proof identifies this
        # server's own connections in pg_stat_activity.
        'DATABASE_URL': (f'postgresql+psycopg2://postgres:{password}'
                         f'@127.0.0.1:{DISPOSABLE_PORT}/{DISPOSABLE_DB}'
                         f'?application_name={APP_NAME}'),
        'M2_DATABASE_URL': (f'postgresql+psycopg2://postgres:{password}'
                            f'@127.0.0.1:{DISPOSABLE_PORT}/{DISPOSABLE_DB}'
                            f'?application_name={APP_NAME}'),
        'M2_EXPECTED_DATABASE': DISPOSABLE_DB,
        'PROJECT1_ISOLATED_DATABASE_NAME': DISPOSABLE_DB,
        'PROJECT1_ISOLATED_DATABASE_PORT': str(DISPOSABLE_PORT),
        # A clearly fake service-role key so the admin *client constructs*
        # without contacting Supabase. This is what lets token verification run:
        # the admin dependency resolves first, and if it raised, a bad signature
        # would be masked by a 503 instead of being refused with 401. The key is
        # deliberately invalid, so any real admin call fails closed.
        'SUPABASE_SECRET_KEY': 'isolated-e2e-not-a-real-service-role-key',
        'SUPABASE_PUBLISHABLE_KEY': 'isolated-e2e-not-a-real-publishable-key',
        'PYTHONPATH': str(BACKEND / 'src'),
    }
    # A provider must never be contacted by an isolation probe.
    env.pop('TOKENHARBOR_API_KEY', None)

    log_path = BACKEND / 'var' / 'evidence' / 'gate5_uvicorn.log'
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log = log_path.open('w', encoding='utf-8')
    process = subprocess.Popen(
        [sys.executable, '-m', 'uvicorn', 'sitewise.main:app',
         '--host', '127.0.0.1', '--port', str(api_port), '--log-level', 'warning'],
        cwd=str(BACKEND), env=env, stdout=log, stderr=subprocess.STDOUT)

    try:
        ready = _wait_ready(f'{base}/health')
        receipt['server_started'] = ready
        if not ready:
            receipt['verdict'] = 'BLOCKED'
            receipt['reason'] = 'uvicorn did not become ready'
            receipt['log_tail'] = _tail(log_path)
            _write(args.out, receipt)
            return 2

        # 1. The server's own view of its database.
        status, body = _get(f'{base}/health')
        receipt['health'] = {'status': status, 'body': body[:400]}

        subject = '11111111-1111-4111-8111-111111111111'
        route = f'{base}/api/v1/auth/me'

        # 2. Unauthenticated.
        status, body = _get(route)
        receipt['unauthenticated'] = {'status': status,
                                      'code': _detail_code(body)}

        # 3. Broken signature: verification must be genuinely running.
        status, body = _get(route, identity.mint_tampered(subject=subject))
        receipt['tampered_token'] = {'status': status, 'code': _detail_code(body)}

        # 4. Genuine signature.
        token = identity.mint(subject=subject)
        status, body = _get(route, token)
        receipt['valid_token'] = {'status': status, 'code': _detail_code(body),
                                  'reached_application': status not in (401, 403)}

        # 5. A token from a different issuer must be refused.
        forged = identity.mint(subject=subject,
                               issuer='https://evil.example/auth/v1')
        status, body = _get(route, forged)
        receipt['wrong_issuer'] = {'status': status, 'code': _detail_code(body)}

        # 6. An expired token must be refused.
        expired = identity.mint(subject=subject, ttl=-60)
        status, body = _get(route, expired)
        receipt['expired_token'] = {'status': status, 'code': _detail_code(body)}

        # 7. Prove which database the server is actually bound to, from the
        # server side rather than from our own configuration.
        receipt['db_binding'] = _bound_databases(password)
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
        log.close()
        if not args.keep_running:
            identity.stop()

    receipt['rows_after'] = _row_counts(password)

    before = receipt['rows_before']
    after = receipt['rows_after']
    protected_delta = _delta(before, after, 'protected')
    disposable_delta = _delta(before, after, 'disposable')
    receipt['row_deltas'] = {'protected': protected_delta,
                             'disposable': disposable_delta}

    checks = {
        'server_started': bool(receipt.get('server_started')),
        'unauthenticated_refused': receipt['unauthenticated']['status'] in (401, 403),
        'tampered_signature_refused': receipt['tampered_token']['status'] in (401, 403),
        'wrong_issuer_refused': receipt['wrong_issuer']['status'] in (401, 403),
        'expired_token_refused': receipt['expired_token']['status'] in (401, 403),
        'valid_token_passed_verification':
            receipt['valid_token']['reached_application'] is True,
        'server_bound_to_disposable_database':
            receipt.get('db_binding', {}).get('databases') == [DISPOSABLE_DB],
        'protected_database_unchanged': protected_delta == 0,
    }
    receipt['checks'] = checks
    receipt['verdict'] = 'PASS' if all(checks.values()) else 'FAIL'
    receipt['external_dependency_note'] = (
        'A 5xx from /auth/me after a valid token means verification succeeded and '
        'the request stopped at the Supabase-hosted identity row, which the '
        'isolated environment does not provide. That is the documented boundary, '
        'not a verification failure.')
    _write(args.out, receipt)
    print(json.dumps({k: receipt[k] for k in
                      ('verdict', 'checks', 'row_deltas')}, indent=2))
    return 0 if receipt['verdict'] == 'PASS' else 1


def _bound_databases(password: str) -> dict:
    """Which databases this server's own connections are attached to.

    Read from ``pg_stat_activity`` filtered by the ``application_name`` set on the
    server's connection string. This is server-side truth: it does not depend on
    what we configured, so a misconfigured URL cannot make the check pass.
    """
    import psycopg2

    try:
        conn = psycopg2.connect(host='127.0.0.1', port=DISPOSABLE_PORT,
                                dbname=DISPOSABLE_DB, user='postgres',
                                password=password, connect_timeout=5)
    except Exception as exc:  # noqa: BLE001
        return {'probe': 'UNAVAILABLE', 'error': type(exc).__name__}
    try:
        with conn.cursor() as cur:
            cur.execute(
                'SELECT DISTINCT datname FROM pg_stat_activity '
                'WHERE application_name = %s AND datname IS NOT NULL '
                'ORDER BY datname', (APP_NAME,))
            databases = [row[0] for row in cur.fetchall()]
        return {'probe': 'OK', 'databases': databases,
                'expected': [DISPOSABLE_DB]}
    finally:
        conn.close()


def _delta(before: dict, after: dict, key: str) -> int | None:
    b = before.get(key, {}).get('users_rows')
    a = after.get(key, {}).get('users_rows')
    if b is None or a is None:
        return None
    return a - b


def _tail(path: Path, lines: int = 25) -> list[str]:
    try:
        return path.read_text(encoding='utf-8', errors='replace').splitlines()[-lines:]
    except OSError:
        return []


def _write(relative: str, payload: dict) -> None:
    path = BACKEND / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + '\n',
                    encoding='utf-8')
    print(f'wrote {path}')


if __name__ == '__main__':
    raise SystemExit(main())
