"""N04-C — live QG attempt driven by a real authenticated session.

The first attempt used a hardcoded actor. This runner derives the actor from an
access token issued by the identity service, proves that identity against an
authenticated API, and only then builds the adapter chain.

Nothing is dispatched unless ``--dispatch`` is passed. The default is a dry run
that exercises every gate up to, but not including, the provider call.

Usage
-----
    python tools/n04c_qg_live_attempt_http.py            # dry run
    python tools/n04c_qg_live_attempt_http.py --dispatch # one real attempt

The token is read from ``var/e2e/n04c_token.json`` when present, otherwise
obtained by password grant. In both cases the actor is taken from the identity
service's own answer for that token, never from a constant.
"""
from __future__ import annotations

import json
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))

import httpx  # noqa: E402
import psycopg2  # noqa: E402
from sqlalchemy import create_engine, text  # noqa: E402

IDENTITY = 'http://127.0.0.1:54329'
API = 'http://127.0.0.1:8092'
PUBLISHABLE = 'sb_publishable_local_e2e'
EMAIL = 'gatebc-e2e-b9e62014@example.invalid'
PASSWORD = 'e2e-local-password'
TOKEN_FILE = BACKEND / 'var' / 'e2e' / 'n04c_token.json'

ASSESSMENT = '053b3768-145b-4d4a-a880-e98174adcd94'
PROPOSAL = '662b8518-89a2-56a5-940f-5d44adcc86d4'
CONFIRMATION = 'd2453af1-70e8-4be6-9fbe-20fe5e41b357'
OBJECTIVE = 'O1'
ARTIFACT = BACKEND / 'var' / 'n04c_qg_authorization.json'
COST_CEILING_USD = 0.50
#: The owner-adopted budget for the retest, after the 30 s attempt timed out.
#: Verified below against the value the provider object actually holds.
REQUIRED_TIMEOUT_SECONDS = 90

DSN = ('host=127.0.0.1 port=5433 dbname=project1_workflow_tests '
       'user=postgres password=123456')
M2_URL = ('postgresql+psycopg2://p1_m2_runtime:m2_runtime_dev_only'
          '@127.0.0.1:5433/project1_workflow_tests')
RUNTIME_URL = ('postgresql+psycopg2://p1ai_engine:p1ai_engine_dev_only'
               '@127.0.0.1:5433/project1_workflow_tests')

#: The configuration the application itself is launched with. This script used
#: to set ``TOKENHARBOR_ENABLED`` and the timeout in its own process, which made
#: it a way around the deployment switch: it could dispatch while the
#: application said the provider was off. It now adopts the same file the app
#: reads, so "the provider is enabled" is a fact about the environment rather
#: than something this process can decide for itself.
ENV_FILE = BACKEND / 'var' / 'e2e' / 'app.env'

#: The model the owner authorised. Asserted, never selected here: a script that
#: could choose its own model would make the authorization meaningless.
REQUIRED_MODEL = 'deepseek-v4.1-flash-1017'
#: Provisional Direct-QG evaluation cap. Not a production default; the
#: application config must adopt it explicitly before a dispatch is allowed.
REQUIRED_MAX_TOKENS = 12000
#: A new authorization family for the governed isolated application-path gate.
#: Earlier authorizations remain in the ledger untouched; this discriminator
#: makes a fresh one-attempt authorization identity unavoidable.
AUTHORIZATION_GATE = 'n04c-app-path-12000-v1'


def load_environment(path: Path) -> None:
    """Adopt the application's configuration, overriding this shell's."""
    if not path.is_file():
        raise SystemExit(f'REFUSED: configuration file not found: {path}')
    for raw in path.read_text(encoding='utf-8').splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in '"\'':
            value = value[1:-1]
        os.environ[key.strip()] = value


