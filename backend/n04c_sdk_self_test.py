#!/usr/bin/env python3
"""N04-C reconstructed Direct-QG request diagnostic.

Default: verify the actual synthetic QG input and send it through an OpenAI SDK
client backed by an in-process httpx.MockTransport (zero network calls).

Optional: --live --confirm-live performs ONE new, standalone TokenHarbour API
request using the reconstructed body. This is NOT a governed Project1 dispatch,
creates NO Project1 ledger entry, may be billable, and must not be interpreted
as retrying the historical unknown-outcome attempt.

Credentials, prompts, full request body, and response headers are never logged.
The local result file may contain an AI-generated response based on synthetic data.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

EXPECTED_REQUEST_SHA256 = '5786ded57b6e83f0b977cbb654068c489689a8213570da684a5b07ccc32f9915'
EXPECTED_PROMPT_SHA256 = 'a4d21e98a819749f7a0d1f9dea8cd1977e6da0fff60a4267e1124bdc101c55cb'
EXPECTED_MODEL = 'deepseek-v4.1-flash-1017'
BASE_URL = 'https://tokenharbor.ai/v1'
TIMEOUT_SECONDS = 90


def canonical(obj):
    return json.dumps(obj, sort_keys=True, ensure_ascii=False,
                      separators=(',', ':'), allow_nan=False)


def sha256(obj):
    return hashlib.sha256(canonical(obj).encode('utf-8')).hexdigest()


def fail(reason):
    raise ValueError(reason)


def default_payload_path():
    home = Path(__file__).resolve().parent
    candidate = home / 'var' / 'e2e' / 'n04c_manual_qg_request.json'
    return candidate if candidate.exists() else home / 'n04c_manual_qg_request.json'


def verify_payload(path):
    doc = json.loads(path.read_text(encoding='utf-8'))
    if doc.get('status') != 'RECONSTRUCTED' or doc.get('original_payload_retained') is not False:
        fail('Payload must be explicitly labelled RECONSTRUCTED, not a captured original')
    binding = doc.get('source_binding', {})
    if binding.get('data_classification') != 'SYNTHETIC isolated N04-C test data':
        fail('Expected synthetic N04-C data only; refusing other source material')
    body = doc.get('request_body')
    if not isinstance(body, dict) or set(body) != {
        'model', 'messages', 'temperature', 'max_tokens', 'stream', 'response_format'
    }:
        fail('Unexpected or missing provider request fields')
    if body['model'] != EXPECTED_MODEL or (body['temperature'], body['max_tokens'], body['stream']) != (0, 131072, False):
        fail('Model or generation parameters differ from reconstructed N04-C attempt')
    if not isinstance(body['messages'], list) or [m.get('role') for m in body['messages']] != ['system', 'user']:
        fail('Expected exactly one system and one user message')
    if any(not isinstance(m.get('content'), str) or not m['content'] for m in body['messages']):
        fail('Missing prompt content')
    rf = body['response_format']
    if (not isinstance(rf, dict) or rf.get('type') != 'json_schema' or
        not isinstance(rf.get('json_schema'), dict) or rf['json_schema'].get('strict') is not True or
        rf['json_schema'].get('name') != 'FixedOptionCandidate'):
        fail('Structured output configuration differs from N04-C')
    schema = rf['json_schema'].get('schema')
    if not isinstance(schema, dict) or 'fixed_measurement' not in schema.get('properties', {}):
        fail('Fixed-option measurement missing from output schema')

    ident = {
        'messages': body['messages'], 'model': body['model'],
        'schema': schema, 'mode': rf['type'],
    }
    computed = sha256(ident)
    meta = doc.get('identity_verification', {})
    if (computed != EXPECTED_REQUEST_SHA256 or
        meta.get('recorded_request_sha256') != EXPECTED_REQUEST_SHA256 or
        meta.get('reconstructed_request_sha256') != EXPECTED_REQUEST_SHA256 or
        meta.get('recorded_prompt_sha256') != EXPECTED_PROMPT_SHA256 or
        meta.get('reconstructed_prompt_sha256') != EXPECTED_PROMPT_SHA256 or
        meta.get('match') is not True):
        fail('The recorded N04-C request/prompt identity does not match this payload')

    # A user message contains JSON with version-bound confirmed facts.
    user_data = json.loads(body['messages'][1]['content'])
    source = user_data['source_data']
    facts = source['confirmed_facts']
    expected_bindings = {
        'assessment_id': 'assessment_id',
        'objective_id': 'objective_id',
        'objective_text': 'objective_text',
    }
    for fact_field, bind_field in expected_bindings.items():
        if facts.get(fact_field) != binding.get(bind_field):
            fail(f'Assessment / objective binding mismatch: {fact_field}')
    if facts.get('context_hash') != binding.get('context_packet_hash'):
        fail('Confirmed facts do not cite the current BCB packet')
    if source.get('source_fingerprint') != meta.get('confirmed_facts_fingerprint'):
        fail('Confirmed facts fingerprint differs from verification metadata')
    if source.get('contract_version') != 'P1-QG-FIXED-OPTION-1.0':
        fail('Unexpected fixed-option contract version')
    if not facts.get('confirmed_offers') or not facts.get('confirmed_currency'):
        fail('Expected synthetic confirmed offers/currency were not supplied')
    if not any(binding['objective_admission_id'] in ref for ref in facts.get('source_refs', [])):
        fail('Objective admission reference is absent from QG input')

    # Reject credential-shaped keys in the artifact. Checking key names intentionally
    # avoids printing values or interpreting natural-language prompt text as secrets.
    secret_names = {'api_key', 'authorization', 'bearer', 'password', 'secret', 'access_token'}
    def check_no_secret_keys(obj):
        if isinstance(obj, dict):
            for k, v in obj.items():
                if str(k).lower() in secret_names:
                    fail('Credential-shaped key found in input artifact')
                check_no_secret_keys(v)
        elif isinstance(obj, list):
            for v in obj:
                check_no_secret_keys(v)
    check_no_secret_keys(doc)

    return doc, body, {
        'identity_matches_ledger': True,
        'request_sha256': computed,
        'prompt_sha256': EXPECTED_PROMPT_SHA256,
        'assessment_id': binding['assessment_id'],
        'objective_id': binding['objective_id'],
        'objective_text': binding['objective_text'],
        'context_hash': binding['context_packet_hash'],
        'message_roles': ['system', 'user'],
        'message_lengths': [len(m['content']) for m in body['messages']],
        'fixed_option_schema_present': True,
        'confirmed_facts_bound': True,
    }


def mock_sdk_test(body):
    """Intercept a real SDK HTTP POST locally; fall back to httpx if SDK unavailable.

    Both modes use an in-process MockTransport, never a socket. Only the SDK
    mode proves SDK assembly of the actual body and the Bearer header.
    """
    import httpx
    try:
        from openai import OpenAI
    except ImportError:
        OpenAI = None
    seen = []
    fake_key = 'N04C_LOCAL_MOCK_KEY_NOT_REAL'

    def handler(request):
        if request.method != 'POST' or request.url.path != '/v1/chat/completions':
            fail('HTTP client invoked wrong endpoint/method')
        if request.headers.get('authorization') != 'Bearer ' + fake_key:
            fail('HTTP client did not attach expected Bearer Authorization header')
        if 'application/json' not in request.headers.get('content-type', ''):
            fail('HTTP client did not send JSON')
        outgoing = json.loads(request.content)
        if outgoing != body:
            fail('HTTP client changed request messages, model, schema or parameters')
        seen.append(True)
        response_data = {
            'id': 'offline-n04c-mock', 'object': 'chat.completion',
            'created': 0, 'model': EXPECTED_MODEL,
            'choices': [{'index': 0, 'finish_reason': 'stop', 'message': {
                'role': 'assistant',
                'content': json.dumps({'decision': 'ABSTAIN_NEEDS_REVIEW',
                                       'question': '', 'justification': 'Offline mock only.'}),
            }}],
            'usage': {'prompt_tokens': 0, 'completion_tokens': 0, 'total_tokens': 0},
        }
        return httpx.Response(200, json=response_data)

    with httpx.Client(transport=httpx.MockTransport(handler)) as http_client:
        if OpenAI is not None:
            client = OpenAI(api_key=fake_key, base_url=BASE_URL,
                            max_retries=0, timeout=TIMEOUT_SECONDS,
                            http_client=http_client)
            response = client.chat.completions.create(**body)
            returned_model = response.model
            method = 'OpenAI SDK -> httpx.MockTransport'
        else:
            response = http_client.post(
                BASE_URL + '/chat/completions',
                headers={'Authorization': 'Bearer ' + fake_key}, json=body,
            )
            returned_model = response.json()['model']
            method = 'httpx -> MockTransport (SDK not installed in this environment)'
    if len(seen) != 1 or returned_model != EXPECTED_MODEL:
        fail('Offline mock transport/response test did not complete exactly once')
    return {
        'mock_method': method,
        'sdk_tested': OpenAI is not None,
        'json_body_identical': True,
        'bearer_header_attached': True,
        'external_network_calls': 0,
    }


def exception_classes(exc):
    result = []
    visited = set()
    while exc is not None and id(exc) not in visited and len(result) < 6:
        visited.add(id(exc))
        result.append(type(exc).__name__)
        exc = getattr(exc, '__cause__', None) or getattr(exc, '__context__', None)
    return result


def save_result(report, directory):
    directory.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    path = directory / f'n04c_sdk_manual_result_{stamp}.json'
    # Exclusive create: never overwrite another test's evidence.
    with path.open('x', encoding='utf-8') as fh:
        json.dump(report, fh, indent=2, ensure_ascii=False)
        fh.write('\n')
    return path


def live_sdk_test(body, identity, workdir):
    try:
        from openai import OpenAI
        from dotenv import load_dotenv
    except ImportError as exc:
        fail(f'Missing Python dependency: {exc.name} (activate backend venv)')

    envfile = workdir / '.env'
    if not envfile.is_file():
        fail('backend/.env not found; no live request sent')
    load_dotenv(envfile, override=False)
    key = os.environ.get('TOKENHARBOR_API_KEY', '').strip()
    if not key:
        fail('TOKENHARBOR_API_KEY is not configured; no live request sent')

    print('\nLIVE MODE — one new, billable out-of-band API call; no retries or Project1 ledger write.')
    print('This is not the historical attempt and does not prove the FastAPI route.')
    approval = input('Type SEND N04C ONCE to authorize the manual request: ').strip()
    if approval != 'SEND N04C ONCE':
        print('CANCELLED — no provider request sent')
        return 2

    report = {
        'test': 'N04C_SDK_MANUAL_LIVE', 'payload_status': 'RECONSTRUCTED',
        'identity': identity, 'model_requested': EXPECTED_MODEL,
        'timeout_seconds': TIMEOUT_SECONDS, 'max_retries': 0,
        'project1_ledger_updated': False, 'provider_receipt_unknown_until_response': True,
    }
    start = time.monotonic()
    try:
        client = OpenAI(api_key=key, base_url=BASE_URL,
                        max_retries=0, timeout=TIMEOUT_SECONDS)
        response = client.chat.completions.create(**body)  # EXACTLY ONE live request
        report['elapsed_seconds'] = round(time.monotonic() - start, 3)
        report['provider_response_received'] = True
        report['model_returned'] = response.model
        report['model_identity_exact_match'] = response.model == EXPECTED_MODEL
        report['usage'] = response.usage.model_dump() if response.usage else None
        report['finish_reason'] = response.choices[0].finish_reason if response.choices else None
        content = response.choices[0].message.content if response.choices else None
        if not content:
            report['result'] = 'EMPTY_RESPONSE'
        else:
            try:
                parsed = json.loads(content)
                report['response_json'] = parsed
                schema = body['response_format']['json_schema']['schema']
                try:
                    import jsonschema
                except ImportError:
                    report['json_schema_verdict'] = 'NOT_CHECKED (jsonschema not installed)'
                else:
                    try:
                        jsonschema.Draft202012Validator(schema).validate(parsed)
                        report['json_schema_verdict'] = 'PASS'
                    except jsonschema.ValidationError:
                        report['json_schema_verdict'] = 'FAIL'
                report['result'] = 'RESPONSE_RETURNED'
            except ValueError:
                report['result'] = 'NON_JSON_RESPONSE'
                report['response_content_sha256'] = hashlib.sha256(content.encode()).hexdigest()
        report['backend_semantic_validation'] = 'NOT_TESTED'
        report['stage4_stage5_integration'] = 'NOT_TESTED'
        exit_code = 0 if (report.get('result') == 'RESPONSE_RETURNED' and
                          report.get('model_identity_exact_match') and
                          report.get('json_schema_verdict') == 'PASS' and
                          report.get('finish_reason') == 'stop') else 1
    except Exception as exc:
        report['elapsed_seconds'] = round(time.monotonic() - start, 3)
        report['provider_response_received'] = False
        report['result'] = 'PROVIDER_CALL_FAILED'
        report['exception_classes'] = exception_classes(exc)
        status_code = getattr(exc, 'status_code', None)
        report['upstream_http_status'] = status_code if isinstance(status_code, int) else None
        report['delivery_to_provider'] = 'UNKNOWN'
        exit_code = 1

    saved = save_result(report, workdir / 'var' / 'e2e')
    print('\nLive test verdict:', report['result'])
    print('Elapsed seconds:', report['elapsed_seconds'])
    print('Model returned:', report.get('model_returned', 'not available'))
    print('Upstream HTTP status:', report.get('upstream_http_status', 'not available'))
    if 'exception_classes' in report:
        print('Exception class chain:', ' > '.join(report['exception_classes']))
    if 'response_json' in report:
        data = report['response_json']
        print('Model decision:', data.get('decision') if isinstance(data, dict) else 'non-object')
        print('Generated question:', data.get('question') if isinstance(data, dict) else 'non-object')
        print('JSON schema verdict:', report.get('json_schema_verdict'))
    print('Local result file (no API key):', saved)
    return exit_code


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--payload', type=Path, default=default_payload_path(),
                   help='Path to reconstructed n04c_manual_qg_request.json')
    p.add_argument('--live', action='store_true', help='Enable manual live mode')
    p.add_argument('--confirm-live', action='store_true',
                   help='Required together with --live, then interactive confirmation')
    args = p.parse_args()
    if args.live != args.confirm_live:
        p.error('A live call requires both --live and --confirm-live; otherwise omit both')

    try:
        doc, body, identity = verify_payload(args.payload)
        print('PASS — reconstructed N04-C request identity matches the recorded SHA-256')
        print('  model:', body['model'])
        print('  objective:', identity['objective_id'], identity['objective_text'])
        print('  confirmed facts bound: YES')
        print('  roles: system, user | character lengths:', identity['message_lengths'])
        print('  fixed-option output schema: PRESENT')
        mock_result = mock_sdk_test(body)
        print('PASS — HTTP request assembled correctly using local HTTP mock')
        print('  offline transport:', mock_result['mock_method'])
        print('  Authorization: Bearer header: PRESENT (fake offline key)')
        print('  exact JSON body transmitted to mock: YES')
        print('  external API calls: 0')
    except (ValueError, FileNotFoundError, KeyError, TypeError, json.JSONDecodeError) as exc:
        print('FAIL — offline preflight:', str(exc), file=sys.stderr)
        return 1

    if not args.live:
        print('OFFLINE PASS — no API key loaded, no live TokenHarbour request made.')
        return 0
    try:
        # Backend root should contain .env and var/e2e. When testing beside JSON,
        # the user can move this script into backend/ before selecting live mode.
        return live_sdk_test(body, identity, Path(__file__).resolve().parent)
    except (ValueError, OSError) as exc:
        print('LIVE PREFLIGHT FAILED —', str(exc), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
