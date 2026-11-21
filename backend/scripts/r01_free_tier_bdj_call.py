"""R01 — free-tier-gated BDJ dispatch with one authorised availability fallback.

Owner authorisation (this round): at most TWO attempts for the BDJ case, one
primary and one fallback. Primary ``mimo-v2.6-flash:free`` (verified zero price);
fallback ``deepseek-v4.1-flash-1017`` only on a definitive model-availability or
quota signal, under the Owner assertion ``SUBSCRIPTION_COVERED_OWNER_ASSERTED``.

Enforcement, in order:

1. Primary gate: ``GET /v1/models``; the entry must price input and output at
   exactly zero, the catalogue response must be uncompressed and decodable, and
   no ``x-ratelimit-remaining`` may be 0. Otherwise ``FREE_TIER_UNAVAILABLE``,
   nothing reserved, nothing dispatched. No flag can skip this.
2. ``reserve_budget`` appends one slot BEFORE the transport is constructed.
3. Exactly one POST through the real ``TokenHarbor`` + ``ModelRunner`` +
   ``SyntheticBdjDisclosure`` + ``BDJEngine`` on fixture
   ``02_contradictory_service_format``.
4. Fallback fires ONLY when the primary returns a definitive availability signal:
   HTTP 429, HTTP 404, or HTTP 400/402 whose body names quota/allowance/free-tier
   exhaustion. It NEVER fires on ``E_PROVIDER_RESPONSE_DECODE_OUTCOME_UNKNOWN``,
   ``E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN``, or any other unknown-outcome code.
5. The fallback gate records the raw catalogue pricing (non-zero) and the
   verbatim basis string, logs loudly that this is NOT a verified-free route,
   then reserves and dispatches once. Its identity check is strict.
6. Both transports are one-shot and use ``httpx.HTTPTransport(retries=0)``.

Usage (process-only enablement; ``.env`` is never edited)::

    TOKENHARBOR_ENABLED=true ./.venv/Scripts/python.exe \
        scripts/r01_free_tier_bdj_call.py --confirm-live

Without ``--confirm-live`` the primary gate runs and nothing is dispatched.
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx
from pydantic import SecretStr

HERE = Path(__file__).resolve().parent
BACKEND = HERE.parent
CAMPAIGN = BACKEND / 'tests' / 'project1' / 'llm_campaign'
if str(CAMPAIGN) not in sys.path:
    sys.path.insert(0, str(CAMPAIGN))

MODELS_URL = 'https://tokenharbor.ai/v1/models'
FREE_TIER_UNAVAILABLE = 'FREE_TIER_UNAVAILABLE'
FALLBACK_MODEL = 'deepseek-v4.1-flash-1017'
FALLBACK_BASIS = 'SUBSCRIPTION_COVERED_OWNER_ASSERTED'
CATALOGUE_TIMEOUT = 20.0
CAPTURE_BOUND = 192_000  # > MAX_RESPONSE_BYTES, so the provider's own bound fires
UNKNOWN_OUTCOMES = {'E_PROVIDER_RESPONSE_DECODE_OUTCOME_UNKNOWN',
                    'E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN'}

_INPUT_KEYS = ('input_usd_per_1m', 'input', 'input_price_usd_per_1m', 'input_price')
_OUTPUT_KEYS = ('output_usd_per_1m', 'output', 'output_price_usd_per_1m', 'output_price')


def _write(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # default=str: instrument_id is a UUID. Losing a capture after a dispatch
    # already happened is not an acceptable failure mode.
    path.write_text(json.dumps(payload, indent=2, sort_keys=True, default=str),
                    encoding='utf-8')


def _utc() -> str:
    return datetime.now(timezone.utc).isoformat()


# --------------------------------------------------------------------------
# Catalogue gate
# --------------------------------------------------------------------------
def _catalogue_entries(payload):
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ('data', 'models'):
            if isinstance(payload.get(key), list):
                return payload[key]
    raise ValueError('CATALOGUE_SHAPE_UNEXPECTED')


def _price(pricing: dict, keys: tuple[str, ...]):
    """Return ``(key, value, numeric)`` for the first recognised field, or a reason."""
    if not isinstance(pricing, dict):
        return None, 'PRICING_MISSING'
    for key in keys:
        if key in pricing:
            value = pricing[key]
            if isinstance(value, bool) or not isinstance(value, (int, float, str)):
                return None, f'PRICING_NOT_NUMERIC:{key}'
            try:
                numeric = float(value)
            except ValueError:
                return None, f'PRICING_NOT_NUMERIC:{key}'
            return (key, value, numeric), None
    return None, f'PRICING_FIELD_MISSING:{keys[0]}'


def _ratelimit(headers) -> list[dict]:
    rows = []
    for name, value in headers.items():
        lowered = name.lower()
        if 'ratelimit' in lowered and 'remaining' in lowered:
            rows.append({'header': name, 'value': value,
                         'is_zero': value.strip() == '0'})
    return rows


def _fetch_catalogue(model_id: str, api_key: str, out_dir: Path) -> dict:
    """GET the catalogue once. Returns raw evidence; never dispatches a model."""
    evidence = {'checked_at': _utc(), 'url': MODELS_URL, 'model_id': model_id,
                'http_status': None, 'reason': None}
    headers = {'Authorization': 'Bearer ' + api_key,
               'Cache-Control': 'no-store',
               'Accept-Encoding': 'identity'}
    started = time.monotonic()
    try:
        with httpx.Client(timeout=httpx.Timeout(CATALOGUE_TIMEOUT, connect=5),
                          follow_redirects=False,
                          transport=httpx.HTTPTransport(retries=0)) as client:
            response = client.get(MODELS_URL, headers=headers)
        evidence['http_status'] = response.status_code
        evidence['latency_ms'] = round((time.monotonic() - started) * 1000, 1)
        encoding = response.headers.get('content-encoding')
        evidence['content_encoding'] = encoding
        evidence['uncompressed'] = (encoding is None
                                    or encoding.strip().lower() in {'', 'identity'})
        evidence['ratelimit'] = _ratelimit(response.headers)
        if response.status_code != 200:
            evidence['reason'] = f'CATALOGUE_HTTP_{response.status_code}'
            return evidence
        try:
            payload = response.json()
        except Exception as exc:
            evidence['reason'] = f'CATALOGUE_UNPARSABLE:{type(exc).__name__}'
            return evidence
        _write(out_dir / f'models_catalogue_{model_id.replace(":", "_")}.json', payload)
        entries = _catalogue_entries(payload)
        entry = next((row for row in entries
                      if isinstance(row, dict) and row.get('id') == model_id), None)
        evidence['entry'] = entry
        if entry is None:
            evidence['reason'] = 'MODEL_ENTRY_MISSING'
            return evidence
        evidence['pricing'] = entry.get('pricing')
        return evidence
    except httpx.DecodingError:
        evidence['latency_ms'] = round((time.monotonic() - started) * 1000, 1)
        evidence['reason'] = 'E_PROVIDER_RESPONSE_DECODE_OUTCOME_UNKNOWN'
        return evidence
    except httpx.TransportError as exc:
        evidence['latency_ms'] = round((time.monotonic() - started) * 1000, 1)
        evidence['reason'] = f'CATALOGUE_TRANSPORT_ERROR:{type(exc).__name__}'
        return evidence


def primary_gate(model_id: str, api_key: str, out_dir: Path) -> dict:
    """Require verified-zero pricing. Fails closed on any doubt."""
    evidence = _fetch_catalogue(model_id, api_key, out_dir)
    evidence['gate'] = 'PRIMARY_FREE_TIER'
    evidence['result'] = FREE_TIER_UNAVAILABLE
    if evidence['reason']:
        return evidence
    pricing = evidence.get('pricing')
    input_pair, input_reason = _price(pricing, _INPUT_KEYS)
    if input_reason:
        evidence['reason'] = input_reason
        return evidence
    output_pair, output_reason = _price(pricing, _OUTPUT_KEYS)
    if output_reason:
        evidence['reason'] = output_reason
        return evidence
    evidence['pricing_keys_used'] = {'input': input_pair[0], 'output': output_pair[0]}
    if input_pair[2] != 0:
        evidence['reason'] = f'PRICING_NONZERO:{input_pair[0]}={input_pair[1]!r}'
        return evidence
    if output_pair[2] != 0:
        evidence['reason'] = f'PRICING_NONZERO:{output_pair[0]}={output_pair[1]!r}'
        return evidence
    if any(row['is_zero'] for row in evidence.get('ratelimit', [])):
        evidence['reason'] = 'RATELIMIT_REMAINING_ZERO'
        return evidence
    evidence['result'] = 'FREE_TIER_CONFIRMED'
    return evidence


def fallback_gate(model_id: str, api_key: str, out_dir: Path) -> dict:
    """Record the raw pricing and the Owner's coverage assertion. Never fakes zero."""
    evidence = _fetch_catalogue(model_id, api_key, out_dir)
    evidence['gate'] = 'FALLBACK_SUBSCRIPTION'
    evidence['basis'] = FALLBACK_BASIS
    evidence['result'] = 'FALLBACK_SUBSCRIPTION_ASSERTED'
    if evidence['reason']:
        evidence['result'] = 'FALLBACK_CATALOGUE_UNVERIFIED'
        return evidence
    input_pair, input_reason = _price(evidence.get('pricing'), _INPUT_KEYS)
    output_pair, output_reason = _price(evidence.get('pricing'), _OUTPUT_KEYS)
    evidence['pricing_keys_used'] = {
        'input': input_pair[0] if input_pair else None,
        'output': output_pair[0] if output_pair else None}
    evidence['catalogue_zero_priced'] = bool(
        input_pair and output_pair and input_pair[2] == 0 and output_pair[2] == 0)
    evidence['pricing_reason'] = input_reason or output_reason
    if not input_pair or not output_pair:
        # Pricing must still be recorded even when it is unusable.
        evidence['result'] = 'FALLBACK_CATALOGUE_UNVERIFIED'
    return evidence