def provider_configuration() -> dict:
    """The effective provider settings, read rather than assumed."""
    from sitewise.core.config import (
        provider_cost_ceiling_usd, provider_max_tokens,
        provider_timeout_seconds, settings)
    from sitewise.project1.provider import MODEL
    return {'enabled': bool(settings.tokenharbor_enabled), 'model': MODEL,
            'timeout': provider_timeout_seconds(),
            'max_tokens': provider_max_tokens(),
            'configured_max_tokens': settings.tokenharbor_max_tokens,
            'ceiling': provider_cost_ceiling_usd(),
            'configured_ceiling': settings.tokenharbor_cost_ceiling_usd}



def access_token() -> str:
    if TOKEN_FILE.is_file():
        payload = json.loads(TOKEN_FILE.read_text(encoding='utf-8'))
        if payload.get('access_token'):
            return payload['access_token']
    response = httpx.post(f'{IDENTITY}/auth/v1/token?grant_type=password',
                          headers={'apikey': PUBLISHABLE},
                          json={'email': EMAIL, 'password': PASSWORD}, timeout=10)
    response.raise_for_status()
    payload = response.json()
    TOKEN_FILE.write_text(json.dumps(payload), encoding='utf-8')
    return payload['access_token']


def authenticated_actor(token: str) -> str:
    """Ask the identity service who this token belongs to.

    This is the whole point of the exercise: the actor is an answer, not a
    constant. ``/auth/v1/user`` is the same call the application makes.
    """
    response = httpx.get(f'{IDENTITY}/auth/v1/user',
                         headers={'apikey': PUBLISHABLE,
                                  'Authorization': f'Bearer {token}'}, timeout=10)
    response.raise_for_status()
    user = response.json()
    actor = user.get('id') or (user.get('user') or {}).get('id')
    if not actor:
        raise SystemExit('identity service returned no user id')
    return str(actor)


def prove_api_access(token: str) -> dict:
    """One authenticated read, so the session is demonstrably usable."""
    response = httpx.get(
        f'{API}/api/v1/m2/assessments/{ASSESSMENT}/qg-candidates',
        headers={'Authorization': f'Bearer {token}'}, timeout=15)
    if response.status_code != 200:
        raise SystemExit(f'authenticated read failed: {response.status_code} '
                         f'{response.text[:200]}')
    return response.json()


def read_source_verdict(token: str, confirmation_id: str) -> dict:
    """The application's own verdict on which BCB snapshot is current.

    Deliberately not computed here. A local query could agree with itself while
    disagreeing with the service that governs the workflow, and the whole point
    of the check is that the authority is the service, not the caller.
    """
    headers = {'Authorization': f'Bearer {token}'}
    response = httpx.get(
        f'{API}/api/v1/m2/assessments/{ASSESSMENT}/confirmations/{confirmation_id}'
        '/business-context-status', headers=headers, timeout=60)
    if response.status_code != 200:
        return {'refusal': f'BCB_STATUS_UNAVAILABLE_{response.status_code}'}
    status = response.json()
    context_id = status.get('context_id')
    if not context_id:
        return {**status, 'packet_hash': None}
    # The hash is an identifier, not a judgement: reading it from the context the
    # service named cannot contradict the service.
    read = httpx.get(
        f'{API}/api/v1/m2/assessments/{ASSESSMENT}/business-contexts/{context_id}',
        headers=headers, timeout=60)
    packet_hash = None
    if read.status_code == 200:
        packet_hash = (read.json().get('packet') or {}).get('packet_hash')
    return {**status, 'packet_hash': packet_hash}




