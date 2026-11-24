"""The single governed N04-C application-path POST.

This script does not issue authorizations and cannot enable the provider. It
refuses unless the fresh one-attempt authorization and the effective application
configuration both satisfy the adopted gate, then makes exactly one authenticated
request through the FastAPI route. There is no retry and no fallback.

Usage
-----
    python tools/n04c_dispatch_once.py

Run ``tools/n04c_preflight_route.py`` first and require PREFLIGHT PASS.
"""
from __future__ import annotations

import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))

import httpx  # noqa: E402
import psycopg2  # noqa: E402

from tools.n04c_qg_live_attempt_http import (  # noqa: E402
    ARTIFACT, AUTHORIZATION_GATE, COST_CEILING_USD, DSN, ENV_FILE,
    REQUIRED_MAX_TOKENS, REQUIRED_MODEL, REQUIRED_TIMEOUT_SECONDS,
    load_environment, provider_configuration)

IDENTITY = 'http://127.0.0.1:54329'
API = 'http://127.0.0.1:8092/api/v1'
PUBLISHABLE = 'sb_publishable_local_e2e'
EMAIL = 'gatebc-e2e-b9e62014@example.invalid'
PASSWORD = 'e2e-local-password'

ASSESSMENT = '053b3768-145b-4d4a-a880-e98174adcd94'
CONFIRMATION = 'd2453af1-70e8-4be6-9fbe-20fe5e41b357'
PROPOSAL = '662b8518-89a2-56a5-940f-5d44adcc86d4'
CURRENT_CONTEXT = '80dbc244-e55b-504c-b472-1c133de27229'
LEGACY_AUTHORIZATIONS = frozenset({
    '19ef5757-5570-5c87-8f58-cb44459e760d',
    'd7211b7e-39c0-5101-9a90-2a6da8c5835d',
})
RESULT = BACKEND / 'var' / 'e2e' / 'n04c_governed_app_path_result.json'


def refuse(code: str, detail: str) -> int:
    print('\n=== DISPATCH REFUSED ===')
    print(f'  code   {code}')
    print(f'  detail {detail}')
    return 6


def load_authorization() -> tuple[str, dict]:
    artifact = json.loads(ARTIFACT.read_text(encoding='utf-8'))
    authorization = str(artifact.get('authorization_id') or '')
    if not authorization:
        raise ValueError('QG_AUTHORIZATION_ARTIFACT_ID_MISSING')
    if authorization in LEGACY_AUTHORIZATIONS:
        raise ValueError('QG_LEGACY_AUTHORIZATION_REUSED')
    if artifact.get('authorization_gate') != AUTHORIZATION_GATE:
        raise ValueError('QG_AUTHORIZATION_GATE_MISMATCH')
    if artifact.get('max_tokens') != REQUIRED_MAX_TOKENS:
        raise ValueError('PROVIDER_MAX_TOKENS_NOT_ADOPTED')
    if artifact.get('cost_ceiling_usd') != COST_CEILING_USD:
        raise ValueError('PROVIDER_COST_CEILING_NOT_ADOPTED')
    if artifact.get('max_attempts') != 1:
        raise ValueError('QG_AUTHORIZATION_NOT_SINGLE_ATTEMPT')
    return authorization, artifact


def unconsumed(authorization: str) -> bool:
    with psycopg2.connect(DSN) as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT consumed_at, consumed_candidate_id
              FROM m2_qg_authorizations WHERE authorization_id=%s
        """, (authorization,))
        row = cur.fetchone()
    return row is not None and row[0] is None and row[1] is None


def main() -> int:
    try:
        authorization, artifact = load_authorization()
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return refuse('QG_AUTHORIZATION_ARTIFACT_INVALID', str(exc))

    load_environment(ENV_FILE)
    config = provider_configuration()
    if not config['enabled']:
        return refuse('PROVIDER_NOT_ENABLED', str(ENV_FILE))
    if config['model'] != REQUIRED_MODEL:
        return refuse('PROVIDER_MODEL_NOT_AS_ADOPTED', config['model'])
    if config['timeout'] != REQUIRED_TIMEOUT_SECONDS:
        return refuse('PROVIDER_TIMEOUT_NOT_AS_ADOPTED', str(config['timeout']))
    if config['max_tokens'] != REQUIRED_MAX_TOKENS:
        return refuse('PROVIDER_MAX_TOKENS_NOT_ADOPTED',
                      str(config['max_tokens']))
    if config['ceiling'] != COST_CEILING_USD:
        return refuse('PROVIDER_COST_CEILING_NOT_ADOPTED',
                      str(config['ceiling']))
    if not unconsumed(authorization):
        return refuse('QG_AUTHORIZATION_CONSUMED', authorization)

    token = httpx.post(
        f'{IDENTITY}/auth/v1/token?grant_type=password',
        headers={'apikey': PUBLISHABLE},
        json={'email': EMAIL, 'password': PASSWORD}, timeout=15
    ).json()['access_token']

    payload = {'confirmation_id': CONFIRMATION, 'context_id': CURRENT_CONTEXT,
               'objective_id': 'O1', 'proposal_id': PROPOSAL,
               'authorization_id': authorization}
    started = datetime.now(timezone.utc)
    clock = time.monotonic()
    try:
        # The only provider-reaching call in this process. No loop, no retry.
        response = httpx.post(
            f'{API}/m2/assessments/{ASSESSMENT}/qg-candidates',
            headers={'Authorization': f'Bearer {token}'}, json=payload,
            timeout=180)
        elapsed = time.monotonic() - clock
        try:
            body = response.json()
        except ValueError:
            body = {'unparsed': response.text[:4000]}
        record = {
            'dispatched_at': started.isoformat(),
            'elapsed_seconds': round(elapsed, 3),
            'http_status': response.status_code,
            'request': payload,
            'authorization_artifact': artifact,
            'provider_configuration': config,
            'response': body,
        }
    except Exception as exc:  # noqa: BLE001 - the genuine transport outcome
        record = {
            'dispatched_at': started.isoformat(),
            'elapsed_seconds': round(time.monotonic() - clock, 3),
            'http_status': None,
            'request': payload,
            'authorization_artifact': artifact,
            'provider_configuration': config,
            'transport_error': f'{type(exc).__name__}: {exc}',
        }

    RESULT.write_text(json.dumps(record, indent=2, default=str), encoding='utf-8')
    print(json.dumps(record, indent=2, default=str)[:8000])
    ok = record.get('http_status') == 200 and \
        (record.get('response') or {}).get('outcome') in {
            'CANDIDATE_VALIDATED', 'ABSTAINED_BY_MODEL'}
    print('\nresult:', 'SUCCESS' if ok else 'NOT A SUCCESS')
    print('evidence:', RESULT)
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
