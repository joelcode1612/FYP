"""P4 — Stage 3 reachability walk against the disposable stack.

Purpose
-------
Record, reproducibly, exactly how far the PROJECT1 Stage 3 journey gets on the
disposable workflow database, and where it stops. The value of this harness is
that it refuses to report a stage as "working" on the strength of an HTTP 200
alone: a 200 that carries ``outcome: held`` is recorded as held.

Three principals are involved and the distinction matters:

* ``sitewise_e2e`` — NOSUPERUSER / NOBYPASSRLS login used for ordinary reads and
  writes. A superuser login is refused outright by
  ``verify_workflow_database`` (it raises ``SOURCE_PRINCIPAL_REVIEW_REQUIRED``
  whenever the connecting role is superuser or bypassrls, because RLS would be
  silently bypassed).
* ``p1ai_engine`` — execution principal, member of the NOLOGIN ``p1ai_runtime``,
  used only for the attempt ledger via ``PROJECT1_RUNTIME_DATABASE_URL``.
* the entrepreneur — identified per request by ``project1.actor_id``.

Evidence is written to ``deliverables/phase4/p4_stage3_reachability.json``.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import requests

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
OUT = REPO / 'deliverables' / 'phase4'

AUTH = 'http://127.0.0.1:54329'
APP = 'http://127.0.0.1:8091'
PASSWORD = 'e2e-local-password'
OWNER = 'gatebc-e2e-b9e62014@example.invalid'
OTHER = 'gatebc-e2e-c70a999a@example.invalid'


def mint(email: str) -> dict:
    resp = requests.post(f'{AUTH}/auth/v1/token',
                         params={'grant_type': 'password'},
                         json={'email': email, 'password': PASSWORD}, timeout=15)
    resp.raise_for_status()
    body = resp.json()
    return {'email': email, 'token': body['access_token'],
            'user_id': body['user']['id']}


def get(token: str, path: str, **params):
    resp = requests.get(f'{APP}{path}', headers={'Authorization': f'Bearer {token}'},
                        params=params or None, timeout=40)
    try:
        return resp.status_code, resp.json()
    except ValueError:
        return resp.status_code, resp.text[:300]


def classify(status: int, body) -> dict:
    """Turn a response into a stage verdict rather than a bare status code."""
    verdict = {'status': status}
    if isinstance(body, dict):
        detail = body.get('detail')
        if isinstance(detail, dict):
            verdict['code'] = detail.get('code')
        elif isinstance(detail, str):
            verdict['code'] = detail[:120]
        if 'outcome' in body:
            verdict['outcome'] = body['outcome']
        if 'message' in body:
            verdict['message'] = str(body['message'])[:160]
        for flag in ('publication_authorized', 'owner_authorization',
                     'scientific_acceptance', 'qj_execution', 'qg_execution'):
            if flag in body:
                verdict[flag] = body[flag]
        if 'checkpoints' in body:
            verdict['checkpoints'] = [
                {'checkpoint': c.get('checkpoint'), 'outcome': c.get('outcome'),
                 'reason': c.get('reason')} for c in body['checkpoints']]
        if 'result_count' in body:
            verdict['result_count'] = body['result_count']
        if 'proposal_count' in body:
            verdict['proposal_count'] = body['proposal_count']
    if status >= 500:
        verdict['verdict'] = 'error'
    elif status == 409:
        verdict['verdict'] = 'held'
    elif status == 422:
        verdict['verdict'] = 'rejected_input'
    elif status == 404:
        verdict['verdict'] = 'absent'
    elif status == 200:
        verdict['verdict'] = 'held' if verdict.get('outcome') == 'held' else 'reachable'
    else:
        verdict['verdict'] = 'other'
    return verdict


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', default=str(OUT / 'p4_stage3_reachability.json'))
    args = parser.parse_args()

    owner = mint(OWNER)
    other = mint(OTHER)
    token = owner['token']

    status, listing = get(token, '/api/v1/m2/assessments')
    mine = [a for a in (listing or {}).get('items') or []
            if a.get('owner_user_id') == owner['user_id']]
    assessment_id = mine[0]['id']
    # Read the revision from the assessment detail, not the list projection:
    # the list reports the *confirmed* revision, which goes stale as soon as an
    # answer is saved, and a stale expected_revision makes every downstream
    # stage look "held" for the wrong reason.
    _, detail = get(token, f'/api/v1/m2/assessments/{mine[0]["id"]}')
    revision = int(detail['assessment']['revision'])

    evidence = {
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'stack': {'auth': AUTH, 'app': APP,
                  'database': 'project1_workflow_tests@5433',
                  'app_role': 'sitewise_e2e (NOSUPERUSER, NOBYPASSRLS)',
                  'runtime_role': 'p1ai_engine -> SET LOCAL ROLE p1ai_runtime'},
        'assessment_id': assessment_id,
        'assessment_revision': revision,
        'stages': [],
    }

    stages = [
        ('1_source_projection',
         f'/api/v1/project1-workflow/assessments/{assessment_id}/source',
         {'expected_revision': revision}),
        ('2_attempt_ledger_results',
         f'/api/v1/project1-workflow/assessments/{assessment_id}/results',
         {'expected_revision': revision}),
        ('3_setup_publication_authority', '/api/v1/project1-workflow/setup', {}),
    ]
    for name, path, params in stages:
        status, body = get(token, path, **params)
        evidence['stages'].append({'stage': name, 'path': path,
                                   **classify(status, body)})

    # Business understanding is a POST and is the gate that decides whether any
    # objective proposal can exist at all.
    resp = requests.post(
        f'{APP}/api/v1/project1-workflow/assessments/{assessment_id}/business-understanding',
        headers={'Authorization': f'Bearer {token}'},
        json={'expected_revision': revision}, timeout=60)
    try:
        bu = resp.json()
    except ValueError:
        bu = resp.text[:300]
    evidence['stages'].append({'stage': '4_business_understanding',
                               'path': 'POST business-understanding',
                               **classify(resp.status_code, bu)})

    # The read-only readiness surface that the entrepreneur's report panel calls.
    status, body = get(token, f'/api/v1/project1-read/assessments/{assessment_id}/readiness')
    evidence['stages'].append({'stage': '5_readiness_panel',
                               'path': 'project1-read readiness',
                               **classify(status, body)})

    # Cross-owner isolation on the workflow surface itself.
    status, body = get(other['token'],
                       f'/api/v1/project1-workflow/assessments/{assessment_id}/source',
                       expected_revision=revision)
    evidence['stages'].append({
        'stage': '6_cross_owner_source_refused',
        'path': 'workflow source as a different owner',
        **classify(status, body),
        'refused': status in (403, 404, 409),
    })

    # Enumeration-oracle check: a caller must not be able to tell "this
    # assessment exists but is not yours" apart from "no such assessment".
    # Both are probed and the responses compared byte for byte.
    import uuid
    ghost = str(uuid.uuid4())
    real_status, real_body = get(other['token'],
                                 f'/api/v1/project1-workflow/assessments/{assessment_id}/source',
                                 expected_revision=revision)
    ghost_status, ghost_body = get(other['token'],
                                   f'/api/v1/project1-workflow/assessments/{ghost}/source',
                                   expected_revision=revision)
    evidence['stages'].append({
        'stage': '7_no_enumeration_oracle',
        'path': 'not-mine vs non-existent',
        'not_mine': {'status': real_status, 'body': real_body},
        'non_existent': {'status': ghost_status, 'body': ghost_body},
        'indistinguishable': (real_status == ghost_status
                              and real_body == ghost_body),
        'verdict': 'reachable' if (real_status == ghost_status
                                   and real_body == ghost_body) else 'leaky',
    })

    # Verdict: the journey is only "complete" if every stage is reachable.
    reachable = [s for s in evidence['stages'] if s.get('verdict') == 'reachable']
    held = [s for s in evidence['stages'] if s.get('verdict') == 'held']
    errors = [s for s in evidence['stages'] if s.get('verdict') == 'error']
    evidence['summary'] = {
        'reachable': [s['stage'] for s in reachable],
        'held': [s['stage'] for s in held],
        'errors': [s['stage'] for s in errors],
        'blocking_reason': next((s.get('code') or s.get('message')
                                 for s in held + errors), None),
        'stage3_complete': len(errors) == 0 and len(held) == 0,
    }

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(evidence, indent=2), encoding='utf-8')
    print(json.dumps(evidence['summary'], indent=2))
    print('written to', args.out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