def binding_set(engine, actor: str, *, context_id: str) -> dict:
    from sitewise.project1 import measurement_library as ml
    from sitewise.project1.objective_admission import admission_state
    from sitewise.project1.objective_registry import get as objective_get
    from sitewise.project1.prompts import PROMPTS
    from sitewise.project1.qg_candidate_adapter import facts_from_objective

    with psycopg2.connect(DSN) as conn, conn.cursor() as cur:
        cur.execute('select source_fingerprint from m2_bdj_objective_proposals '
                    'where proposal_id=%s', (PROPOSAL,))
        source_fp = cur.fetchone()[0]
        # The operative admission is the newest one: a re-admission after a
        # business-context rebuild is appended, never substituted.
        cur.execute('select admission_id, context_packet_hash, confirmation_id, '
                    'confirmation_revision, policy_version '
                    'from m2_bdj_objective_admissions where proposal_id=%s '
                    'order by created_at desc limit 1', (PROPOSAL,))
        admission_id, packet_hash, confirmation_id, revision, policy_version = \
            cur.fetchone()
        cur.execute('select packet_json from m2_business_contexts '
                    'where context_id=%s', (context_id,))
        packet = cur.fetchone()[0]

    objective = objective_get(OBJECTIVE)
    facts = facts_from_objective(packet, objective_id=OBJECTIVE,
                                 objective_text=objective.construct,
                                 admission_id=str(admission_id))
    measurement = ml.resolve(ml.PostgresMeasurementStore(engine, actor), OBJECTIVE,
                             stimulus={'concept_name': 'Slow Bar'},
                             supported_formats=ml.CANDIDATE_FORMATS,
                             allow_synthetic_test_approval=True)
    state = admission_state(engine, PROPOSAL, source_fingerprint=source_fp,
                            actor_id=actor)
    return {
        'actor': actor, 'assessment_id': ASSESSMENT,
        'confirmation_id': confirmation_id, 'assessment_revision': revision,
        'source_fingerprint': source_fp, 'context_id': context_id,
        'context_packet_hash': packet_hash, 'objective_id': OBJECTIVE,
        'objective_admission_id': state.get('admission_id') or str(admission_id),
        'measurement': measurement, 'admission': state,
        'prompt': PROMPTS['QG_FIXED_OPTION'], 'facts': facts, 'packet': packet,
        'objective_text': objective.construct, 'policy_version': policy_version,
    }


def authorization_id_for(b: dict) -> str:
    """Derive this gate's one-attempt authorization identity.

    The gate discriminator and the provisional output cap are part of the
    identity, so this authorization cannot be confused with the earlier
    exhausted runs even when every business binding is identical.
    """
    return str(uuid.uuid5(uuid.NAMESPACE_URL, '|'.join([
        'n04c-qg-auth', AUTHORIZATION_GATE, str(REQUIRED_MAX_TOKENS),
        b['assessment_id'], b['context_packet_hash'],
        b['objective_admission_id'], b['measurement']['measurement_id'],
        b['measurement']['measurement_version'], b['prompt'].version,
        b['prompt'].fingerprint])))


def issue(engine, b: dict, authorization_id: str) -> dict:
    from sitewise.repositories.m2_context_bindings import bind_restricted_principal
    prompt = b['prompt']
    with engine.begin() as conn:
        bind_restricted_principal(conn, b['actor'])
        existing = conn.execute(text(
            'SELECT authorization_id, consumed_at, expires_at '
            'FROM public.m2_qg_authorizations WHERE authorization_id=:id'),
            {'id': authorization_id}).mappings().one_or_none()
        if existing is not None:
            return {'created': False, **dict(existing)}
        conn.execute(text("""
            INSERT INTO public.m2_qg_authorizations (
                authorization_id, assessment_id, confirmation_id,
                assessment_revision, source_fingerprint, context_id,
                context_packet_hash, objective_id, objective_admission_id,
                measurement_id, measurement_version, prompt_version,
                prompt_sha256, issued_by, issued_at, expires_at, request_id)
            VALUES (:id, :assessment, :confirmation, :revision, :source, :context,
                :context_hash, :objective, :admission, :measurement,
                :measurement_version, :prompt_version, :prompt_sha, :issued_by,
                :issued_at, :expires_at, :request)
        """), {
            'id': authorization_id, 'assessment': b['assessment_id'],
            'confirmation': b['confirmation_id'],
            'revision': b['assessment_revision'],
            'source': b['source_fingerprint'], 'context': b['context_id'],
            'context_hash': b['context_packet_hash'],
            'objective': b['objective_id'],
            'admission': b['objective_admission_id'],
            'measurement': b['measurement']['measurement_id'],
            'measurement_version': b['measurement']['measurement_version'],
            'prompt_version': prompt.version, 'prompt_sha': prompt.fingerprint,
            'issued_by': b['actor'],
            'issued_at': datetime.now(timezone.utc),
            'expires_at': datetime.now(timezone.utc) + timedelta(hours=24),
            'request': str(uuid.uuid4()),
        })
    return {'created': True, 'authorization_id': authorization_id,
            'consumed_at': None}


