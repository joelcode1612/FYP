"""N04-C governed application-path preflight.

Every check is either a real authenticated request to the running application or
a read of the authorization the application will consume. Two checks are
negative and must be refused for a named reason before the single dispatch is
trusted. Nothing here sends a provider request and nothing here issues a new
authorization.

Usage
-----
    python tools/n04c_preflight_route.py

The fresh authorization must already have been issued by
``tools/n04c_qg_live_attempt_http.py --issue-only``.
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))

import httpx  # noqa: E402
import psycopg2  # noqa: E402

from tools.n04c_qg_live_attempt_http import (  # noqa: E402
    ARTIFACT, AUTHORIZATION_GATE, COST_CEILING_USD, ENV_FILE,
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
STALE_CONTEXT = 'fa3cb714-5145-57e9-97cd-0af92da80f46'
EXPECTED_ADMISSION = 'ec67889d-b4ca-4553-8bba-899fb520ac91'
ADOPTED_PROMPT_SHA = (
    'a4d21e98a819749f7a0d1f9dea8cd1977e6da0fff60a4267e1124bdc101c55cb')
LEGACY_AUTHORIZATIONS = frozenset({
    '19ef5757-5570-5c87-8f58-cb44459e760d',
    'd7211b7e-39c0-5101-9a90-2a6da8c5835d',
})

DSN = ('host=127.0.0.1 port=5433 dbname=project1_workflow_tests '
       'user=postgres password=123456')

PASS, FAIL = 'PASS', 'FAIL'
results: list[tuple[str, str, str]] = []


def record(name: str, verdict: str, detail: str) -> None:
    results.append((name, verdict, detail))
    print(f'  [{verdict}] {name}\n         {detail}')


def ok(name: str, condition: bool, detail: str) -> None:
    record(name, PASS if condition else FAIL, detail)


def login() -> str:
    response = httpx.post(
        f'{IDENTITY}/auth/v1/token?grant_type=password',
        headers={'apikey': PUBLISHABLE},
        json={'email': EMAIL, 'password': PASSWORD}, timeout=15)
    response.raise_for_status()
    return response.json()['access_token']


def code_of(response: httpx.Response):
    if not response.content:
        return None
    try:
        return (response.json().get('detail') or {}).get('code')
    except (ValueError, AttributeError):
        return None


def generate(token: str, *, context_id: str, authorization_id: str) -> httpx.Response:
    return httpx.post(
        f'{API}/m2/assessments/{ASSESSMENT}/qg-candidates',
        headers={'Authorization': f'Bearer {token}'},
        json={'confirmation_id': CONFIRMATION, 'context_id': context_id,
              'objective_id': 'O1', 'proposal_id': PROPOSAL,
              'authorization_id': authorization_id},
        timeout=180)


def load_packet_hash(token: str, context_id: str) -> str | None:
    response = httpx.get(
        f'{API}/m2/assessments/{ASSESSMENT}/business-contexts/{context_id}',
        headers={'Authorization': f'Bearer {token}'}, timeout=60)
    if response.status_code != 200:
        return None
    return (response.json().get('packet') or {}).get('packet_hash')


def main() -> int:
    print('=== 0. fresh authorization artifact ===')
    if not ARTIFACT.is_file():
        record('authorization artifact exists', FAIL, str(ARTIFACT))
        return 2
    artifact = json.loads(ARTIFACT.read_text(encoding='utf-8'))
    authorization = str(artifact.get('authorization_id') or '')
    ok('authorization artifact exists', True, str(ARTIFACT))
    ok('fresh authorization id present', bool(authorization), authorization)
    ok('authorization is not a legacy run',
       authorization not in LEGACY_AUTHORIZATIONS, authorization)
    ok('authorization gate is this gate',
       artifact.get('authorization_gate') == AUTHORIZATION_GATE,
       f'{artifact.get("authorization_gate")}')
    ok('authorization is one attempt', artifact.get('max_attempts') == 1,
       f'max_attempts={artifact.get("max_attempts")}')
    ok('new request provenance records the output cap',
       artifact.get('max_tokens') == REQUIRED_MAX_TOKENS,
       f'max_tokens={artifact.get("max_tokens")}')
    ok('authorization cost ceiling is the adopted one',
       artifact.get('cost_ceiling_usd') == COST_CEILING_USD,
       f'USD {artifact.get("cost_ceiling_usd")}')
    ok('authorization prompt hash is adopted',
       artifact.get('prompt_sha256') == ADOPTED_PROMPT_SHA,
       str(artifact.get('prompt_version')))
    ok('authorization scope is candidate-only live test',
       artifact.get('scope') == 'LIVE_PROVIDER_CANDIDATE_TEST',
       str(artifact.get('scope')))
    ok('evaluation identity is derived from this authorization',
       authorization != '' and authorization in str(artifact.get('evaluation_id')),
       str(artifact.get('evaluation_id')))

    token = login()
    headers = {'Authorization': f'Bearer {token}'}

    print('\n=== 1. the application\'s own verdict on the current source ===')
    status_response = httpx.get(
        f'{API}/m2/assessments/{ASSESSMENT}/confirmations/{CONFIRMATION}'
        '/business-context-status', headers=headers, timeout=60)
    if status_response.status_code != 200:
        record('business-context status available', FAIL,
               f'{status_response.status_code} {status_response.text[:200]}')
        return 2
    status = status_response.json()
    current = status.get('context_id')
    ok('business-context status available', True,
       f'context {current}  status={status.get("status")}')
    ok('source is current', status.get('source_is_current') is True,
       f'compatible={status.get("context_compatible")}')
    ok('the current context is the one the admission cites',
       current == CURRENT_CONTEXT, f'expected {CURRENT_CONTEXT}, got {current}')
    packet_hash = load_packet_hash(token, str(current))
    ok('current packet hash is readable', bool(packet_hash), str(packet_hash))

    print('\n=== 2. admission and measurement authorization ===')
    eligibility_response = httpx.get(
        f'{API}/m2/assessments/{ASSESSMENT}/qg-eligibility',
        params={'objective_id': 'O1'}, headers=headers, timeout=60)
    if eligibility_response.status_code != 200:
        record('eligibility report available', FAIL,
               f'{eligibility_response.status_code}')
        return 2
    eligibility = eligibility_response.json()
    checks = {item['check_id']: item for item in eligibility.get('checks', [])}
    ok('objective admission is AUTHORITATIVE',
       checks.get('QG-ADM', {}).get('status') == PASS,
       f'admission={eligibility.get("admission_id")}  '
       f'status={checks.get("QG-ADM", {}).get("status")}')
    ok('admission is the operative one',
       eligibility.get('admission_id') == EXPECTED_ADMISSION,
       str(eligibility.get('admission_id')))
    ok('measurement id is version-bound',
       eligibility.get('measurement_id') == 'P1-MEAS-O1-CONCEPT-INTEREST'
       and eligibility.get('measurement_version') == '0.1-CAND',
       f'{eligibility.get("measurement_id")}@'
       f'{eligibility.get("measurement_version")}')
    measurement_failures = [
        key for key, item in checks.items()
        if key.startswith('MV-') and item.get('status') == FAIL]
    ok('no measurement requirement definitively failed',
       not measurement_failures, f'failures={measurement_failures}')
    ok('measurement format is an adopted fixed-option format',
       checks.get('MV-04', {}).get('status') == PASS,
       str(checks.get('MV-04', {}).get('evidence')))
    ok('synthetic-only measurement scope is disclosed, not hidden',
       checks.get('MV-10', {}).get('reason_code')
       == 'MEASUREMENT_SYNTHETIC_SCOPE_ONLY',
       f'dispatch_refusal={eligibility.get("dispatch_refusal")}')
    ok('preview never claims scientific acceptance or fielding',
       eligibility.get('scientifically_accepted') is False
       and eligibility.get('fielding_authorized') is False
       and eligibility.get('dispatches_model') is False,
       f'scientific={eligibility.get("scientifically_accepted")}  '
       f'fielding={eligibility.get("fielding_authorized")}')

    print('\n=== 3. route refusals that must happen before any dispatch ===')
    stale = generate(token, context_id=STALE_CONTEXT,
                     authorization_id=authorization)
    ok('stale context refused by the binding',
       stale.status_code == 409
       and code_of(stale) == 'QG_BINDING_CONTEXT_NOT_ADMITTED',
       f'{stale.status_code} {code_of(stale)}')
    unknown = generate(token, context_id=str(current),
                       authorization_id='00000000-0000-0000-0000-000000000000')
    ok('unknown authorization refused',
       unknown.status_code == 404
       and code_of(unknown) == 'QG_AUTHORIZATION_NOT_FOUND',
       f'{unknown.status_code} {code_of(unknown)}')

    print('\n=== 4. authorization row the attempt will consume ===')
    with psycopg2.connect(DSN) as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT authorization_id, assessment_id, context_id,
                   context_packet_hash, objective_id, objective_admission_id,
                   measurement_id, measurement_version, prompt_version,
                   prompt_sha256, consumed_at, consumed_candidate_id,
                   expires_at, issued_at
              FROM m2_qg_authorizations WHERE authorization_id=%s
        """, (authorization,))
        row = cur.fetchone()
    if row is None:
        record('authorization exists', FAIL, 'no row')
        return 2
    (auth_id, assessment_id, context_id, auth_packet_hash, objective_id,
     admission_id, measurement_id, measurement_version, prompt_version,
     prompt_sha, consumed_at, consumed_candidate_id, expires_at, issued_at) = row
    ok('authorization exists', str(auth_id) == authorization, str(auth_id))
    ok('authorization is unconsumed', consumed_at is None
       and consumed_candidate_id is None, f'consumed_at={consumed_at}')
    ok('authorization is unexpired',
       expires_at is None or expires_at > datetime.now(timezone.utc),
       f'expires_at={expires_at}')
    ok('authorization binds this assessment',
       str(assessment_id) == ASSESSMENT, str(assessment_id))
    ok('authorization binds the current context',
       str(context_id) == str(current), str(context_id))
    ok('authorization cites the current packet',
       auth_packet_hash == packet_hash,
       f'{auth_packet_hash} vs {packet_hash}')
    ok('authorization cites objective O1', objective_id == 'O1',
       str(objective_id))
    ok('authorization cites the operative admission',
       str(admission_id) == eligibility.get('admission_id'),
       str(admission_id))
    ok('authorization cites the resolved measurement',
       measurement_id == eligibility.get('measurement_id')
       and measurement_version == eligibility.get('measurement_version'),
       f'{measurement_id}@{measurement_version}')
    ok('authorization prompt hash is the adopted one',
       prompt_sha == ADOPTED_PROMPT_SHA, f'{prompt_version} {prompt_sha[:16]}…')

    print('\n=== 5. effective provider configuration and budget ===')
    load_environment(ENV_FILE)
    config = provider_configuration()
    ok('provider enabled by the application environment',
       config['enabled'] is True, f'from {ENV_FILE.name}')
    ok('model is the adopted one', config['model'] == REQUIRED_MODEL,
       config['model'])
    ok('timeout is the adopted 90 s',
       config['timeout'] == REQUIRED_TIMEOUT_SECONDS,
       f'{config["timeout"]}s')
    ok('max_tokens is the provisional application-path cap',
       config['max_tokens'] == REQUIRED_MAX_TOKENS,
       f'{config["max_tokens"]} (configured {config["configured_max_tokens"]})')
    ok('cost ceiling is the adopted 0.50',
       config['ceiling'] == COST_CEILING_USD,
       f'USD {config["ceiling"]} (configured {config["configured_ceiling"]})')

    from sitewise.project1 import budget
    budget_status = budget.status()
    ok('global budget ledger is internally consistent',
       budget_status['limit_matches_authorized'] is True,
       f'{budget_status["spent"]}/{budget_status["authorized_limit"]}')
    ok('one attempt remains in the global budget',
       budget_status['remaining'] >= 1,
       f'remaining={budget_status["remaining"]}')

    print('\n=== summary ===')
    failed = [name for name, verdict, _ in results if verdict == FAIL]
    print(f'  {len(results) - len(failed)}/{len(results)} checks passed')
    if failed:
        print('  FAILED: ' + '; '.join(failed))
        return 2
    print('  PREFLIGHT PASS — one fresh authorization is bound to the current '
          'source, the route refuses the negative cases, and the provider is '
          'configured exactly as authorized.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
