"""LLM-02 campaign runner. Six provider calls, hard ceiling, enforced on disk.

Default is dry-run: every step runs except the dispatch, and the exact request
body is written to disk and summarised. Real calls require ``--confirm-calls``.

Budget
------
``BUDGET`` is read from ``sitewise.project1.budget.AUTHORIZED_CUMULATIVE_LIMIT``
and is not a flag, so no argument can raise it. ``reserve_budget()`` reads the
state file, increments and fsyncs it *before* a transport is constructed, and the
state is re-read for the next call. A crash after the increment therefore consumes
the slot rather than refunding it, and a new ``--out`` directory cannot reset the
counter because the state path is fixed and independent of the run directory.

What is real, and what is not
-----------------------------
Real: ``TokenHarbor``, ``ModelRunner``, ``PROMPTS``, ``SyntheticBdjDisclosure``,
``BDJEngine``, ``load_rules``, ``validate_candidates``, the instrument loader.

Substituted, and recorded as such in every capture:

* **Ledger.** ``FileLedger`` implements the same port with the same ordering
  (reserve -> fsync -> dispatch -> receipt) because the production
  ``PostgresAttemptLedger`` needs a ``project1_ai.runs`` row that this campaign is
  not authorized to create. It is a recording double, not a bypass: it refuses a
  second dispatch for the same stage and persists before dispatch.
* **QJ disclosure.** There is no synthetic QJ disclosure adapter; the only
  synthetic adapter is BDJ-scoped and refuses stage QJ by design. Call 6 is
  dispatched through ``provider.complete`` with a construction-time assertion
  that the input is fixture data, and the capture records
  ``disclosure_adapter: NONE_QJ_STAGE_NOT_AUTHORIZED``. Its output is transport
  evidence only, never an authorized QJ route.

Run:
    .venv/Scripts/python.exe tests/project1/llm_campaign/run_llm_campaign.py
    .venv/Scripts/python.exe tests/project1/llm_campaign/run_llm_campaign.py --confirm-calls
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx

from sitewise.project1 import budget

HERE = Path(__file__).resolve().parent
BACKEND = HERE.parents[2]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

BUDGET = budget.AUTHORIZED_CUMULATIVE_LIMIT
STATE_PATH = budget.DEFAULT_STATE_PATH
DEFAULT_OUT = BACKEND / 'var' / 'llm_campaign' / 'runs'

BDJ_SCENARIOS = ('consistent', 'contradictory', 'missing',
                 'confirmed_uncertainty', 'requires_clarification')


# --------------------------------------------------------------------------
# Budget: increment and fsync before any socket exists.
# --------------------------------------------------------------------------
# The ceiling is owned by sitewise.project1.budget, not by this script. A second
# constant here would be a second authority, and the two would drift.
BudgetExhausted = budget.BudgetExhausted


def _write_json_atomic(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + '.tmp')
    with open(tmp, 'w', encoding='utf-8') as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)


def _read_json(path: Path, default: dict) -> dict:
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding='utf-8'))


def reserve_budget(path: Path, scenario: str) -> int:
    """Consume one slot and persist it. Raises before any transport is built.

    Delegates to the authoritative budget module so the campaign and the
    production ledger cannot disagree about the ceiling.
    """
    return budget.reserve(path, scenario)


# --------------------------------------------------------------------------
# Transports
# --------------------------------------------------------------------------
class DryRunStop(Exception):
    """The request was captured, not sent."""


class DryRunTransport(httpx.BaseTransport):
    def __init__(self):
        self.record = None

    def handle_request(self, request):
        self.record = {'url': str(request.url), 'method': request.method,
                       'body': json.loads(request.content)}
        raise DryRunStop()


class RecordingTransport(httpx.BaseTransport):
    """Wraps the real HTTP transport and records status, body and latency."""

    def __init__(self):
        self._inner = httpx.HTTPTransport()
        self.record = None

    def handle_request(self, request):
        started = time.monotonic()
        response = self._inner.handle_request(request)
        body = response.read()
        self.record = {
            'url': str(request.url), 'method': request.method,
            'request_body': json.loads(request.content),
            'status': response.status_code,
            'body': body.decode('utf-8', 'replace'),
            'latency_ms': round((time.monotonic() - started) * 1000, 1),
        }
        headers = {k: v for k, v in response.headers.items()
                   if k.lower() not in {'transfer-encoding', 'content-length'}}
        return httpx.Response(response.status_code, headers=headers,
                              content=body, request=request)


# --------------------------------------------------------------------------
# Ledger double: same port, same ordering, on disk.
# --------------------------------------------------------------------------
class FileLedger:
    """One governed attempt per ``(run_id, stage)``, persisted before dispatch."""

    def __init__(self, path: Path, run_id: str):
        self.path, self.run_id = path, run_id

    def _state(self) -> dict:
        return _read_json(self.path, {'runs': {}})

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
        _write_json_atomic(self.path, state)  # committed BEFORE dispatch
        return attempt

    def finish(self, attempt, outcome, output_digest):
        state = self._state()
        run = self._run(state)
        run['receipts'].append({'attempt_no': attempt, 'outcome': outcome,
                                'output_digest': output_digest,
                                'at': datetime.now(timezone.utc).isoformat()})
        _write_json_atomic(self.path, state)


# --------------------------------------------------------------------------
# Request building
# --------------------------------------------------------------------------
def require_provider_configured():
    """Fail before any budget slot is consumed, and never flip a flag."""
    from sitewise.core.config import settings

    if not settings.tokenharbor_enabled:
        raise SystemExit('tokenharbor_enabled is False; the script will not flip it')
    if not settings.tokenharbor_api_key.get_secret_value():
        raise SystemExit('TOKENHARBOR_API_KEY is empty; refusing to dispatch')


def _provider(transport, *, dry_run):
    from pydantic import SecretStr
    from sitewise.core.config import settings
    from sitewise.project1.provider import TokenHarbor

    if dry_run:
        # Placeholder credential: the transport captures and stops, no socket is
        # opened, and nothing is read from or written to the environment.
        key = 'dry-run-no-credential-used'
        enabled = True
    else:
        key = settings.tokenharbor_api_key.get_secret_value()
        if not key:
            raise SystemExit('TOKENHARBOR_API_KEY is empty; refusing to dispatch')
        if not settings.tokenharbor_enabled:
            raise SystemExit('tokenharbor_enabled is False; the script will not flip it')
        enabled = True
    return TokenHarbor(SecretStr(key), enabled=enabled,
                       structured_mode=settings.tokenharbor_structured_mode,
                       timeout=max(1, min(settings.tokenharbor_timeout_seconds, 60)),
                       transport=transport)


def _qj_input(case):
    """A synthetic QJ input. Not a BCB packet; see the module docstring."""
    from sitewise.services.business_context_v1 import current_business_description

    fixture = case.fixture
    uncertainty = fixture['confirmation']['confirmed_uncertainty']
    return {
        'context_version': 'SYNTHETIC_LLM01_QJ_NOT_A_BCB_PACKET',
        'data_class': 'SYNTHETIC_NONHUMAN',
        'synthetic_fixture_id': fixture['fixture_id'],
        'confirmed_uncertainty': {'id': uncertainty['id'],
                                  'exact_text': uncertainty['exact_text'],
                                  'evidence_class': uncertainty['evidence_class']},
        'business_description': current_business_description(case.items, case.answers),
        'm2_declarations': [{'item_key': d['item_key'], 'question': d['question'],
                             'answer_state': d['answer_state'], 'value': d['value']}
                            for d in case.packet['declarations']],
        'limitations': ['Synthetic non-human input for transport and schema '
                        'verification only. No customer data, no fielding, no '
                        'research authority.'],
    }


def _rejections(raw_content, packet, allowed):
    """Per-candidate admission result, so one bad finding does not hide the rest."""
    from sitewise.project1.bdj import validate_candidates
    from sitewise.project1.contracts import WorkflowHeld
    from sitewise.project1.provider import strict_json

    try:
        payload = strict_json(raw_content)
    except Exception:
        return [{'index': None, 'rejection_code': 'PROVIDER_INVALID_STRUCTURED_RESPONSE'}]
    issues = payload.get('issues') if isinstance(payload, dict) else None
    if not isinstance(issues, list):
        return [{'index': None, 'rejection_code': 'BDJ_OUTPUT_INVALID'}]
    rows = []
    for index, issue in enumerate(issues):
        rule_id = issue.get('rule_id') if isinstance(issue, dict) else None
        try:
            validate_candidates({'issues': [issue], 'overall_note': 'per-candidate'},
                                packet, allowed)
            rows.append({'index': index, 'rule_id': rule_id, 'admitted': True,
                         'rejection_code': None})
        except WorkflowHeld as exc:
            rows.append({'index': index, 'rule_id': rule_id, 'admitted': False,
                         'rejection_code': str(exc)})
        except Exception as exc:  # schema failure, not a governance decision
            rows.append({'index': index, 'rule_id': rule_id, 'admitted': False,
                         'rejection_code': type(exc).__name__})
    return rows


# --------------------------------------------------------------------------
# One call
# --------------------------------------------------------------------------
def run_call(*, index, scenario, stage, case, rules, transport, ledger, out_dir,
             run_id, dry_run):
    from sitewise.project1.bdj import BDJEngine
    from sitewise.project1.contracts import QJOutput, WorkflowHeld
    from sitewise.project1.disclosure import (SyntheticBdjAuthorization,
                                              SyntheticBdjDisclosure)
    from sitewise.project1.prompts import PROMPTS
    from sitewise.project1.provider import ENDPOINT, MODEL, ModelRunner

    from campaign import authorization, instrument

    definition, _schema_digest, _instrument_id, _rows = instrument()
    auth = authorization()
    capture = {'run_id': run_id, 'scenario': scenario, 'stage': stage,
               'dry_run': dry_run,
               'instrument_version': definition['version_tag'],
               'instrument_source_sha256': definition['source_sha256'],
               'ruleset_version': auth['ruleset_version'],
               'ruleset_sha256': auth['ruleset_sha256'],
               'prompt_version': PROMPTS[stage].version,
               'endpoint': ENDPOINT, 'model_requested': MODEL,
               'started_at': datetime.now(timezone.utc).isoformat()}

    started = time.monotonic()
    error = None
    allowed: set = set()
    if stage == 'BDJ':
        provider = _provider(transport, dry_run=dry_run)
        disclosure = SyntheticBdjDisclosure(SyntheticBdjAuthorization(
            run_id=run_id, source_fingerprint=case.packet['source_fingerprint'],
            operator_receipt=auth['adoption_receipt'],
            data_class=case.packet['data_class'], purpose=case.packet['purpose']))
        runner = ModelRunner(provider, ledger, PROMPTS, disclosure=disclosure)
        allowed = {p['rule_id'] for p in rules.evaluate_candidate_issues(
            {d['item_key']: {'id': d['answer_revision_id'],
                             'answer_state': d['answer_state'],
                             'value_json': d['value']}
             for d in case.packet['declarations']})}
        capture['rule_catalogue'] = sorted(allowed)
        try:
            result = BDJEngine(rules, model_runner=runner).review(
                case.packet, recheck_current=lambda: case.packet['source_fingerprint'])
            capture['engine_outcome'] = result['outcome']
            capture['authorized_findings'] = result['findings']
            capture['checkpoints'] = result['checkpoints']
        except WorkflowHeld as exc:
            error = str(exc)
    else:
        # REFUSED, not dispatched. There is no synthetic QJ disclosure adapter:
        # the only one is BDJ-scoped and refuses stage QJ by design. Calling
        # ``provider.complete`` here would reach the provider with no disclosure
        # control at all, which is the control that keeps non-synthetic data out.
        # Construction-time assertions are not a substitute for that control, so
        # this stage records the refusal and spends no call. Enabling QJ needs a
        # QJ-scoped synthetic disclosure adapter -- a governance artefact, not a
        # flag.
        capture['disclosure_adapter'] = 'NONE_QJ_STAGE_NOT_AUTHORIZED'
        capture['engine_outcome'] = 'REFUSED_NO_QJ_DISCLOSURE_ADAPTER'
        capture['authorized_findings'] = []
        error = 'QJ_DISCLOSURE_NOT_AUTHORIZED'

    capture['error'] = error
    capture['elapsed_ms'] = round((time.monotonic() - started) * 1000, 1)
    record = getattr(transport, 'record', None) or {}
    capture['http_status'] = record.get('status')
    capture['latency_ms'] = record.get('latency_ms')
    capture['raw_response'] = record.get('body')
    capture['transport'] = type(transport).__name__
    sent = record.get('request_body')
    if sent:
        capture['request'] = {
            'model': sent.get('model'), 'max_tokens': sent.get('max_tokens'),
            'temperature': sent.get('temperature'), 'stream': sent.get('stream'),
            'response_format': sent.get('response_format'),
            'message_count': len(sent.get('messages', [])),
            'messages': sent.get('messages'),
        }

    if stage == 'BDJ' and record.get('body'):
        content = None
        try:
            from sitewise.project1.provider import strict_json
            content = strict_json(record['body'])['choices'][0]['message']['content']
        except Exception:
            content = None
        capture['candidate_admission'] = (
            _rejections(content, case.packet, allowed) if content is not None
            else [{'index': None, 'rejection_code': 'PROVIDER_INVALID_ENVELOPE'}])
    else:
        capture['candidate_admission'] = []

    path = out_dir / f'{index:02d}-{scenario}-{stage}.json'
    _write_json_atomic(path, capture)
    return capture, path


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
def _summarise(body: dict) -> dict:
    messages = body.get('messages', [])
    source = None
    if messages:
        try:
            source = json.loads(messages[-1]['content']).get('source_data')
        except Exception:
            source = None
    keys = None
    if isinstance(source, dict):
        keys = [d.get('item_key') for d in source.get('declarations', [])]
    fmt = body.get('response_format') or {}
    response_format = {'type': fmt.get('type')}
    if 'json_schema' in fmt:
        schema = fmt['json_schema'].get('schema', {})
        response_format.update({'name': fmt['json_schema'].get('name'),
                                'strict': fmt['json_schema'].get('strict'),
                                'schema_bytes': len(json.dumps(schema).encode())})
    return {'model': body.get('model'), 'max_tokens': body.get('max_tokens'),
            'temperature': body.get('temperature'), 'stream': body.get('stream'),
            'response_format': response_format,
            'message_count': len(messages),
            'roles': [m.get('role') for m in messages],
            'source_item_keys': keys}


def main(argv=None):
    parser = argparse.ArgumentParser(description='LLM-02 campaign runner (6 calls).')
    parser.add_argument('--confirm-calls', action='store_true',
                        help='dispatch real provider calls; default is dry-run')
    parser.add_argument('--out', type=Path, default=DEFAULT_OUT)
    parser.add_argument('--state', type=Path, default=STATE_PATH)
    args = parser.parse_args(argv)
    dry_run = not args.confirm_calls

    from sitewise.project1.bdj import load_rules

    from campaign import authorization, build_case

    auth = authorization()
    rules = load_rules(auth['ruleset_version'], auth['ruleset_sha256'],
                       auth['adoption_receipt'])
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    run_id = f"llm02-{'dry' if dry_run else 'live'}-{stamp}"
    out_dir = args.out / run_id
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f'run_id={run_id} mode={"DRY-RUN" if dry_run else "LIVE"} budget={BUDGET}')
    print(f'out={out_dir}')
    print(f'ruleset={auth["ruleset_version"]} sha256={auth["ruleset_sha256"]}')
    if not dry_run:
        require_provider_configured()

    plan = [(name, 'BDJ') for name in BDJ_SCENARIOS] + [('requires_clarification', 'QJ')]
    summary = []
    for index, (name, stage) in enumerate(plan, start=1):
        # A refused stage must not consume a budget slot: the budget exists to
        # bound provider dispatches, and this stage dispatches nothing.
        if stage == 'QJ':
            # Record the refusal as a capture rather than skipping silently: an
            # unauditable skip is indistinguishable from a forgotten stage.
            print(f'[call {index}/{BUDGET}] scenario={name} stage=QJ '
                  'REFUSED: no QJ synthetic disclosure adapter; 0 calls spent')
            refusal = {'index': index, 'scenario': name, 'stage': 'QJ',
                       'dry_run': dry_run, 'sent': False, 'transport': 'NONE',
                       'disclosure_adapter': 'NONE_QJ_STAGE_NOT_AUTHORIZED',
                       'engine_outcome': 'REFUSED_NO_QJ_DISCLOSURE_ADAPTER',
                       'authorized_findings': [],
                       'error': 'QJ_DISCLOSURE_NOT_AUTHORIZED',
                       'budget_spent': 0,
                       'reason': ('No QJ-scoped synthetic disclosure adapter exists; the '
                                  'only one is BDJ-scoped and refuses stage QJ. Reaching '
                                  'the provider here would bypass the disclosure control.')}
            path = out_dir / f'{index:02d}-{name}-QJ.json'
            path.write_text(json.dumps(refusal, indent=2), encoding='utf-8')
            summary.append({'index': index, 'scenario': name, 'stage': 'QJ',
                            'outcome': 'REFUSED_NO_QJ_DISCLOSURE_ADAPTER',
                            'error': 'QJ_DISCLOSURE_NOT_AUTHORIZED',
                            'budget_spent': 0, 'capture': str(path)})
            continue
        state = _read_json(args.state, {'limit': BUDGET, 'spent': 0, 'attempts': []})
        print(f'[call {index}/{BUDGET}] scenario={name} stage={stage} '
              f'remaining_before={BUDGET - state["spent"]}')
        if not dry_run:
            spent = reserve_budget(args.state, f'{name}:{stage}')
            print(f'  budget reserved: spent={spent}/{BUDGET} '
                  f'remaining_after={BUDGET - spent}')

        transport = DryRunTransport() if dry_run else RecordingTransport()
        case = build_case(name)
        call_run_id = f'{run_id}-c{index:02d}'
        ledger = FileLedger(out_dir / 'ledger.json', call_run_id)
        catalogue: list = []
        if stage == 'BDJ':
            catalogue = sorted({p['rule_id'] for p in rules.evaluate_candidate_issues(
                {d['item_key']: {'id': d['answer_revision_id'],
                                 'answer_state': d['answer_state'],
                                 'value_json': d['value']}
                 for d in case.packet['declarations']})})
            print(f'  rule_catalogue={catalogue}')
        try:
            capture, path = run_call(index=index, scenario=name, stage=stage, case=case,
                                     rules=rules, transport=transport,
                                     ledger=ledger, out_dir=out_dir,
                                     run_id=call_run_id, dry_run=dry_run)
        except DryRunStop:
            record = transport.record
            path = out_dir / f'{index:02d}-{name}-{stage}.json'
            _write_json_atomic(path, {
                'run_id': call_run_id, 'scenario': name, 'stage': stage,
                'dry_run': True, 'sent': False, 'transport': 'DryRunTransport',
                'url': record['url'], 'method': record['method'],
                'rule_catalogue': catalogue,
                'request': _summarise(record['body']),
                'request_body': record['body']})
            print('  DRY-RUN: captured, not sent')
            print('  ' + json.dumps({'url': record['url'],
                                     'method': record['method'],
                                     'rule_catalogue': catalogue,
                                     **_summarise(record['body'])}, indent=2))
        summary.append({'call': index, 'scenario': name, 'stage': stage,
                        'file': str(path), 'dry_run': dry_run})
        print(f'  wrote {path}')

    _write_json_atomic(out_dir / 'summary.json',
                       {'run_id': run_id, 'dry_run': dry_run, 'budget': BUDGET,
                        'ruleset_version': auth['ruleset_version'],
                        'calls': summary,
                        'finished_at': datetime.now(timezone.utc).isoformat()})
    print(f'summary: {out_dir / "summary.json"}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