def write_artifact(b: dict, authorization_id: str) -> dict:
    from sitewise.project1.disclosure import QG_PURPOSE
    payload = {
        'purpose': QG_PURPOSE,
        'source_fingerprint': b['facts'].fingerprint,
        'operator_receipt': 'N04C-OWNER-AUTHORIZED-SYNTHETIC-LIVE-TEST',
        'assessment_id': b['assessment_id'], 'actor_id': b['actor'],
        'max_attempts': 1, 'evaluation_id': f'QG-AUTHORIZATION-{authorization_id}',
        'authorization_id': authorization_id,
        'authorization_gate': AUTHORIZATION_GATE,
        'max_tokens': REQUIRED_MAX_TOKENS,
        'prompt_version': b['prompt'].version,
        'prompt_sha256': b['prompt'].fingerprint,
        'cost_ceiling_usd': COST_CEILING_USD,
        'scope': 'LIVE_PROVIDER_CANDIDATE_TEST',
        'issued_at': datetime.now(timezone.utc).isoformat(),
    }
    ARTIFACT.write_text(json.dumps(payload, indent=2), encoding='utf-8')
    return payload


def main() -> int:
    # Importing this module must not rewrite the process environment; loading the
    # application's configuration is an act of the run, not of the import.
    load_environment(ENV_FILE)
    dispatch = '--dispatch' in sys.argv

    # Refuse before authenticating, before reading and before issuing anything:
    # a configuration refusal must not depend on the session being usable.
    if dispatch:
        # Nothing is enabled here. The provider switch belongs to the deployment,
        # and a script that flipped it would be a second, quieter way to spend
        # money than the application it is meant to mirror.
        config = provider_configuration()
        if not config['enabled']:
            print('\n=== DISPATCH HELD ===')
            print('  code                 PROVIDER_NOT_ENABLED')
            print(f'  configuration        {ENV_FILE}')
            print('  The provider is disabled in the application configuration. '
                  'Enable it there; this script will not enable it here.')
            return 6
        if config['ceiling'] is None:
            print('\n=== DISPATCH HELD ===')
            print('  code                 PROVIDER_COST_CEILING_NOT_ADOPTED')
            print(f'  configured ceiling   {config["configured_ceiling"]}')
            return 6
        if config['model'] != REQUIRED_MODEL:
            print('\n=== DISPATCH HELD ===')
            print('  code                 PROVIDER_MODEL_NOT_AS_ADOPTED')
            print(f'  effective model      {config["model"]}')
            print(f'  adopted model        {REQUIRED_MODEL}')
            return 6
        if config.get('max_tokens') != REQUIRED_MAX_TOKENS:
            print('\n=== DISPATCH HELD ===')
            print('  code                 PROVIDER_MAX_TOKENS_NOT_ADOPTED')
            print(f'  effective max_tokens {config.get("max_tokens")}')
            print(f'  adopted max_tokens   {REQUIRED_MAX_TOKENS}')
            print('  This is the provisional Direct-QG evaluation cap, not a '
                  'production default.')
            return 6

    token = access_token()
    actor = authenticated_actor(token)
    print('=== authenticated session ===')
    print(f'  token                ...{token[-12:]}')
    print(f'  identity service id  {actor}')
    listing = prove_api_access(token)
    print(f'  authenticated read   OK ({len(listing.get("candidates") or [])} candidates)')

    from sitewise.project1 import measurement_library as ml
    from sitewise.project1 import source_currentness as source_gate
    from sitewise.project1.objective_admission import admission_state
    from sitewise.project1.qg_candidate_adapter import LIVE_SCOPE, QgCandidateAdapter
    from sitewise.project1.qg_live import QgLiveRunner
    from sitewise.project1.qg_live_candidate import live_fixed_option_generator

    engine = create_engine(M2_URL)
    runtime_engine = create_engine(RUNTIME_URL)

    # The current context is read first: it is what the attempt will be bound to,
    # and the binding set must be assembled from that same snapshot rather than
    # from a constant that could name a superseded one.
    verdict = read_source_verdict(token, CONFIRMATION)
    if not verdict.get('context_id'):
        print('\n=== DISPATCH HELD ===')
        print(f'  code                 {verdict.get("refusal") or "BCB_CONTEXT_NOT_PERSISTED"}')
        return 4
    b = binding_set(engine, actor, context_id=verdict['context_id'])

    print('\n=== binding set ===')
    for key in ('assessment_id', 'confirmation_id', 'assessment_revision',
                'source_fingerprint', 'context_id', 'context_packet_hash',
                'objective_id', 'objective_admission_id'):
        print(f'  {key:24} {b[key]}')
    print(f'  {"measurement":24} {b["measurement"]["measurement_id"]}'
          f'@{b["measurement"]["measurement_version"]}')
    print(f'  {"admission_state":24} {b["admission"]["admission_state"]}')
    print(f'  {"prompt_version":24} {b["prompt"].version}')
    print(f'  {"prompt_sha256":24} {b["prompt"].fingerprint}')
    print(f'  {"facts.fingerprint":24} {b["facts"].fingerprint}')

    refusal = source_gate.refusal(
        verdict, authorized_context_packet_hash=b['context_packet_hash'])
    print('\n=== source currentness (application verdict) ===')
    for key in ('status', 'context_id', 'assessment_revision', 'source_is_current',
                'context_compatible', 'context_incompatible_reason'):
        if key in verdict:
            print(f'  {key:24} {verdict[key]}')
    if verdict.get('refusal'):
        print(f'  {"refusal":24} {verdict["refusal"]}')
    print(f'  {"authorized context":24} {b["context_id"]}')
    print(f'  {"authorized packet":24} {b["context_packet_hash"]}')
    print(f'  {"source gate":24} {refusal or "PASS"}')
    if refusal is not None:
        print('\n=== AUTHORIZATION HELD ===')
        print(f'  code                 {refusal}')
        print('  A new authorization is not issued against a context the '
              'application no longer calls current.')
        return 4

    authorization_id = authorization_id_for(b)
    issued = issue(engine, b, authorization_id)
    print('\n=== authorization ===')
    print(f'  authorization_id     {authorization_id}')
    print(f'  created              {issued["created"]}')
    if not issued['created'] and issued.get('consumed_at'):
        print('  REFUSING: already consumed')
        return 2
    artifact = write_artifact(b, authorization_id)
    print(f'  artifact             {ARTIFACT}')
    print(f'  cost_ceiling_usd     {artifact["cost_ceiling_usd"]}')
    print(f'  max_attempts         {artifact["max_attempts"]}')
    print(f'  max_tokens           {artifact["max_tokens"]} (provisional)')
    print(f'  evaluation_id        {artifact["evaluation_id"]}')

    if '--issue-only' in sys.argv:
        print('\n=== authorization issued; nothing dispatched ===')
        print('  Proceed only after n04c_preflight_route.py reports all gates PASS.')
        return 0

    runner = QgLiveRunner(engine=runtime_engine, authorization_path=ARTIFACT)
    generate = live_fixed_option_generator(runner, policy_version=b['policy_version'])
    adapter = QgCandidateAdapter(
        engine=engine, actor_id=actor,
        store=ml.PostgresMeasurementStore(engine, actor),
        admission_lookup=lambda pid, fp: admission_state(engine, pid,
                                                         source_fingerprint=fp,
                                                         actor_id=actor),
        generate=generate, scope=LIVE_SCOPE, source_check=lambda: verdict)

    kwargs = dict(
        assessment_id=b['assessment_id'], confirmation_id=b['confirmation_id'],
        assessment_revision=b['assessment_revision'],
        source_fingerprint=b['source_fingerprint'], context_id=b['context_id'],
        context_packet_hash=b['context_packet_hash'],
        objective_id=b['objective_id'], objective_text=b['objective_text'],
        proposal_id=PROPOSAL, packet=b['packet'],
        stimulus={'concept_name': 'Slow Bar'}, authorization_id=authorization_id,
        prompt_version=b['prompt'].version, prompt_sha256=b['prompt'].fingerprint,
        population=b['measurement']['population'])

    if not dispatch:
        config = provider_configuration()
        print('\n=== dry run: every gate prepared, nothing dispatched ===')
        print(f'  adapter scope        {adapter.scope}')
        print(f'  adapter mode         {adapter.execution_mode}')
        print(f'  provider enabled     {runner.provider.enabled}')
        print(f'  provider model       {runner.provider.model}')
        print(f'  provider timeout     {runner.provider.timeout}s')
        print(f'  max_tokens           {config.get("max_tokens")} (provisional)')
        print(f'  cost ceiling         USD {config["ceiling"]}')
        print(f'  source gate          {refusal or "PASS"}')
        print(f'  dispatch_calls       {adapter.dispatch_calls}')
        permitted = (refusal is None
                     and runner.provider.timeout == REQUIRED_TIMEOUT_SECONDS
                     and config['enabled']
                     and config['ceiling'] is not None
                     and config['model'] == REQUIRED_MODEL
                     and config.get('max_tokens') == REQUIRED_MAX_TOKENS)
        print(f'\n  dispatch permitted   {permitted}')
        print('  Re-run with --dispatch to make the single authorized attempt.')
        return 0

    # Both refusals are checked before the adapter runs, so neither can consume
    # an authorization, an attempt slot or a budget unit.
    if refusal is not None:
        print('\n=== DISPATCH HELD ===')
        print(f'  code                 {refusal}')
        print(f'  authorized context   {b["context_id"]} ({b["context_packet_hash"][:16]}…)')
        print(f'  current context      {verdict.get("context_id")}')
        print('  The authorization binds a snapshot the application no longer calls '
              'current. Re-admission against the current context is required; this '
              'script will not substitute one.')
        return 4
    if runner.provider.timeout != REQUIRED_TIMEOUT_SECONDS:
        print('\n=== DISPATCH HELD ===')
        print(f'  code                 PROVIDER_TIMEOUT_NOT_AS_ADOPTED')
        print(f'  effective timeout    {runner.provider.timeout}s')
        print(f'  adopted timeout      {REQUIRED_TIMEOUT_SECONDS}s')
        return 5

    print('\n=== dispatch (exactly one attempt) ===')
    try:
        envelope = adapter.prepare(**kwargs)
    except Exception as exc:  # noqa: BLE001 - report the genuine outcome
        print(f'  DISPATCH REFUSED/FAILED: {type(exc).__name__}: {exc}')
        return 3
    for key in ('outcome', 'dispatched', 'candidate_id', 'candidate_state',
                'candidate_persisted', 'authorization_consumed', 'question'):
        print(f'  {key:24} {envelope.get(key)}')
    print(f'  {"execution":24} {json.dumps(envelope.get("execution"))}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
