"""CP-08 offline preflight for the QG contract-2.0 path.

What this does
--------------
Builds the exact request that a live QG call *would* send — the real versioned
prompt, the real JSON schema, the real payload shape — and writes it to disk
without opening a socket. It also evaluates every governance gate that stands
between this request and a dispatch, so the blocker is a recorded fact rather
than an assumption.

What it deliberately does not do
--------------------------------
It does not dispatch, and it does not construct a disclosure authorization to
get past the gate. The disclosure contract authorizes exactly one stage (BDJ)
and exactly one attempt; inventing an authorization for QG would be fabricating
authority, which is the failure this whole system exists to prevent.

Run:
    .venv/Scripts/python.exe scripts/cp08_qg_preflight.py
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
if str(BACKEND / 'src') not in sys.path:
    sys.path.insert(0, str(BACKEND / 'src'))

from sitewise.project1.contracts import digest                    # noqa: E402
from sitewise.project1.prompts import PROMPTS                     # noqa: E402
from sitewise.project1.provider import ENDPOINT, MODEL            # noqa: E402
from sitewise.project1.qg_contract import (                       # noqa: E402
    CONTRACT_VERSION, QGCandidate, facts_from_packet,
)

OUT = BACKEND.parent / 'artifacts' / 'cp08_qg_preflight'
UNCERTAINTY_ID = 'a1b2c3d4-0000-4000-8000-000000000000'
CONFIRMATION_ID = 'b2c3d4e5-0000-4000-8000-000000000000'
EXACT_TEXT = ('Would eligible customers find RM13 acceptable for a 12 oz takeaway '
              'iced latte?')


def packet() -> dict:
    value = {
        'schema_version': 'business-context-package/1.1',
        'assessment_id': 'SYN-ASSESS-1',
        'confirmation': {'status': 'CURRENT_CONFIRMED', 'id': CONFIRMATION_ID,
                         'revision': 1},
        'confirmed_uncertainty': {
            'id': UNCERTAINTY_ID, 'confirmation_id': CONFIRMATION_ID,
            'actor_user_id': 'c3d4e5f6-0000-4000-8000-000000000000',
            'exact_text': EXACT_TEXT},
        'geography': None,
        'permissions': {'qj_execution': False},
        'm2_answers': [{'answer_revision_id': 'SYN-A1', 'item_key': 'M2-04',
                        'value': 'takeaway only'}],
        'supporting_sources': [],
    }
    value['packet_hash'] = digest(value)
    return value


def request_body(prompt_key: str = 'QG_PROPOSAL') -> dict:
    """The payload TokenHarbor.complete would POST, built the same way it builds it."""
    facts = facts_from_packet(packet(), uncertainty_version=UNCERTAINTY_ID)
    payload = {
        'contract_version': CONTRACT_VERSION,
        'confirmed_facts': facts.model_dump(),
        'field_authority': {'proposed_fields_are_candidates': True,
                            'confirmed_fields_are_facts': True,
                            'scientifically_adopted': False,
                            'fielding_authorized': False},
    }
    prompt = PROMPTS[prompt_key]
    messages = prompt.messages(payload, QGCandidate.model_json_schema())
    schema = QGCandidate.model_json_schema()
    return {
        'model': MODEL,
        'messages': messages,
        'temperature': 0,
        'max_tokens': 4000,
        'stream': False,
        'response_format': {'type': 'json_schema',
                            'json_schema': {'name': QGCandidate.__name__,
                                            'strict': True, 'schema': schema}},
        '_meta': {'endpoint': ENDPOINT, 'prompt_version': prompt.version,
                  'prompt_fingerprint': prompt.fingerprint,
                  'contract_version': CONTRACT_VERSION,
                  'message_count': len(messages),
                  'schema_bytes': len(json.dumps(schema).encode()),
                  'payload_bytes': len(json.dumps(payload).encode())},
    }


def gates() -> list[dict]:
    """Every gate between this request and a dispatch, evaluated honestly."""
    from sitewise.project1 import budget
    return [
        {'gate': 'disclosure.stage',
         'source': 'project1/disclosure.py:81',
         'state': 'BLOCKED',
         'detail': ("validate_synthetic refuses stage != 'BDJ' with "
                    "DISCLOSURE_STAGE_NOT_AUTHORIZED. QG has no stage-scoped "
                    "disclosure authorization.")},
        {'gate': 'disclosure.purpose',
         'source': 'project1/disclosure.py:77',
         'state': 'BLOCKED',
         'detail': ("purpose must be 'SYNTHETIC_BDJ_DIAGNOSTIC'; there is no QG "
                    "purpose value.")},
        {'gate': 'disclosure.packet_schema',
         'source': 'project1/disclosure.py:86',
         'state': 'BLOCKED',
         'detail': ("packet schema_version must be "
                    "'project1-m2-projection/1-candidate'. The contract-2.0 input "
                    "is confirmed_facts, a different shape.")},
        {'gate': 'disclosure.max_attempts',
         'source': 'project1/disclosure.py:84',
         'state': 'BLOCKED',
         'detail': ("max_attempts must be exactly 1, so the 3-attempt retry cycle "
                    "is not authorized even in principle.")},
        {'gate': 'ledger.stage_allowlist',
         'source': 'project1/ledger.py:43',
         'state': 'OPEN',
         'detail': "'QG' is a registered ledger stage, so the ledger itself would "
                   "accept the reservation."},
        {'gate': 'ledger.one_attempt_per_stage',
         'source': 'migrations/project1_ai/20261111_01_candidate_ledger.sql:52',
         'state': 'BLOCKED',
         'detail': ("UNIQUE(run_id, stage) permits one QG attempt per run, so a "
                    "retry needs a project1_ai migration.")},
        {'gate': 'budget',
         'source': 'project1/budget.py',
         'state': 'OPEN',
         'detail': json.dumps(budget.status())},
        {'gate': 'free_route',
         'source': 'tests/project1/llm_campaign/verify_free_route.py',
         'state': 'OPEN',
         'detail': 'FREE_ROUTE_CONFIRMED at zero cost; 0 budget slots consumed.'},
    ]


def main() -> int:
    body = request_body()
    OUT.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    path = OUT / f'qg_proposal_request_{stamp}.json'
    path.write_text(json.dumps(body, indent=2), encoding='utf-8')

    meta = body['_meta']
    print(f'captured: {path}')
    print(f"prompt={meta['prompt_version']} contract={meta['contract_version']}")
    print(f"messages={meta['message_count']} schema_bytes={meta['schema_bytes']} "
          f"payload_bytes={meta['payload_bytes']}")
    print(f'model={body["model"]} endpoint={meta["endpoint"]}')
    print('dispatched: NO (offline preflight; no socket opened)\n')

    report = gates()
    for gate in report:
        print(f"[{gate['state']:7}] {gate['gate']}: {gate['detail']}")
    blocked = [g for g in report if g['state'] == 'BLOCKED']
    print(f'\n{len(blocked)} blocking gate(s). Live QG dispatch is NOT authorized.')
    (OUT / f'gates_{stamp}.json').write_text(json.dumps(
        {'captured_at': stamp, 'request': str(path), 'gates': report},
        indent=2), encoding='utf-8')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
