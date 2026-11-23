"""P4 — owner-selected-answer coverage against the disposable M2 workflow.

Scope (approved by the user): the entrepreneur choosing an answer for an
authorized M2 instrument item, and that choice surviving a readback, refusing
a stale write, and refusing a different owner.

What this proves, and what it deliberately does not
---------------------------------------------------
* It talks only to the local disposable stack: GoTrue stub on
  ``127.0.0.1:54329`` and the app on ``127.0.0.1:8091`` whose three database
  URLs all resolve to ``project1_workflow_tests@5433``. Every database write is
  therefore inside the disposable cluster.
* It never contacts live Supabase and never injects a fabricated browser
  session: the tokens are minted by the stub from real password grants.
* It does **not** cover step-5 questionnaire publishing. That control is
  hard-disabled in the UI (``project1_read_panel.dart:87-94``) and there is no
  authorized routed questionnaire to publish, so there is nothing to exercise.

Evidence is written to ``deliverables/phase4/p4_owner_answers.json``.
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

# Item whose options are a closed single-choice set, so a write is unambiguous.
# M2V1-01 was the first choice but it is a GEO item, and the disposable stack
# has no approved versioned GEO catalogue, so it refuses every write with
# 422 "No area reference can be invented." That refusal is recorded as its own
# step below rather than being papered over — it is a real provisioning gap.
ITEM = 'M2V1-02'
GEO_ITEM = 'M2V1-01'


def mint(email: str) -> dict:
    """Password grant against the stub. Raises if the grant is refused."""
    resp = requests.post(
        f'{AUTH}/auth/v1/token',
        params={'grant_type': 'password'},
        json={'email': email, 'password': PASSWORD},
        timeout=15,
    )
    resp.raise_for_status()
    body = resp.json()
    return {'email': email, 'token': body['access_token'],
            'user_id': body['user']['id']}


def call(session_token: str, method: str, path: str, **kwargs):
    """One authenticated call. Returns (status, parsed_body)."""
    headers = {'Authorization': f'Bearer {session_token}'}
    resp = requests.request(method, f'{APP}{path}', headers=headers,
                            timeout=30, **kwargs)
    try:
        body = resp.json()
    except ValueError:
        body = resp.text[:400]
    return resp.status_code, body


def summarise(status: int, body) -> dict:
    """Compact, stable evidence — no tokens, no full instrument dump."""
    if isinstance(body, dict):
        if 'detail' in body and len(body) <= 2:
            return {'status': status, 'detail': body['detail']}
        keep = {}
        for key in ('contract_version', 'assessment', 'answers',
                    'derived_selections', 'current_review_completed',
                    'current_confirmation_valid', 'review', 'questionnaire'):
            if key in body:
                keep[key] = body[key]
        if not keep:
            keep = {'keys': sorted(body)[:12]}
        return {'status': status, **keep}
    return {'status': status, 'body': body}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', default=str(OUT / 'p4_owner_answers.json'))
    args = parser.parse_args()

    evidence: dict = {
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'stack': {'auth': AUTH, 'app': APP,
                  'database': 'project1_workflow_tests@5433'},
        'item': ITEM,
        'steps': [],
    }

    owner = mint(OWNER)
    other = mint(OTHER)
    evidence['actors'] = {'owner': owner['user_id'], 'other': other['user_id']}
    if owner['user_id'] == other['user_id']:
        evidence['fatal'] = 'the two synthetic identities collapsed to one user'
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(evidence, indent=2), encoding='utf-8')
        return 2

    # ---- 1. locate the owner's assessment -------------------------------
    status, listing = call(owner['token'], 'GET', '/api/v1/m2/assessments')
    items = (listing or {}).get('items') or []
    mine = [a for a in items if a.get('owner_user_id') == owner['user_id']]
    if not mine:
        evidence['fatal'] = 'owner has no M2 assessment on the disposable stack'
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(evidence, indent=2), encoding='utf-8')
        return 3
    assessment_id = mine[0]['id']
    evidence['assessment_id'] = assessment_id
    evidence['steps'].append({'step': 'list_owner_assessments',
                              'status': status, 'count': len(mine)})

    # ---- 2. read baseline ------------------------------------------------
    status, before = call(owner['token'], 'GET',
                          f'/api/v1/m2/assessments/{assessment_id}')
    revision = int(before['assessment']['revision'])
    options = []
    for item in before.get('items', []):
        if item.get('item_key') == ITEM:
            options = [o['code'] for o in
                       (item.get('option_values') or {}).get('options', [])]
            break
    prior = (before.get('answers') or {}).get(ITEM)
    prior_value = (prior or {}).get('value_json')
    evidence['steps'].append({
        'step': 'read_baseline', 'status': status, 'revision': revision,
        'item': ITEM, 'prior_value': prior_value, 'options': options,
    })

    # ---- 2b. GEO item refusal (documented provisioning gap) --------------
    # The GEO answer path needs an approved versioned area catalogue. The
    # disposable stack has none, and the service correctly refuses rather than
    # inventing an area reference. Recorded so the gap is visible, not hidden.
    geo_status, geo_body = call(
        owner['token'], 'PUT',
        f'/api/v1/m2/assessments/{assessment_id}/answers/{GEO_ITEM}',
        json={'expected_revision': revision, 'answer_state': 'ANSWERED',
              'value': 'PENANG'},
    )
    evidence['steps'].append({
        'step': 'geo_item_refused_no_catalogue', 'status': geo_status,
        'item': GEO_ITEM, 'result': summarise(geo_status, geo_body),
        'refused_as_designed': geo_status == 422,
    })

    # Pick an option that actually differs from what is stored, so the write is
    # observable rather than a no-op that could pass for a success.
    target = next((o for o in options if o != prior_value), None)
    if target is None:
        evidence['fatal'] = f'no alternative option for {ITEM}'
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(evidence, indent=2), encoding='utf-8')
        return 4
    evidence['chosen_value'] = target

    # ---- 3. owner selects an answer --------------------------------------
    status, body = call(
        owner['token'], 'PUT',
        f'/api/v1/m2/assessments/{assessment_id}/answers/{ITEM}',
        json={'expected_revision': revision, 'answer_state': 'ANSWERED',
              'value': target},
    )
    evidence['steps'].append({
        'step': 'owner_selects_answer', 'status': status,
        'expected_revision': revision, 'sent_value': target,
        'result': summarise(status, body),
    })
    write_ok = status in (200, 201)

    # ---- 4. readback ------------------------------------------------------
    status, after = call(owner['token'], 'GET',
                         f'/api/v1/m2/assessments/{assessment_id}')
    stored = ((after.get('answers') or {}).get(ITEM) or {}).get('value_json')
    new_revision = int(after['assessment']['revision'])
    evidence['steps'].append({
        'step': 'readback_after_write', 'status': status,
        'stored_value': stored, 'revision': new_revision,
        'persisted': stored == target,
        'revision_advanced': new_revision > revision,
    })

    # ---- 5. stale revision must be refused -------------------------------
    status, body = call(
        owner['token'], 'PUT',
        f'/api/v1/m2/assessments/{assessment_id}/answers/{ITEM}',
        json={'expected_revision': revision, 'answer_state': 'ANSWERED',
              'value': prior_value or target},
    )
    evidence['steps'].append({
        'step': 'stale_revision_refused', 'status': status,
        'expected_revision': revision, 'current_revision': new_revision,
        'refused': status >= 400, 'result': summarise(status, body),
    })

    # ---- 6. a different owner must be refused ----------------------------
    status, body = call(
        other['token'], 'PUT',
        f'/api/v1/m2/assessments/{assessment_id}/answers/{ITEM}',
        json={'expected_revision': new_revision, 'answer_state': 'ANSWERED',
              'value': target},
    )
    evidence['steps'].append({
        'step': 'cross_owner_write_refused', 'status': status,
        'refused': status in (403, 404), 'result': summarise(status, body),
    })

    # ---- 7. a different owner must not read it either --------------------
    status, body = call(other['token'], 'GET',
                        f'/api/v1/m2/assessments/{assessment_id}')
    evidence['steps'].append({
        'step': 'cross_owner_read_refused', 'status': status,
        'refused': status in (403, 404), 'result': summarise(status, body),
    })

    # ---- verdict ----------------------------------------------------------
    def step(name: str) -> dict:
        return next(s for s in evidence['steps'] if s['step'] == name)

    checks = {
        'owner_write_accepted': write_ok,
        'answer_persisted': step('readback_after_write')['persisted'],
        'revision_advanced': step('readback_after_write')['revision_advanced'],
        'stale_write_refused': step('stale_revision_refused')['refused'],
        'cross_owner_write_refused': step('cross_owner_write_refused')['refused'],
        'cross_owner_read_refused': step('cross_owner_read_refused')['refused'],
        'geo_item_refused_cleanly': step('geo_item_refused_no_catalogue')[
            'refused_as_designed'],
    }
    evidence['checks'] = checks
    evidence['passed'] = all(checks.values())

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(evidence, indent=2), encoding='utf-8')
    print(json.dumps({'passed': evidence['passed'], 'checks': checks,
                      'out': args.out}, indent=2))
    return 0 if evidence['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
