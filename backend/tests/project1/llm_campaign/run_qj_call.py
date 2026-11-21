"""One governed QJ call, capture-first, with a hard one-dispatch guard.

Order is the contract:

    build BCB 1.1 context -> disclosure preflight -> reserve budget ->
    ledger.reserve -> one POST -> receipt -> raw capture -> derived capture

Nothing is dispatched until the disclosure has accepted the exact packet, so a
refusal costs zero calls and zero budget. The budget file is the existing
``var/llm_campaign/budget_state.json``; ``reserve_budget`` is imported from
``run_llm_campaign`` so there is one implementation of the ceiling.

Capture-first exists because the previous BDJ attempt lost its evidence to a
UUID serialisation bug. Every writer here passes ``default=str``, and
``--dry-run`` exercises the writers and the full request build with a local
transport before anything is sent.

Usage:
    .venv/Scripts/python.exe tests/project1/llm_campaign/run_qj_call.py --dry-run
    TOKENHARBOR_ENABLED=true .venv/Scripts/python.exe .../run_qj_call.py --live
    .venv/Scripts/python.exe tests/project1/llm_campaign/run_qj_call.py --fail-closed
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

import httpx

HERE = Path(__file__).resolve().parent
BACKEND = HERE.parents[2]
BCB_SUPPORT = BACKEND / 'tests' / 'project1' / 'bcb'
for _path in (HERE, BCB_SUPPORT):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

BUDGET_PATH = BACKEND / 'var' / 'llm_campaign' / 'budget_state.json'
DEFAULT_OUT = BACKEND / 'var' / 'llm_campaign' / 'runs'
AUTHORIZATION_PATH = HERE / 'qj_scope' / 'qj_test_scope_authorization.json'
PRICE_AUTHORIZATION_PATH = HERE / 'qj_scope' / 'qj_test_scope_authorization_price_rm13.json'
UNCERTAINTY_TEXT = ('Would office workers pay RM12 for a coffee and a light lunch '
                    'at this location?')
FIXTURE_ID = 'BCB-QJ-SYNTHETIC-1'
PRICE_FIXTURE_ID = 'BCB-QJ-PRICE-RM13-1'


# --------------------------------------------------------------------------
# Writers. default=str everywhere: instrument ids are UUIDs.
# --------------------------------------------------------------------------
def _write_json(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + '.tmp')
    with open(tmp, 'w', encoding='utf-8') as handle:
        json.dump(payload, handle, indent=2, sort_keys=True, default=str,
                  ensure_ascii=False, allow_nan=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)


def _write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + '.tmp')
    with open(tmp, 'w', encoding='utf-8', newline='') as handle:
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)


def _read_budget(path: Path = BUDGET_PATH) -> dict:
    return json.loads(path.read_text(encoding='utf-8'))


# --------------------------------------------------------------------------
# The BCB context, built by the production builder
# --------------------------------------------------------------------------
def build_context(*, uncertainty: bool = True) -> dict:
    from sandbox_support import (FixedClock, SyntheticAuthorization, SyntheticSnapshots,
                                 load_fixture, request_for)
    from sitewise.services.business_context_v1 import (CURRENT_CONTEXT_VERSION,
                                                       BusinessContextBuilderV1)

    fixture = load_fixture()
    fixture['bindings']['geography'] = None
    fixture['request']['purpose'] = 'QJ_CONTEXT'
    fixture['decision']['scope']['purpose'] = 'QJ_CONTEXT'
    if uncertainty:
        fixture['bindings']['uncertainty'] = {
            'id': 'SYN-UNC-QJ-01',
            'confirmation_id': fixture['confirmation']['id'],
            'actor_user_id': fixture['assessment']['owner_user_id'],
            'exact_text': UNCERTAINTY_TEXT,
        }
    builder = BusinessContextBuilderV1(
        SyntheticAuthorization(fixture), SyntheticSnapshots(fixture), FixedClock(),
        contract=CURRENT_CONTEXT_VERSION)
    return builder.get_context(request_for(fixture))


def authorization_record(path: Path = AUTHORIZATION_PATH) -> dict:
    return json.loads(path.read_text(encoding='utf-8'))


def load_packet(path: Path) -> dict:
    """Load a persisted builder packet and re-verify its own fingerprint.

    A packet that does not hash to its recorded ``packet_hash`` is refused
    before any disclosure decision or budget reservation, so a tampered or
    truncated capture cannot become a dispatch.
    """
    from sitewise.project1.contracts import digest

    packet = json.loads(path.read_text(encoding='utf-8'))
    claimed = packet.pop('packet_hash', None)
    if not claimed or digest(packet) != claimed:
        raise SystemExit(f'{path} does not hash to its own packet_hash; refusing')
    packet['packet_hash'] = claimed
    return packet


def disclosure_for(packet: dict, authorization_path: Path = AUTHORIZATION_PATH):
    from sitewise.project1.qj_disclosure import (QjImmutableContextReferences,
                                                 SyntheticQjDisclosure,
                                                 SyntheticQjTestScopeAuthorization)

    record = authorization_record(authorization_path)
    authorization = SyntheticQjTestScopeAuthorization(
        authorization_id=record['authorization_id'],
        valid_until=record['valid_until'],
        tenant_id=record['tenant_id'],
        authorised_operations=tuple(record['authorised_operations']),
        scope=record['scope'], purpose=record['purpose'],
        data_class=record['data_class'], synthetic=record['synthetic'],
        human_subjects=record['human_subjects'],
        production_adoption=record['production_adoption'],
        owner_signature=record['owner_signature'],
        scientific_approval=record['scientific_approval'],
        geo_authority=record['geo_authority'], stage=record['stage'])
    references = QjImmutableContextReferences(
        assessment_id=packet['identity']['assessment_id'],
        confirmation_id=packet['confirmation']['id'],
        confirmed_revision=packet['confirmation']['revision'],
        context_version=packet['context_version'],
        builder_version=packet['context_version'],
        context_hash=packet['packet_hash'])
    return SyntheticQjDisclosure(authorization, references)


def envelope_for(packet: dict, fixture_id: str = FIXTURE_ID) -> dict:
    """The dispatch envelope. ``admission`` carries the server-resolved version.

    F-01: the model must be told the exact `uncertainty_version` string. Before
    this, the field was unnamed in the prompt and the value was unguessable, so a
    survey candidate could only ever fail by accident. The value here comes from
    `resolve_uncertainty_version`, the same server rule the workflow uses, so the
    harness and the workflow cannot drift apart.
    """
    from sitewise.project1.contracts import WorkflowHeld
    from sitewise.project1.measurement_policy import lab_authority

    envelope = {
        'context': packet,
        'synthetic': {
            'data_class': 'SYNTHETIC_NONHUMAN',
            'synthetic': True,
            'human_subjects': False,
            'fixture_id': fixture_id,
        },
    }
    try:
        # Use the real admission port, not a copy of its output, so the value the
        # model is shown is the same one the workflow would resolve.
        task = lab_authority().admit_qj(packet)
    except WorkflowHeld:
        # No admissible uncertainty: the disclosure refuses before any dispatch,
        # so there is no admission record to state. Absence is not a permission.
        return envelope
    envelope['admission'] = {key: task[key] for key in
                             ('uncertainty_version', 'uncertainty_version_basis',
                              'uncertainty_version_rule', 'policy_version',
                              'authorization_status')}
    return envelope


# --------------------------------------------------------------------------
# Ledger double and transports
# --------------------------------------------------------------------------
class DryRunStop(Exception):
    """The request was captured, not sent."""


class DryRunTransport(httpx.BaseTransport):
    """Local capture-only transport. Records the body and stops before a socket."""

    def __init__(self):
        self.record = None

    def handle_request(self, request):
        self.record = {
            'url': str(request.url), 'method': request.method,
            'headers': dict(request.headers),
            'body': json.loads(request.content),
            'request_bytes': len(request.content),
        }
        raise DryRunStop()


class RecordingTransport(httpx.BaseTransport):
    """Real transport wrapper that keeps the raw response bytes."""

    def __init__(self):
        self._inner = httpx.HTTPTransport()
        self.record = None

    def handle_request(self, request):
        started = time.monotonic()
        response = self._inner.handle_request(request)
        body = response.read()
        self.record = {
            'url': str(request.url), 'method': request.method,
            'request_headers': dict(request.headers),
            'request_body': json.loads(request.content),
            'request_bytes': len(request.content),
            'status': response.status_code,
            'response_headers': dict(response.headers),
            'raw_body': body.decode('utf-8', 'replace'),
            'response_bytes': len(body),
            'latency_ms': round((time.monotonic() - started) * 1000, 1),
        }
        headers = {k: v for k, v in response.headers.items()
                   if k.lower() not in {'transfer-encoding', 'content-length'}}
        return httpx.Response(response.status_code, headers=headers,
                              content=body, request=request)


class FileLedger:
    """One governed attempt per ``(run_id, stage)``, persisted before dispatch."""

    def __init__(self, path: Path, run_id: str):
        self.path, self.run_id = path, run_id

    def _state(self) -> dict:
        if not self.path.exists():
            return {'runs': {}}
        return json.loads(self.path.read_text(encoding='utf-8'))

    def _run(self, state):
        return state['runs'].setdefault(self.run_id, {'attempts': [], 'receipts': []})

    def reserve(self, stage, prompt_version, prompt_hash, request_hash):
        from sitewise.project1.contracts import WorkflowHeld

        state = self._state()
        run = self._run(state)
        if stage in {row['stage'] for row in run['attempts']}:
            raise WorkflowHeld('MODEL_STAGE_ALREADY_RESERVED')
        attempt = len(run['attempts']) + 1
        run['attempts'].append({'attempt_no': attempt, 'stage': stage,
                                'prompt_version': prompt_version,
                                'prompt_hash': prompt_hash,
                                'request_hash': request_hash,
                                'reserved_at': datetime.now(timezone.utc).isoformat()})
        _write_json(self.path, state)  # committed BEFORE dispatch
        return attempt

    def finish(self, attempt, outcome, output_digest):
        state = self._state()
        run = self._run(state)
        run['receipts'].append({'attempt_no': attempt, 'outcome': outcome,
                                'output_digest': output_digest,
                                'at': datetime.now(timezone.utc).isoformat()})
        _write_json(self.path, state)


# --------------------------------------------------------------------------
# Provider
# --------------------------------------------------------------------------
def provider_for(transport, *, dry_run=False):
    from pydantic import SecretStr
    from sitewise.core.config import settings
    from sitewise.project1.provider import TokenHarbor

    if dry_run:
        # Placeholder credential: the transport captures and stops, no socket is
        # opened, and nothing is read from or written to the environment.
        return TokenHarbor(SecretStr('dry-run-no-credential-used'), enabled=True,
                           structured_mode=settings.tokenharbor_structured_mode,
                           transport=transport, identity_exception=True)

    key = settings.tokenharbor_api_key.get_secret_value()
    if not key:
        raise SystemExit('TOKENHARBOR_API_KEY is empty; refusing to dispatch')
    if not settings.tokenharbor_enabled:
        raise SystemExit('tokenharbor_enabled is False; the script will not flip it')
    return TokenHarbor(SecretStr(key), enabled=True,
                       structured_mode=settings.tokenharbor_structured_mode,
                       timeout=max(1, min(settings.tokenharbor_timeout_seconds, 60)),
                       transport=transport, identity_exception=True)


# --------------------------------------------------------------------------
# Deterministic validation (structural only; no scientific acceptance)
# --------------------------------------------------------------------------
def validate_output(output: dict, packet: dict, *, uncertainty_version: str | None = None) -> dict:
    """Apply the repository's own measurement rules, not a local copy.

    Two layers, kept separate so neither can hide behind the other:

    * ``codes`` — ``sitewise.project1.research.validate_measurement``, the
      deterministic gate the workflow itself calls.
    * ``policy_codes`` — ``MeasurementPolicyDocument`` invariants, the real
      validator that replaced the no-op ``authority.validate_measurement``.

    The expected ``uncertainty_version`` is resolved by the server rule
    (``resolve_uncertainty_version``), never taken from the model's own output, so
    the comparison is not circular.

    Neither layer is a scientific acceptance. The policy document is lab-scoped and
    says so in ``authorization_status``.
    """
    from sitewise.project1.contracts import Measurement, WorkflowHeld
    from sitewise.project1.measurement_policy import (QJ_INVARIANTS_POLICY,
                                                      resolve_uncertainty_version)
    from sitewise.project1.research import validate_measurement

    codes: list[str] = []
    policy_codes: list[str] = []
    try:
        resolved = resolve_uncertainty_version(packet)
        expected_version = uncertainty_version or resolved.value
    except WorkflowHeld as exc:
        resolved = None
        expected_version = uncertainty_version
        codes.append(str(exc))

    measurement = output.get('measurement')
    if output['route'] != 'CUSTOMER_SURVEY_CANDIDATE':
        if measurement is not None:
            codes.append('NON_SURVEY_MEASUREMENT_FORBIDDEN')
    elif measurement is None:
        codes.append('SURVEY_MEASUREMENT_INCOMPLETE')
    else:
        try:
            frozen = Measurement.model_validate(measurement)
            if expected_version is None:
                raise WorkflowHeld('F01_UNCERTAINTY_VERSION_UNRESOLVED')
            validate_measurement(frozen, packet, expected_version)
        except WorkflowHeld as exc:
            codes.append(str(exc))
        except Exception:
            # A schema violation (extra key, wrong type, length bound) is still a
            # refusal, never a pass. The raw reason is not persisted.
            codes.append('MEASUREMENT_SCHEMA_INVALID')
        if resolved is not None:
            try:
                QJ_INVARIANTS_POLICY.validate(measurement, packet, resolved)
            except WorkflowHeld as exc:
                policy_codes.append(str(exc))
            except Exception:
                policy_codes.append('POLICY_VALIDATION_INVALID')

    return {'valid': not codes and not policy_codes, 'codes': codes,
            'policy_codes': policy_codes,
            'validator': 'sitewise.project1.research.validate_measurement',
            'policy_validator': QJ_INVARIANTS_POLICY.policy_version,
            'policy_status': ('TEST_SCOPED_VALID' if not policy_codes
                              else 'TEST_SCOPED_INVALID'),
            'policy_authorization': QJ_INVARIANTS_POLICY.authorization_status,
            'uncertainty_version_expected': expected_version,
            'uncertainty_version_basis': ('confirmed_uncertainty.id resolved by '
                                          'measurement_policy.resolve_uncertainty_version; '
                                          'id immutability proved from the append-only '
                                          'trigger and m2_research_revisions'),
            'authority': 'CANDIDATE_ONLY', 'scientific_acceptance': False,
            'note': ('Structural and invariant validation only. No scientific acceptance, '
                     'no bank authorisation and no approved research question.')}


# --------------------------------------------------------------------------
# Modes
# --------------------------------------------------------------------------
def _stamp() -> str:
    return datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')


def run_dry(out_root: Path) -> int:
    from sitewise.project1.contracts import QJOutput
    from sitewise.project1.prompts import PROMPTS
    from sitewise.project1.provider import ModelRunner

    out = out_root / f'qj-dry-{_stamp()}'
    packet = build_context()
    disclosure = disclosure_for(packet)
    transport = DryRunTransport()
    runner = ModelRunner(provider_for(transport, dry_run=True),
                         FileLedger(out / 'ledger.json', 'qj-dry'), PROMPTS,
                         disclosure=disclosure)
    try:
        runner('QJ', envelope_for(packet), QJOutput)
    except DryRunStop:
        pass
    record = transport.record
    # Exercise the exact writers used live, including a UUID-shaped value.
    _write_json(out / 'raw_response.json', {'raw_body': None,
                                            'probe_instrument_id': __import__('uuid').uuid4()})
    _write_json(out / 'raw_meta.json', {'status': None, 'request_bytes': record['request_bytes'],
                                        'probe': __import__('uuid').uuid4()})
    _write_json(out / 'capture.json', {'dry_run': True,
                                       'checks': list(disclosure.records[0].checks),
                                       'request': record})
    for name in ('raw_response.json', 'raw_meta.json', 'capture.json'):
        json.loads((out / name).read_text(encoding='utf-8'))
    print(json.dumps({'dry_run': True, 'out': str(out),
                      'request_bytes': record['request_bytes'],
                      'under_64k': record['request_bytes'] <= 64_000,
                      'checks': list(disclosure.records[0].checks)}, indent=2))
    return 0


def run_live(out_root: Path, *, packet: dict | None = None, scenario: str = 'qj:single',
             authorization_path: Path = AUTHORIZATION_PATH,
             fixture_id: str = FIXTURE_ID) -> int:
    from sitewise.project1.contracts import QJOutput, WorkflowHeld
    from sitewise.project1.prompts import PROMPTS
    from sitewise.project1.provider import ENDPOINT, MODEL, ModelRunner
    from run_llm_campaign import BUDGET, reserve_budget

    state = _read_budget()
    if state['spent'] >= BUDGET:
        raise SystemExit(f'budget exhausted: {state["spent"]}/{BUDGET}')
    # Idempotency is per scenario, not global: the ceiling is BUDGET, and a
    # distinct, separately authorised scenario must not be blocked by an earlier
    # one. Re-running the same scenario is still refused.
    if any(row.get('scenario') == scenario for row in state['attempts']):
        raise SystemExit(f'{scenario} is already recorded; refusing a repeat dispatch')

    out = out_root / f'qj-live-{scenario.replace(":", "-")}-{_stamp()}'
    if out.exists() and any(out.glob('raw_response.json')):
        raise SystemExit(f'{out} already holds a QJ capture; refusing a second dispatch')

    packet = packet if packet is not None else build_context()
    disclosure = disclosure_for(packet, authorization_path)
    envelope = envelope_for(packet, fixture_id)

    # Preflight: the disclosure decides before any budget slot or socket exists.
    try:
        receipt = disclosure.require_current('QJ', envelope, ENDPOINT, MODEL)
    except WorkflowHeld as exc:
        _write_json(out / 'refusal.json', {'stage': 'QJ', 'code': str(exc),
                                           'budget_spent': state['spent'], 'sent': False})
        print(f'REFUSED {exc}; 0 calls, 0 budget')
        return 0

    spent = reserve_budget(BUDGET_PATH, scenario)
    print(f'budget reserved: spent={spent}/{BUDGET} remaining={BUDGET - spent}')

    transport = RecordingTransport()
    ledger = FileLedger(out / 'ledger.json', f'qj-live-{_stamp()}')
    runner = ModelRunner(provider_for(transport), ledger, PROMPTS, disclosure=disclosure)
    started = time.monotonic()
    output = runner('QJ', envelope, QJOutput)   # receipt written inside
    elapsed = round((time.monotonic() - started) * 1000, 1)

    # RAW FIRST, before any derived field.
    record = transport.record or {}
    raw = record.get('raw_body')
    _write_json(out / 'raw_response.json', {
        'raw_body': raw,
        'body_sha256': hashlib.sha256((raw or '').encode('utf-8')).hexdigest(),
        'response_bytes': record.get('response_bytes'),
    })
    _write_text(out / 'raw_response.txt', raw or '')
    _write_json(out / 'raw_meta.json', {
        'url': record.get('url'), 'method': record.get('method'),
        'status': record.get('status'),
        'response_headers': record.get('response_headers'),
        'request_headers': {k: v for k, v in (record.get('request_headers') or {}).items()
                            if k.lower() in {'accept-encoding', 'content-type'}},
        'request_bytes': record.get('request_bytes'),
        'response_bytes': record.get('response_bytes'),
        'latency_ms': record.get('latency_ms'), 'wall_ms': elapsed,
        'model_requested': MODEL, 'model_returned': _returned_model(record),
        'identity': getattr(runner, 'last_identity', None),
        'captured_at': datetime.now(timezone.utc).isoformat(),
    })

    usage = None
    try:
        usage = json.loads(raw or '{}').get('usage')
    except ValueError:
        usage = None
    _write_json(out / 'capture.json', {
        'stage': 'QJ', 'run_id': f'qj-live-{_stamp()}',
        'context_version': packet['context_version'],
        'packet_hash': packet['packet_hash'],
        'geography_is_null': packet['geography'] is None,
        'confirmation': packet['confirmation'],
        'confirmed_uncertainty': packet['confirmed_uncertainty'],
        'receipt': {
            'checks': list(receipt.checks), 'tenant_id': receipt.tenant_id,
            'assessment_id': receipt.assessment_id,
            'confirmation_id': receipt.confirmation_id,
            'confirmed_revision': receipt.confirmed_revision,
            'context_version': receipt.context_version,
            'builder_version': receipt.builder_version,
            'context_hash': receipt.context_hash,
            'authorization_id': receipt.authorization_id,
            'authority': receipt.authority, 'candidate_only': receipt.candidate_only,
            'scientific_acceptance': receipt.scientific_acceptance,
            'owner_authorization': receipt.owner_authorization,
            'publication_authorized': receipt.publication_authorized,
            'fielding_authorized': receipt.fielding_authorized,
            'report_release_authorized': receipt.report_release_authorized,
        },
        'qj': output,
        'validation': validate_output(output, packet),
        'usage': usage,
        'budget_spent': spent,
    })
    print(json.dumps({'out': str(out), 'status': record.get('status'),
                      'route': output.get('route'), 'budget_spent': spent,
                      'usage': usage}, indent=2))
    return 0


def _returned_model(record) -> str | None:
    try:
        return json.loads(record.get('raw_body') or '{}').get('model')
    except ValueError:
        return None


def run_fail_closed(out_root: Path) -> int:
    from sitewise.project1.contracts import WorkflowHeld
    from sitewise.project1.provider import ENDPOINT, MODEL

    before = BUDGET_PATH.read_bytes()
    spent_before = _read_budget()['spent']
    out = out_root / f'qj-failclosed-{_stamp()}'
    packet = build_context(uncertainty=False)
    disclosure = disclosure_for(packet)
    code = None
    try:
        disclosure.require_current('QJ', envelope_for(packet), ENDPOINT, MODEL)
    except WorkflowHeld as exc:
        code = str(exc)
    after = BUDGET_PATH.read_bytes()
    _write_json(out / 'refusal.json', {
        'stage': 'QJ', 'scenario': 'confirmed uncertainty absent',
        'code': code, 'sent': False, 'socket_constructed': False,
        'budget_before': spent_before, 'budget_after': _read_budget()['spent'],
        'budget_file_identical': before == after,
        'confirmed_uncertainty': packet['confirmed_uncertainty'],
        'unknowns': packet['unknowns'],
    })
    print(json.dumps({'code': code, 'sent': False,
                      'budget_file_identical': before == after,
                      'budget_before': spent_before,
                      'budget_after': _read_budget()['spent']}, indent=2))
    return 0 if code == 'QJ_DISCLOSURE_UNCERTAINTY_NOT_CONFIRMED' else 1


def run_preflight(out_root: Path, *, packet: dict, scenario: str,
                  authorization_path: Path = AUTHORIZATION_PATH,
                  fixture_id: str = FIXTURE_ID) -> int:
    """Ask the disclosure adapter whether this packet would be dispatched.

    Zero cost and zero side effects: no socket, no budget reservation, no
    ledger write. A refusal here is a real result and is recorded as one.
    """
    from sitewise.project1.contracts import WorkflowHeld
    from sitewise.project1.provider import ENDPOINT, MODEL

    out = out_root / f'qj-preflight-{scenario.replace(":", "-")}-{_stamp()}'
    disclosure = disclosure_for(packet, authorization_path)
    envelope = envelope_for(packet, fixture_id)
    record = {'stage': 'QJ', 'scenario': scenario, 'sent': False,
              'socket_constructed': False,
              'packet_hash': packet['packet_hash'],
              'context_version': packet['context_version'],
              'geography_is_null': packet['geography'] is None,
              'tenant_id': packet['identity']['tenant_id'],
              'confirmed_uncertainty': packet['confirmed_uncertainty'],
              'authorization': str(authorization_path.name),
              'endpoint': ENDPOINT, 'model': MODEL}
    try:
        receipt = disclosure.require_current('QJ', envelope, ENDPOINT, MODEL)
    except WorkflowHeld as exc:
        record.update(accepted=False, code=str(exc))
        _write_json(out / 'preflight.json', record)
        print(json.dumps(record, indent=2, default=str))
        return 0
    record.update(accepted=True, code=None,
                  checks=list(receipt.checks),
                  receipt={'assessment_id': receipt.assessment_id,
                           'confirmation_id': receipt.confirmation_id,
                           'confirmed_revision': receipt.confirmed_revision,
                           'context_version': receipt.context_version,
                           'context_hash': receipt.context_hash,
                           'authorization_id': receipt.authorization_id,
                           'authority': receipt.authority,
                           'candidate_only': receipt.candidate_only,
                           'fielding_authorized': receipt.fielding_authorized,
                           'publication_authorized': receipt.publication_authorized})
    _write_json(out / 'preflight.json', record)
    print(json.dumps(record, indent=2, default=str))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description='One governed QJ call.')
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--dry-run', action='store_true')
    group.add_argument('--live', action='store_true')
    group.add_argument('--fail-closed', action='store_true')
    group.add_argument('--preflight', action='store_true',
                       help='disclosure decision only; no socket, no budget, no ledger')
    parser.add_argument('--out', type=Path, default=DEFAULT_OUT)
    parser.add_argument('--packet', type=Path, default=None,
                        help='persisted builder packet to use instead of the sandbox fixture')
    parser.add_argument('--scenario', default='qj:single',
                        help='budget/ledger scenario key; a repeat of the same key is refused')
    parser.add_argument('--authorization', type=Path, default=AUTHORIZATION_PATH)
    parser.add_argument('--fixture-id', default=FIXTURE_ID)
    args = parser.parse_args(argv)
    packet = load_packet(args.packet) if args.packet else None
    if args.dry_run:
        return run_dry(args.out)
    if args.preflight:
        if packet is None:
            raise SystemExit('--preflight requires --packet')
        return run_preflight(args.out, packet=packet, scenario=args.scenario,
                             authorization_path=args.authorization,
                             fixture_id=args.fixture_id)
    if args.live:
        return run_live(args.out, packet=packet, scenario=args.scenario,
                        authorization_path=args.authorization,
                        fixture_id=args.fixture_id)
    return run_fail_closed(args.out)


if __name__ == '__main__':
    raise SystemExit(main())
