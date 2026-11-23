"""Priority 2 -- prove the confirmation actually advances the stage, and that it
regresses when a later answer invalidates it.

The claim under test is not "the button returns 200". It is that four separate
read surfaces move together:

    review -> confirm -> record.completed_stages -> stage 2 status
                      -> confirmation-current
                      -> the list projection

and that a single answer change afterwards moves them all back. The harness
records each surface before, immediately after confirming, and again after a
controlled answer change, then restores the owner's answer and re-confirms so
the assessment is left in the confirmed state it should be in.

Writes only to the disposable database, through the public API, as the owner.

Run from ``backend/``::

    python tools/phase4_p2_confirm_advances_20261122.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import requests

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
OUT = REPO / 'deliverables' / 'phase4' / 'p2_confirm_advances.json'

AUTH = 'http://127.0.0.1:54329'
APP = 'http://127.0.0.1:8091'
PASSWORD = 'e2e-local-password'
OWNER = 'gatebc-e2e-b9e62014@example.invalid'

MARKETPLACE_ID = '37bf879a-005a-4f5a-b49d-210ea1ce37c4'
M2_ID = '032d3dde-547f-49a6-9e0f-58fbc5f1a48f'

# The item used to disturb the revision. M2V1-02 is the one revision 11 changed,
# so reusing it keeps the experiment on the same code path that caused the
# original regression.
PROBE_ITEM = 'M2V1-02'
PROBE_FROM = 'TAKEAWAY'
PROBE_TO = 'DINE_IN'


def mint(email: str) -> dict:
    resp = requests.post(f'{AUTH}/auth/v1/token',
                         params={'grant_type': 'password'},
                         json={'email': email, 'password': PASSWORD}, timeout=15)
    resp.raise_for_status()
    body = resp.json()
    return {'email': email, 'token': body['access_token'], 'user_id': body['user']['id']}


class Client:
    def __init__(self, token: str) -> None:
        self.h = {'Authorization': f'Bearer {token}'}

    def get(self, path: str, **params):
        r = requests.get(f'{APP}{path}', headers=self.h, params=params or None, timeout=60)
        try:
            return r.status_code, r.json()
        except ValueError:
            return r.status_code, r.text[:300]

    def post(self, path: str, body: dict):
        r = requests.post(f'{APP}{path}', headers=self.h, json=body, timeout=60)
        try:
            return r.status_code, r.json()
        except ValueError:
            return r.status_code, r.text[:300]

    def put(self, path: str, body: dict):
        r = requests.put(f'{APP}{path}', headers=self.h, json=body, timeout=60)
        try:
            return r.status_code, r.json()
        except ValueError:
            return r.status_code, r.text[:300]


def snapshot(c: Client, label: str) -> dict:
    """Every surface that reports stage 2, read the same way each time."""
    _, draft = c.get(f'/api/v1/m2/assessments/{M2_ID}')
    assessment = (draft or {}).get('assessment') or {}
    revision = assessment.get('revision')

    _, detail = c.get(f'/api/v1/assessments/{MARKETPLACE_ID}')
    record = (detail or {}).get('assessment') or {}
    stages = {s.get('key'): s for s in (record.get('stages') or [])}

    _, listing = c.get('/api/v1/assessments/me', limit=50, offset=0)
    rows = (listing or {}).get('data') or []
    row = next((r for r in rows if MARKETPLACE_ID in json.dumps(r)), None) or {}

    conf_http, conf = c.get(f'/api/v1/m2/assessments/{M2_ID}/confirmation-current')

    _, readiness = c.get(f'/api/v1/assessments/{MARKETPLACE_ID}/workflow-readiness')
    rd = readiness if isinstance(readiness, dict) else {}

    gate_http, gate = c.get(
        f'/api/v1/project1-workflow/assessments/{M2_ID}/source',
        expected_revision=revision if revision is not None else 0)

    stage2 = stages.get('business_requirements') or {}
    return {
        'label': label,
        'm2_revision': revision,
        'm2_status': assessment.get('status'),
        'confirmation_current_http': conf_http,
        'confirmation_revision': (conf or {}).get('assessment_revision')
        if isinstance(conf, dict) else None,
        'record_completed_stages': record.get('completed_stages'),
        'record_current_stage': record.get('current_stage_key'),
        'stage2_status': stage2.get('status'),
        'stage2_unavailable_reason': stage2.get('unavailable_reason'),
        'list_completed_stages': row.get('completed_stages'),
        'list_current_stage': row.get('current_stage_key'),
        'readiness_stage2_complete': (rd.get('stage_2') or {}).get('complete'),
        'readiness_stage3_enterable': (rd.get('stage_3') or {}).get('enterable'),
        'stepper_governed_formula': int((rd.get('stage_1') or {}).get('complete') is True)
        + int((rd.get('stage_2') or {}).get('complete') is True),
        'stage3_source_gate_http': gate_http,
        'stage3_source_gate_reason': (gate or {}).get('detail', {}).get('message')
        if isinstance(gate, dict) and isinstance(gate.get('detail'), dict) else None,
    }


def confirm(c: Client) -> dict:
    _, draft = c.get(f'/api/v1/m2/assessments/{M2_ID}')
    revision = ((draft or {}).get('assessment') or {}).get('revision')
    body = {'expected_revision': revision, 'marketplace_assessment_id': MARKETPLACE_ID}
    review_http, review = c.post(f'/api/v1/m2/assessments/{M2_ID}/review', body)
    confirm_http, confirmation = c.post(f'/api/v1/m2/assessments/{M2_ID}/confirm', body)
    return {
        'expected_revision': revision,
        'review_http': review_http,
        'review_id': (review or {}).get('review_id') if isinstance(review, dict) else None,
        'confirm_http': confirm_http,
        'confirmation_id': (confirmation or {}).get('confirmation_id')
        if isinstance(confirmation, dict) else None,
        'confirm_body': confirmation if confirm_http != 200 else 'ok',
    }


def set_answer(c: Client, value: str) -> dict:
    _, draft = c.get(f'/api/v1/m2/assessments/{M2_ID}')
    revision = ((draft or {}).get('assessment') or {}).get('revision')
    http, body = c.put(f'/api/v1/m2/assessments/{M2_ID}/answers/{PROBE_ITEM}',
                       {'expected_revision': revision, 'answer_state': 'ANSWERED',
                        'value': value})
    return {'http': http, 'expected_revision': revision,
            'new_revision': (body or {}).get('revision') if isinstance(body, dict) else None}


def main() -> int:
    owner = mint(OWNER)
    c = Client(owner['token'])
    report: dict = {'owner': {'email': owner['email'], 'user_id': owner['user_id']},
                    'steps': {}}

    report['steps']['1_before'] = snapshot(c, 'answered but unconfirmed')

    report['steps']['2_confirm'] = confirm(c)
    report['steps']['3_after_confirm'] = snapshot(c, 'confirmed at current revision')

    report['steps']['4_disturb'] = set_answer(c, PROBE_TO)
    report['steps']['5_after_disturb'] = snapshot(c, 'confirmation invalidated by a later answer')

    # Leave the owner's own answer in place and the declaration confirmed.
    report['steps']['6_restore'] = set_answer(c, PROBE_FROM)
    report['steps']['7_reconfirm'] = confirm(c)
    report['steps']['8_final'] = snapshot(c, 'restored and re-confirmed')

    # --- verdicts ---------------------------------------------------------
    before = report['steps']['1_before']
    after = report['steps']['3_after_confirm']
    disturbed = report['steps']['5_after_disturb']
    final = report['steps']['8_final']

    checks = [
        {'check': 'unconfirmed assessment sits at 1 completed stage',
         'observed': before['record_completed_stages'],
         'verdict': 'PASS' if before['record_completed_stages'] == 1 else 'FAIL'},
        {'check': 'unconfirmed stage 2 is current, not complete',
         'observed': before['stage2_status'],
         'verdict': 'PASS' if before['stage2_status'] == 'current' else 'FAIL'},
        {'check': 'no valid confirmation while unconfirmed',
         'observed': before['confirmation_current_http'],
         'verdict': 'PASS' if before['confirmation_current_http'] == 404 else 'FAIL'},
        {'check': 'confirming advances the record to 2 completed stages',
         'observed': after['record_completed_stages'],
         'verdict': 'PASS' if after['record_completed_stages'] == 2 else 'FAIL'},
        {'check': 'confirming marks stage 2 complete',
         'observed': after['stage2_status'],
         'verdict': 'PASS' if after['stage2_status'] == 'complete' else 'FAIL'},
        {'check': 'confirming makes confirmation-current resolvable',
         'observed': after['confirmation_current_http'],
         'verdict': 'PASS' if after['confirmation_current_http'] == 200 else 'FAIL'},
        {'check': 'list projection agrees with the record after confirming',
         'observed': [after['list_completed_stages'], after['record_completed_stages']],
         'verdict': 'PASS' if after['list_completed_stages']
         == after['record_completed_stages'] else 'FAIL'},
        {'check': 'a later answer change invalidates the confirmation',
         'observed': [disturbed['confirmation_current_http'],
                      disturbed['record_completed_stages']],
         'verdict': 'PASS' if disturbed['confirmation_current_http'] == 404
         and disturbed['record_completed_stages'] == 1 else 'FAIL'},
        {'check': 'the invalidated stage 2 explains itself',
         'observed': disturbed['stage2_unavailable_reason'],
         'verdict': 'PASS' if disturbed['stage2_unavailable_reason'] else 'FAIL'},
        {'check': 'final state is confirmed at 2 completed stages',
         'observed': [final['record_completed_stages'], final['confirmation_current_http']],
         'verdict': 'PASS' if final['record_completed_stages'] == 2
         and final['confirmation_current_http'] == 200 else 'FAIL'},
    ]
    report['checks'] = checks
    report['verdict'] = 'PASS' if all(c_['verdict'] == 'PASS' for c_ in checks) else 'FAIL'

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(report, indent=2), encoding='utf-8')

    hdr = ('stage', 'rev', 'conf', 'stages', 'stage2', 'stepper', 'list')
    print(f'{hdr[0]:32} {hdr[1]:4} {hdr[2]:5} {hdr[3]:6} {hdr[4]:10} {hdr[5]:7} {hdr[6]:4}')
    for key in ('1_before', '3_after_confirm', '5_after_disturb', '8_final'):
        s = report['steps'][key]
        print(f'{s["label"]:32.32} {str(s["m2_revision"]):4} '
              f'{str(s["confirmation_current_http"]):5} '
              f'{str(s["record_completed_stages"]):6} {str(s["stage2_status"]):10} '
              f'{str(s["stepper_governed_formula"]):7} {str(s["list_completed_stages"]):4}')
    print()
    for c_ in checks:
        print(f'  [{c_["verdict"]}] {c_["check"]}  -> {c_["observed"]}')
    print(f'\nverdict: {report["verdict"]}\nwrote {OUT}')
    return 0 if report['verdict'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