# --------------------------------------------------------------------------
# One-shot recording transport: real socket, one dispatch, no retry.
# --------------------------------------------------------------------------
class OneShotRecordingTransport(httpx.BaseTransport):
    def __init__(self):
        self._inner = httpx.HTTPTransport(retries=0)
        self.dispatches = 0
        self.record = None

    def handle_request(self, request):
        self.dispatches += 1
        if self.dispatches > 1:
            raise RuntimeError('SECOND_DISPATCH_BLOCKED')
        started = time.monotonic()
        response = self._inner.handle_request(request)
        raw = bytearray()
        truncated = False
        try:
            for chunk in response.iter_raw():
                raw.extend(chunk)
                if len(raw) > CAPTURE_BOUND:
                    truncated = True
                    break
        finally:
            response.close()
        headers = {k: v for k, v in response.headers.items()
                   if k.lower() not in {'transfer-encoding', 'content-length'}}
        self.record = {
            'url': str(request.url), 'method': request.method,
            'request_body': json.loads(request.content),
            'request_headers': {k: v for k, v in request.headers.items()
                                if k.lower() != 'authorization'},
            'status': response.status_code,
            'response_headers': headers,
            'content_encoding': response.headers.get('content-encoding'),
            'raw_bytes': len(raw), 'truncated': truncated,
            'body': bytes(raw).decode('utf-8', 'replace'),
            'latency_ms': round((time.monotonic() - started) * 1000, 1),
        }
        return httpx.Response(response.status_code, headers=headers,
                              content=bytes(raw), request=request)


