"""Priority 2 -- do the three progress views agree, and where does each one come from?

Three surfaces report the same journey:

* ``GET /api/v1/assessments/me``          -- the list projection the history page renders
* ``GET /api/v1/assessments/{marketplace}`` -- the record the workspace loads
* ``GET /api/v1/assessments/{id}/workflow-readiness`` -- the governed stage gates

The stepper renders a *fourth* number: it sums ``stage_1.complete`` and
``stage_2.complete`` itself instead of reading ``completed_stages``. This
harness prints all of them side by side so a disagreement is visible as a
number, not an impression.

Read-only. Nothing here writes.

Run from ``backend/``::

    python tools/phase4_p2_progress_sync_20261122.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import requests

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
OUT = REPO / 'deliverables' / 'phase4' / 'p2_progress_sync.json'

AUTH = 'http://127.0.0.1:54329'
APP = 'http://127.0.0.1:8091'
PASSWORD = 'e2e-local-password'
OWNER = 'gatebc-e2e-b9e62014@example.invalid'

MARKETPLACE_ID = '37bf879a-005a-4f5a-b49d-210ea1ce37c4'
M2_ID = '032d3dde-547f-49a6-9e0f-58fbc5f1a48f'


def mint(email: str) -> dict:
    resp = requests.post(f'{AUTH}/auth/v1/token',
                         params={'grant_type': 'password'},
                         json={'email': email, 'password': PASSWORD}, timeout=15)
    resp.raise_for_status()
    body = resp.json()
    return {'email': email, 'token': body['access_token'], 'user_id': body['user']['id']}


def get(token: str, path: str, **params):
    resp = requests.get(f'{APP}{path}', headers={'Authorization': f'Bearer {token}'},
                        params=params or None, timeout=60)
    try:
        return resp.status_code, resp.json()
    except ValueError:
        return resp.status_code, resp.text[:400]


def main() -> int:
    owner = mint(OWNER)
    token = owner['token']
    report: dict = {'owner': {'email': owner['email'], 'user_id': owner['user_id']}}

    # --- 1. the list projection -------------------------------------------
    # The list envelope is {data, meta}; the rows are under ``data``.
    status, listing = get(token, '/api/v1/assessments/me', limit=50, offset=0)
    rows = (listing.get('data') or []) if isinstance(listing, dict) else []
    row = next((r for r in rows if MARKETPLACE_ID in json.dumps(r)), None)
    report['list_projection'] = {
        'http': status,
        'row_count': len(rows),
        'row': row,
        'completed_stages': row.get('completed_stages') if row else None,
        'total_stages': row.get('total_stages') if row else None,
        'current_stage': row.get('current_stage_key') if row else None,
    }

    # --- 2. the record the workspace loads --------------------------------
    status, detail = get(token, f'/api/v1/assessments/{MARKETPLACE_ID}')
    record = detail.get('assessment') if isinstance(detail, dict) else None
    report['detail_record'] = {
        'http': status,
        'completed_stages': (record or {}).get('completed_stages'),
        'total_stages': (record or {}).get('total_stages'),
        'current_stage_key': (record or {}).get('current_stage_key'),
        'stages': [
            {'key': s.get('key'), 'number': s.get('number'),
             'status': s.get('status'),
             'complete': s.get('status') == 'complete',
             'reason': s.get('unavailable_reason')}
            for s in ((record or {}).get('stages') or [])
        ],
    }

    # --- 3. governed readiness gates --------------------------------------
    status, readiness = get(token, f'/api/v1/assessments/{MARKETPLACE_ID}/workflow-readiness')
    report['workflow_readiness'] = {'http': status, 'body': readiness}

    # --- 4. the M2 truth that drives stage 2 ------------------------------
    status, draft = get(token, f'/api/v1/m2/assessments/{M2_ID}')
    assessment = (draft or {}).get('assessment') if isinstance(draft, dict) else None
    revision = (assessment or {}).get('revision')
    report['m2_assessment'] = {
        'http': status,
        'revision': revision,
        'status': (assessment or {}).get('status'),
        'answered_required': (assessment or {}).get('answered_required_count'),
        'required_total': (assessment or {}).get('required_item_count'),
    }

    status, confirmation = get(token, f'/api/v1/m2/assessments/{M2_ID}/confirmation-current')
    report['confirmation_current'] = {'http': status, 'body': confirmation}

    # The source gate is what stage 3 actually checks, and it is the one place
    # where a stale confirmation shows up as a refusal rather than a number.
    # It lives on the project1-workflow router, not the m2 router.
    probe = {}
    for candidate in (M2_ID, MARKETPLACE_ID):
        code, body = get(token,
                         f'/api/v1/project1-workflow/assessments/{candidate}/source',
                         expected_revision=revision if revision is not None else 0)
        probe[candidate] = {'http': code, 'body': body}
    chosen = M2_ID if probe[M2_ID]['http'] != 404 else MARKETPLACE_ID
    report['stage3_source_gate'] = {**probe[chosen], 'assessment_id': chosen, 'probes': probe}

    # --- 5. what each surface would print ---------------------------------
    stages = report['detail_record']['stages']
    stage_by_key = {s['key']: s for s in stages}
    stepper_sum = int(stage_by_key.get('select_property', {}).get('complete') is True) + \
        int(stage_by_key.get('business_requirements', {}).get('complete') is True)

    rd = readiness if isinstance(readiness, dict) else {}
    stepper_sum_readiness = int((rd.get('stage_1') or {}).get('complete') is True) + \
        int((rd.get('stage_2') or {}).get('complete') is True)

    report['render_comparison'] = {
        'history_page_uses': report['list_projection']['completed_stages'],
        'stepper_governed_formula': stepper_sum_readiness,
        'stepper_governed_formula_source': 'workflow_readiness.stage_1.complete + stage_2.complete',
        'record_completed_stages': report['detail_record']['completed_stages'],
        'total_stages': report['detail_record']['total_stages'],
        'stepper_can_exceed_2': False,
        'agreement': (
            'AGREE' if report['list_projection']['completed_stages']
            == report['detail_record']['completed_stages'] == stepper_sum_readiness
            else 'DISAGREE'
        ),
    }

    # Stage 3 must stay blocked while the confirmation is stale. Recording the
    # reason separately keeps "blocked correctly" distinct from "broken".
    gate_body = report['stage3_source_gate']['body']
    reason = None
    if isinstance(gate_body, dict):
        detail = gate_body.get('detail')
        if isinstance(detail, dict):
            reason = detail.get('message')
        reason = reason or gate_body.get('message') or gate_body.get('detail')
    else:
        reason = str(gate_body)[:200]
    report['stage3_verdict'] = {'http': report['stage3_source_gate']['http'], 'reason': reason}

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(report, indent=2), encoding='utf-8')

    print('surface                          completed  total  source')
    print(f'  list projection (history)      '
          f'{str(report["list_projection"]["completed_stages"]):9}  '
          f'{str(report["list_projection"]["total_stages"]):5}  GET /assessments/me')
    print(f'  detail record (workspace)      '
          f'{str(report["detail_record"]["completed_stages"]):9}  '
          f'{str(report["detail_record"]["total_stages"]):5}  GET /assessments/{MARKETPLACE_ID[:8]}…')
    print(f'  stepper governed formula       {str(stepper_sum_readiness):9}  '
          f'{str(report["detail_record"]["total_stages"]):5}  stage_1.complete + stage_2.complete')
    print()
    print('per-stage completeness as the record reports it:')
    for s in stages:
        print(f'  {s["key"]:24} status={str(s["status"]):14} {s["reason"] or ""}')
    print()
    print(f'm2 revision            : {report["m2_assessment"]["revision"]}')
    print(f'm2 status              : {report["m2_assessment"]["status"]}')
    print(f'confirmation-current   : HTTP {report["confirmation_current"]["http"]}')
    print(f'stage-3 source gate    : HTTP {report["stage3_source_gate"]["http"]} '
          f'({report["stage3_verdict"]["reason"]})')
    print(f'agreement              : {report["render_comparison"]["agreement"]}')
    print(f'wrote {OUT}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
