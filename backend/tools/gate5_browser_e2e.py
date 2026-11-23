"""GATE 5 browser layer: run the built SPA against the isolated backend.

Starts the same isolated stack as ``tools/isolated_e2e_gate5.py`` — real uvicorn,
real JWT verifier, local ES256 identity, disposable database — then drives the
**built** Jaspr bundle in headless Chromium through a static+proxy server.

What the probe can and cannot show
----------------------------------
Probe A loads the report route with no session. That is genuine evidence: the
route guard refuses an anonymous load and no report data is fetched.

Probes B and C load it with the stand-in bridge from ``tool/session_harness.js``.
That bridge fabricates a session, so those probes say **what the page renders**
and nothing about authorisation. They are labelled ``STANDIN_HARNESS`` in the
receipt and must never be cited as authenticated-E2E evidence.

The reason a genuine authenticated browser run is not attempted here: the SPA's
shipped auth bridge is ``auth_bundle.js``, which obtains a session from Supabase's
hosted auth service. The isolated stack has no Supabase, and
``isolated_e2e_gate5.py`` already established that ``/auth/me`` stops at the
Supabase-hosted identity row with a documented 503. Feeding the browser a token by
other means would be exactly the token injection this gate forbids.

Run from ``backend``::

    ./.venv/Scripts/python.exe tools/gate5_browser_e2e.py --out var/evidence/gate5_browser.json
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
DISPOSABLE_DB = 'project1_disposable_app'
DISPOSABLE_PORT = 5433
APP_NAME = 'sitewise_gate5_browser'

sys.path.insert(0, str(BACKEND))

from tools.isolated_identity_server import IsolatedIdentity  # noqa: E402


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def _password() -> str:
    import re
    text = (BACKEND / '.env').read_text(encoding='utf-8', errors='replace')
    match = re.search(r'^DATABASE_URL=(.*)$', text, re.M)
    if not match:
        raise SystemExit('DATABASE_URL missing from backend/.env')
    inner = re.search(r':([^:@/]+)@', match.group(1))
    if not inner:
        raise SystemExit('DATABASE_URL has no inline password')
    return inner.group(1)


def _wait_ready(url: str, timeout: float = 90.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=3) as r:
                if r.status < 500:
                    return True
        except Exception:
            time.sleep(0.7)
    return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', default='var/evidence/gate5_browser.json')
    args = parser.parse_args(argv)

    password = _password()
    api_port = _free_port()
    base = f'http://127.0.0.1:{api_port}'
    receipt: dict = {
        'gate': 'GATE 5 — browser layer',
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'backend': base,
        'disposable_database': DISPOSABLE_DB,
    }

    identity = IsolatedIdentity().start()
    env = {
        **os.environ,
        **identity.env(),
        'DATABASE_URL': (f'postgresql+psycopg2://postgres:{password}'
                         f'@127.0.0.1:{DISPOSABLE_PORT}/{DISPOSABLE_DB}'
                         f'?application_name={APP_NAME}'),
        'M2_DATABASE_URL': (f'postgresql+psycopg2://postgres:{password}'
                            f'@127.0.0.1:{DISPOSABLE_PORT}/{DISPOSABLE_DB}'
                            f'?application_name={APP_NAME}'),
        'M2_EXPECTED_DATABASE': DISPOSABLE_DB,
        'PROJECT1_ISOLATED_DATABASE_NAME': DISPOSABLE_DB,
        'PROJECT1_ISOLATED_DATABASE_PORT': str(DISPOSABLE_PORT),
        'SUPABASE_SECRET_KEY': 'isolated-e2e-not-a-real-service-role-key',
        'SUPABASE_PUBLISHABLE_KEY': 'isolated-e2e-not-a-real-publishable-key',
        'PYTHONPATH': str(BACKEND / 'src'),
    }
    env.pop('TOKENHARBOR_API_KEY', None)

    log_path = BACKEND / 'var' / 'evidence' / 'gate5_browser_uvicorn.log'
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log = log_path.open('w', encoding='utf-8')
    process = subprocess.Popen(
        [sys.executable, '-m', 'uvicorn', 'sitewise.main:app',
         '--host', '127.0.0.1', '--port', str(api_port), '--log-level', 'warning'],
        cwd=str(BACKEND), env=env, stdout=log, stderr=subprocess.STDOUT)

    out_path = BACKEND.parent / 'deliverables' / 'PROJECT1_REPORT_BROWSER_E2E_RESULTS.json'
    try:
        ready = _wait_ready(f'{base}/health')
        receipt['server_started'] = ready
        if not ready:
            receipt['verdict'] = 'BLOCKED'
            receipt['reason'] = 'isolated backend did not become ready'
        else:
            node = subprocess.run(
                ['node', str(BACKEND / 'tools' / 'gate5_browser_probe.js'),
                 '--api', base, '--port', str(_free_port())],
                capture_output=True, text=True, timeout=300,
                cwd=str(REPO))
            receipt['node_exit'] = node.returncode
            if node.returncode != 0:
                receipt['node_stderr'] = node.stderr[-2000:]
            try:
                receipt['probe'] = json.loads(node.stdout)
            except Exception:
                receipt['probe_raw'] = node.stdout[-3000:]

            probes = (receipt.get('probe') or {}).get('probes') or []
            by_label = {p['label']: p for p in probes}
            anonymous = by_label.get('A_anonymous', {})
            standin = by_label.get('B_standin_session', {})
            selector = by_label.get('C_selector_standin_session', {})

            checks = {
                'anonymous_load_refused': (
                    anonymous.get('final_path', '') != '/entrepreneur/cafe-report/view'),
                'anonymous_fetched_no_report_data': all(
                    c['status'] >= 400 for c in anonymous.get('api_calls', [])) or not
                    anonymous.get('api_calls'),
                'standin_renders_no_measurement': not standin.get('renders_a_measurement'),
                'selector_renders_no_measurement': not selector.get('renders_a_measurement'),
            }
            receipt['checks'] = checks
            receipt['verdict'] = 'PASS' if all(checks.values()) else 'FAIL'
            receipt['claim_scope'] = (
                'Probe A evidences the anonymous guard. Probes B/C evidence rendered '
                'output under a fabricated session and evidence nothing about '
                'authorisation.')
    finally:
        process.terminate()
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()
        log.close()
        identity.stop()

    out_path.write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    print(json.dumps({k: receipt.get(k) for k in
                      ('verdict', 'checks', 'server_started', 'node_exit')}, indent=2))
    return 0 if receipt.get('verdict') == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