# --------------------------------------------------------------------------
# One BDJ call
# --------------------------------------------------------------------------
def run_one_call(*, model_id: str, identity_exception: bool, out_dir: Path,
                 run_id: str, api_key: str, context: dict, label: str) -> dict:
    import run_llm_campaign as runner_mod
    from campaign import authorization, build_case
    from sitewise.core.config import settings
    from sitewise.project1.bdj import BDJEngine, load_rules
    from sitewise.project1.contracts import WorkflowHeld, digest
    from sitewise.project1.disclosure import (SyntheticBdjAuthorization,
                                              SyntheticBdjDisclosure)
    from sitewise.project1.prompts import PROMPTS
    from sitewise.project1.provider import ModelRunner, TokenHarbor, strict_json

    auth = authorization()
    case = build_case('contradictory')
    capture = {
        'label': label, 'run_id': run_id, 'stage': 'BDJ',
        'scenario': '02_contradictory_service_format',
        'fixture_id': case.fixture['fixture_id'],
        'synthetic': True, 'contains_personal_data': False,
        'started_at': _utc(),
        'model_requested': model_id,
        'identity_exception_enabled': identity_exception,
        **context,
        'disclosure_adapter': 'SyntheticBdjDisclosure',
        'ledger': 'FileLedger (recording double, reserve->fsync->dispatch->receipt)',
    }

    rules = load_rules(auth['ruleset_version'], auth['ruleset_sha256'],
                       auth['adoption_receipt'])
    allowed = {p['rule_id'] for p in rules.evaluate_candidate_issues(
        {d['item_key']: {'id': d['answer_revision_id'],
                         'answer_state': d['answer_state'],
                         'value_json': d['value']}
         for d in case.packet['declarations']})}
    capture['rule_catalogue'] = sorted(allowed)

    transport = OneShotRecordingTransport()
    provider = TokenHarbor(
        SecretStr(api_key), enabled=True,
        structured_mode=settings.tokenharbor_structured_mode,
        timeout=max(1, min(settings.tokenharbor_timeout_seconds, 60)),
        identity_exception=identity_exception, model=model_id, transport=transport)
    disclosure = SyntheticBdjDisclosure(SyntheticBdjAuthorization(
        run_id=run_id, source_fingerprint=case.packet['source_fingerprint'],
        operator_receipt=auth['adoption_receipt'],
        data_class=case.packet['data_class'], purpose=case.packet['purpose'],
        model=model_id))
    ledger_path = out_dir / f'ledger_{label}.json'
    ledger = runner_mod.FileLedger(ledger_path, run_id)
    model_runner = ModelRunner(provider, ledger, PROMPTS, disclosure=disclosure)

    started = time.monotonic()
    error = None
    result = None
    try:
        result = BDJEngine(rules, model_runner=model_runner).review(
            case.packet, recheck_current=lambda: case.packet['source_fingerprint'])
    except WorkflowHeld as exc:
        error = str(exc)
    capture['elapsed_ms'] = round((time.monotonic() - started) * 1000, 1)
    capture['error'] = error
    capture['dispatched'] = transport.dispatches == 1
    capture['dispatches'] = transport.dispatches
    capture['last_identity'] = model_runner.last_identity

    record = transport.record or {}
    capture['http_status'] = record.get('status')
    capture['latency_ms'] = record.get('latency_ms')
    capture['content_encoding'] = record.get('content_encoding')
    capture['uncompressed'] = (record.get('content_encoding') is None
                               or str(record.get('content_encoding')).strip().lower()
                               in {'', 'identity'})
    capture['response_headers'] = record.get('response_headers')
    capture['raw_response'] = record.get('body')
    capture['response_bytes'] = record.get('raw_bytes')
    capture['response_truncated'] = record.get('truncated')
    capture['request_headers_sent'] = record.get('request_headers')

    sent = record.get('request_body') or {}
    if sent:
        capture['request'] = {
            'model': sent.get('model'), 'max_tokens': sent.get('max_tokens'),
            'temperature': sent.get('temperature'), 'stream': sent.get('stream'),
            'response_format': sent.get('response_format'),
            'message_count': len(sent.get('messages', [])),
            'roles': [m.get('role') for m in sent.get('messages', [])],
            'messages_digest': digest(sent.get('messages')),
        }

    content = None
    envelope = None
    if record.get('body'):
        try:
            envelope = strict_json(record['body'])
            content = envelope['choices'][0]['message']['content']
        except Exception:
            envelope, content = None, None
    capture['token_usage'] = (envelope or {}).get('usage')
    capture['response_model_reported'] = (envelope or {}).get('model')

    if result is not None:
        capture['engine_outcome'] = result['outcome']
        capture['checkpoints'] = result['checkpoints']
        capture['authorized_findings'] = result['findings']
        capture['authorized_finding_count'] = len(result['findings'])
    else:
        capture['engine_outcome'] = 'HELD'
        capture['authorized_findings'] = []
        capture['authorized_finding_count'] = 0

    if content is not None:
        capture['candidate_admission'] = runner_mod._rejections(
            content, case.packet, allowed)
    elif record.get('body'):
        capture['candidate_admission'] = [
            {'index': None, 'rejection_code': 'PROVIDER_INVALID_ENVELOPE'}]
    else:
        capture['candidate_admission'] = []

    if ledger_path.exists():
        capture['ledger_receipts'] = json.loads(
            ledger_path.read_text(encoding='utf-8')).get('runs', {}) \
            .get(run_id, {}).get('receipts', [])
    else:
        capture['ledger_receipts'] = []
    return capture


