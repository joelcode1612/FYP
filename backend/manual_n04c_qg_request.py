"""Manual, opt-in reproduction of the reconstructed N04-C Direct-QG request.

This script loads ``var/e2e/n04c_manual_qg_request.json`` and sends its
``request_body`` through the same OpenAI SDK configuration as
``project1_tokenharbor_sdk_smoke_test.py``.

No request is sent unless ``--confirm-dispatch`` is supplied. Running the
script without that flag only verifies the reconstructed request identity and
prints a redacted summary.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

from dotenv import load_dotenv
from openai import OpenAI

BACKEND = Path(__file__).resolve().parent
REQUEST_FILE = BACKEND / 'var' / 'e2e' / 'n04c_manual_qg_request.json'
ENV_FILE = BACKEND / '.env'
BASE_URL = 'https://tokenharbor.ai/v1'
TIMEOUT_SECONDS = 90
EXPECTED_MODEL = 'deepseek-v4.1-flash-1017'
# Provisional Direct-QG evaluation cap only, not a production default.
PROVISIONAL_MAX_TOKENS = 12_000


def canonical(value) -> str:
    """Same canonicalisation as sitewise.project1.contracts.canonical."""
    return json.dumps(
        value,
        sort_keys=True,
        ensure_ascii=False,
        separators=(',', ':'),
        allow_nan=False,
    )


def digest(value) -> str:
    """Same request-identity digest as sitewise.project1.contracts.digest."""
    return hashlib.sha256(canonical(value).encode('utf-8')).hexdigest()


def load_document() -> dict:
    if not REQUEST_FILE.is_file():
        raise SystemExit(f'request file not found: {REQUEST_FILE}')
    doc = json.loads(REQUEST_FILE.read_text(encoding='utf-8'))
    if doc.get('status') != 'RECONSTRUCTED':
        raise SystemExit('refused: request file is not labelled RECONSTRUCTED')
    return doc


def verify(doc: dict) -> dict:
    """Check the ledger identity before any credential or network access."""
    body = doc.get('request_body')
    if not isinstance(body, dict):
        raise SystemExit('refused: request_body is missing')

    expected_keys = {
        'model', 'messages', 'temperature', 'max_tokens', 'stream',
        'response_format',
    }
    if set(body) != expected_keys:
        raise SystemExit(f'refused: unexpected request_body keys: {sorted(body)}')
    if body['model'] != EXPECTED_MODEL:
        raise SystemExit(f'refused: unexpected model {body["model"]!r}')
    if (body['temperature'], body['max_tokens'], body['stream']) != (
            0, PROVISIONAL_MAX_TOKENS, False):
        raise SystemExit('refused: provider constants do not match the provisional Direct-QG cap')
    response_format = body['response_format']
    if not isinstance(response_format, dict) or response_format.get('type') != 'json_schema':
        raise SystemExit('refused: structured mode is not json_schema')
    json_schema = response_format.get('json_schema')
    if not isinstance(json_schema, dict) or json_schema.get('strict') is not True:
        raise SystemExit('refused: strict JSON schema is absent')
    schema = json_schema.get('schema')
    if not isinstance(schema, dict):
        raise SystemExit('refused: JSON schema is absent')

    identity = {
        'messages': body['messages'],
        'model': body['model'],
        'schema': schema,
        'mode': response_format['type'],
    }
    computed = digest(identity)
    verification = doc.get('identity_verification') or {}
    recorded = verification.get('recorded_request_sha256')
    reconstructed = verification.get('reconstructed_request_sha256')
    if computed != recorded or computed != reconstructed or verification.get('match') is not True:
        raise SystemExit(
            'refused: request identity mismatch\n'
            f'  computed      {computed}\n'
            f'  recorded      {recorded}\n'
            f'  reconstructed {reconstructed}'
        )

    # Credentials must never be embedded in the reproducible artifact.
    forbidden = {'api_key', 'authorization', 'bearer', 'token', 'password', 'secret'}
    def walk(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if str(key).casefold() in forbidden:
                    raise SystemExit(f'refused: credential-like key in request file: {key}')
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)
    walk(doc)

    return {
        'computed_request_sha256': computed,
        'prompt_version': verification.get('prompt_version'),
        'confirmed_facts_fingerprint': verification.get('confirmed_facts_fingerprint'),
        'message_count': len(body['messages']),
        'body_bytes': len(canonical(body).encode('utf-8')),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--confirm-dispatch',
        action='store_true',
        help='Actually send the request. Without this flag the script is a dry run.',
    )
    args = parser.parse_args()

    doc = load_document()
    summary = verify(doc)
    print('N04-C Direct-QG manual reproduction')
    print('  status                    RECONSTRUCTED')
    print(f'  request identity SHA-256  {summary["computed_request_sha256"]}')
    print('  identity vs ledger        MATCH')
    print(f'  prompt version            {summary["prompt_version"]}')
    print(f'  confirmed facts SHA-256   {summary["confirmed_facts_fingerprint"]}')
    print(f'  messages                  {summary["message_count"]}')
    print(f'  canonical body bytes      {summary["body_bytes"]}')
    print(f'  model                     {EXPECTED_MODEL}')
    print(f'  max_tokens                {PROVISIONAL_MAX_TOKENS} (provisional)')
    print(f'  endpoint                  {BASE_URL}/chat/completions')

    if not args.confirm_dispatch:
        print('DRY RUN ONLY — no credential loaded, no request sent.')
        return 0

    load_dotenv(dotenv_path=ENV_FILE, override=False)
    api_key = __import__('os').getenv('TOKENHARBOR_API_KEY')
    if not api_key:
        raise SystemExit('TOKENHARBOR_API_KEY is missing from backend/.env')

    client = OpenAI(
        api_key=api_key,
        base_url=BASE_URL,
        max_retries=0,
        timeout=TIMEOUT_SECONDS,
    )
    response = client.chat.completions.create(**doc['request_body'])
    print(response.model_dump_json(indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