# --------------------------------------------------------------------------
# Failure classification
# --------------------------------------------------------------------------
def availability_failure(capture: dict):
    """Return ``(is_definitive, reason)``. Unknown outcomes are never definitive."""
    if capture.get('error') in UNKNOWN_OUTCOMES:
        return False, f'UNKNOWN_OUTCOME_STOP:{capture["error"]}'
    status = capture.get('http_status')
    body = (capture.get('raw_response') or '').lower()
    if status == 429:
        return True, 'HTTP_429_QUOTA_EXHAUSTED'
    if status == 404:
        return True, 'HTTP_404_MODEL_NOT_FOUND'
    if status in {400, 402} and any(token in body for token in (
            'quota', 'exhaust', 'allowance', 'free tier', 'free-tier', 'rate limit')):
        return True, f'HTTP_{status}_QUOTA_MESSAGE'
    return False, f'NO_AVAILABILITY_SIGNAL:{capture.get("error") or status}'


def _context() -> dict:
    from campaign import authorization, build_case, instrument
    from sitewise.project1.prompts import PROMPTS

    definition, schema_digest, instrument_id, _rows = instrument()
    auth = authorization()
    case = build_case('contradictory')
    return {
        'instrument_version': definition['version_tag'],
        'instrument_source_sha256': definition['source_sha256'],
        'instrument_id': str(instrument_id),
        'instrument_schema_digest': schema_digest,
        'ruleset_version': auth['ruleset_version'],
        'ruleset_sha256': auth['ruleset_sha256'],
        'prompt_version': PROMPTS['BDJ'].version,
        'prompt_fingerprint': PROMPTS['BDJ'].fingerprint,
        'source_fingerprint': case.packet['source_fingerprint'],
        'data_class': case.packet['data_class'],
        'purpose': case.packet['purpose'],
    }


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
def _read_spent(path: Path) -> int:
    if not path.exists():
        return 0
    return json.loads(path.read_text(encoding='utf-8')).get('spent', 0)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description='R01: gated BDJ dispatch with one authorised fallback.')
    parser.add_argument('--confirm-live', action='store_true',
                        help='dispatch the authorised POST(s); default is gate-only')
    args = parser.parse_args(argv)

    import run_llm_campaign as runner_mod
    from sitewise.core.config import settings
    from sitewise.project1.provider import MODEL

    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    mode = 'live' if args.confirm_live else 'gate'
    run_id = f'r01-{mode}-{stamp}'
    out_dir = BACKEND / 'var' / 'llm_campaign' / 'runs' / run_id
    out_dir.mkdir(parents=True, exist_ok=True)

    api_key = settings.tokenharbor_api_key.get_secret_value()
    if not api_key:
        print('TOKENHARBOR_API_KEY is empty; refusing')
        return 3
    if not settings.tokenharbor_enabled:
        print('tokenharbor_enabled is False; refusing (set it for this process only)')
        return 3

    context = _context()
    capture = {'run_id': run_id, 'mode': mode, 'started_at': _utc(),
               'primary_model': MODEL, 'fallback_model': FALLBACK_MODEL,
               'fallback_basis': FALLBACK_BASIS,
               'budget_initial': _read_spent(runner_mod.STATE_PATH)}
    print(f'run_id={run_id} mode={mode} out={out_dir}')
    print(f'primary={MODEL} fallback={FALLBACK_MODEL} basis={FALLBACK_BASIS}')

    gate = primary_gate(MODEL, api_key, out_dir)
    _write(out_dir / 'gate.json', gate)
    capture['primary_gate'] = gate
    _write(out_dir / 'r01_capture.json', capture)
    print(f'primary gate: {gate["result"]} reason={gate.get("reason")} '
          f'http={gate.get("http_status")} uncompressed={gate.get("uncompressed")}')
    if gate['result'] != 'FREE_TIER_CONFIRMED':
        capture['outcome'] = FREE_TIER_UNAVAILABLE
        capture['budget_final'] = _read_spent(runner_mod.STATE_PATH)
        _write(out_dir / 'r01_capture.json', capture)
        print(f'{FREE_TIER_UNAVAILABLE}: nothing spent, no dispatch')
        return 2

    if not args.confirm_live:
        capture['outcome'] = 'GATE_ONLY'
        capture['budget_final'] = _read_spent(runner_mod.STATE_PATH)
        _write(out_dir / 'r01_capture.json', capture)
        print('gate-only: no dispatch')
        return 0

    # ---- primary -----------------------------------------------------------
    spent_before = _read_spent(runner_mod.STATE_PATH)
    spent = runner_mod.reserve_budget(
        runner_mod.STATE_PATH, '02_contradictory_service_format:BDJ:primary')
    print(f'primary reserved: {spent_before} -> {spent} '
          f'(limit {runner_mod.BUDGET})')
    primary = run_one_call(model_id=MODEL, identity_exception=True,
                           out_dir=out_dir, run_id=f'{run_id}-primary',
                           api_key=api_key, context=context, label='primary')
    primary['budget'] = {'spent_before': spent_before, 'spent_after': spent,
                         'limit': runner_mod.BUDGET,
                         'remaining': runner_mod.BUDGET - spent}
    capture['primary'] = primary
    capture['budget_after_primary'] = _read_spent(runner_mod.STATE_PATH)
    _write(out_dir / 'r01_capture.json', capture)
    _report('primary', primary)

    definitive, reason = availability_failure(primary)
    capture['primary_availability'] = {'definitive': definitive, 'reason': reason}
    if primary['error'] is None:
        capture['outcome'] = 'PRIMARY_SUCCEEDED'
        capture['fallback'] = {'fired': False, 'reason': 'PRIMARY_SUCCEEDED'}
        capture['budget_final'] = _read_spent(runner_mod.STATE_PATH)
        _write(out_dir / 'r01_capture.json', capture)
        print('primary succeeded: fallback not fired')
        return 0
    if not definitive:
        capture['outcome'] = 'STOPPED_NO_FALLBACK'
        capture['fallback'] = {'fired': False, 'reason': reason}
        capture['budget_final'] = _read_spent(runner_mod.STATE_PATH)
        _write(out_dir / 'r01_capture.json', capture)
        print(f'primary failed ({primary["error"]}); fallback NOT fired: {reason}')
        return 1

    # ---- fallback (only after a definitive availability signal) ------------
    logging.getLogger('sitewise').warning(
        'FALLBACK MODEL NOT VERIFIED FREE: model=%s catalogue_pricing=%s '
        'basis=%s. This is an Owner assertion, not metadata confirmation.',
        FALLBACK_MODEL, json.dumps((capture.get('primary_gate') or {}).get('pricing')),
        FALLBACK_BASIS)
    print(f'!! FALLBACK: {FALLBACK_MODEL} is NOT verified free '
          f'(basis={FALLBACK_BASIS}). Primary signal: {reason}')

    fgate = fallback_gate(FALLBACK_MODEL, api_key, out_dir)
    _write(out_dir / 'fallback_gate.json', fgate)
    capture['fallback_gate'] = fgate
    _write(out_dir / 'r01_capture.json', capture)
    print(f'fallback gate: {fgate["result"]} pricing={json.dumps(fgate.get("pricing"))}')
    if fgate['result'] != 'FALLBACK_SUBSCRIPTION_ASSERTED':
        capture['outcome'] = 'FALLBACK_CATALOGUE_UNVERIFIED'
        capture['fallback'] = {'fired': False, 'reason': fgate.get('reason')}
        capture['budget_final'] = _read_spent(runner_mod.STATE_PATH)
        _write(out_dir / 'r01_capture.json', capture)
        return 1

    spent_before = _read_spent(runner_mod.STATE_PATH)
    spent = runner_mod.reserve_budget(
        runner_mod.STATE_PATH, '02_contradictory_service_format:BDJ:fallback')
    print(f'fallback reserved: {spent_before} -> {spent} '
          f'(limit {runner_mod.BUDGET})')
    fallback = run_one_call(model_id=FALLBACK_MODEL, identity_exception=False,
                            out_dir=out_dir, run_id=f'{run_id}-fallback',
                            api_key=api_key, context=context, label='fallback')
    fallback['budget'] = {'spent_before': spent_before, 'spent_after': spent,
                          'limit': runner_mod.BUDGET,
                          'remaining': runner_mod.BUDGET - spent}
    fallback['basis'] = FALLBACK_BASIS
    capture['fallback'] = {'fired': True, 'reason': reason, 'call': fallback}
    capture['budget_final'] = _read_spent(runner_mod.STATE_PATH)
    capture['outcome'] = 'FALLBACK_RETURNED' if fallback['error'] is None \
        else 'FALLBACK_FAILED'
    _write(out_dir / 'r01_capture.json', capture)
    _report('fallback', fallback)
    return 0 if fallback['error'] is None else 1


def _report(label: str, call: dict) -> None:
    print(f'[{label}] dispatches={call["dispatches"]} http={call["http_status"]} '
          f'uncompressed={call["uncompressed"]} latency_ms={call["latency_ms"]}')
    print(f'[{label}] identity={json.dumps(call["last_identity"], sort_keys=True)}')
    print(f'[{label}] engine_outcome={call["engine_outcome"]} error={call["error"]}')
    print(f'[{label}] authorized_findings={call["authorized_finding_count"]}')
    print(f'[{label}] token_usage={json.dumps(call["token_usage"], sort_keys=True)}')
    print(f'[{label}] budget={call["budget"]}')


if __name__ == '__main__':
    raise SystemExit(main())
