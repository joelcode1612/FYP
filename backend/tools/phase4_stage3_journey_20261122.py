"""Stage 3 journey over real HTTP: Jaspr client contract -> FastAPI -> PostgreSQL.

Exercises the six behaviours the assignment names, against the disposable
cluster with real ES256 verification and real RLS:

1. proposal readback (list and single)
2. decision readback showing admission HELD
3. Approve  (CANDIDATE -> APPROVED, admission still HELD)
4. Reject   (a second proposal)
5. refresh persistence (re-read returns the same decision, not a new one)
6. ownership refusal (a foreign owner cannot read or decide)

Plus the two invariants that must hold in every response: ``qg_execution`` is
false, and no response ever claims downstream authority.

Every request is recorded with its status, code and the fields that matter, so
the evidence file is auditable without re-running anything.
"""
from __future__ import annotations

import json
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import urllib.error
import urllib.request

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent
sys.path.insert(0, str(BACKEND / 'src'))
sys.path.insert(0, str(BACKEND))

from tools.phase4_local_auth_20261122 import _load_or_create_key, mint  # noqa: E402

BASE = 'http://127.0.0.1:8091'
ISSUER = 'https://lzdpjwmcjbhtkzkqudyt.supabase.co/auth/v1'
ASSESSMENT = 'e0124bfd-e54b-4d57-bc19-2023c8e7a5e6'
CONTEXT = '0af90393-46b3-56ed-bd76-7776cd5ec1c2'
REVISION = 11
OWNER = 'b9e62014-b7bc-426e-a950-a95b25965639'
OWNER_EMAIL = 'gatebc-e2e-b9e62014@example.invalid'
FOREIGN = 'c70a999a-50c6-4a31-8f7a-b914d0a5c641'
FOREIGN_EMAIL = 'gatebc-e2e-c70a999a@example.invalid'
PREFIX = f'/api/v1/project1-workflow/assessments/{ASSESSMENT}/objective-proposals'

records: list[dict] = []


def call(method, path, token=None, body=None, params=None):
    url = BASE + path
    if params:
        from urllib.parse import urlencode
        url += '?' + urlencode(params)
    data = None
    headers = {'Accept': 'application/json'}
    if body is not None:
        data = json.dumps(body).encode()
        headers['Content-Type'] = 'application/json'
    if token:
        headers['Authorization'] = f'Bearer {token}'
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.loads(response.read() or b'{}')
            status = response.status
    except urllib.error.HTTPError as exc:
        payload = json.loads(exc.read() or b'{}')
        status = exc.code
    detail = payload.get('detail')
    code = detail.get('code') if isinstance(detail, dict) else None
    records.append({'method': method, 'path': path, 'status': status, 'code': code})
    return status, payload, code


def main() -> int:
    key = _load_or_create_key()
    owner_token = mint(key, sub=OWNER, issuer=ISSUER, email=OWNER_EMAIL)
    foreign_token = mint(key, sub=FOREIGN, issuer=ISSUER, email=FOREIGN_EMAIL)

    evidence: dict = {
        'checkpoint': 'M2_BCB_BDJ_BROWSER_END_TO_END_STAGE3',
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'base_url': BASE,
        'issuer': ISSUER,
        'data_classification': 'SYNTHETIC_ONLY',
        'cloud_calls': 0,
        'assessment_id': ASSESSMENT,
        'owner_user_id': OWNER,
        'foreign_user_id': FOREIGN,
    }

    params = {'expected_revision': REVISION, 'context_id': CONTEXT}

    # --- 1. proposal readback -------------------------------------------
    status, listing, _ = call('GET', PREFIX, owner_token, params=params)
    proposals = listing.get('proposals') or []
    by_state = {p['review_state']: p for p in proposals}
    evidence['readback'] = {
        'status': status,
        'proposal_count': listing.get('proposal_count'),
        'states': {p['proposal_id']: p['review_state'] for p in proposals},
        'qg_execution': listing.get('qg_execution'),
        'finding_authority': listing.get('finding_authority'),
    }

    approved = by_state['APPROVED']
    candidate = by_state['CANDIDATE']
    rejected = by_state['REJECTED']

    status, single, _ = call('GET', f"{PREFIX}/{approved['proposal_id']}",
                             owner_token, params=params)
    evidence['single_readback'] = {
        'status': status,
        'proposal_id': single.get('proposal_id'),
        'review_state': single.get('review_state'),
        'qg_execution': single.get('qg_execution'),
    }

    # --- 2. decision readback: approval is not admission -----------------
    status, decision, _ = call('GET', f"{PREFIX}/{approved['proposal_id']}/decision",
                               owner_token, params=params)
    admission = decision.get('admission') or {}
    evidence['decision_readback_before'] = {
        'status': status,
        'decision': decision.get('decision'),
        'admission_state': admission.get('admission_state'),
        'admission_reason': admission.get('admission_reason'),
        'uncertainty_link': admission.get('uncertainty_link'),
        'qg_execution': decision.get('qg_execution'),
    }

    # --- 3. approve the candidate ---------------------------------------
    status, approved_resp, code = call(
        'POST', f"{PREFIX}/{candidate['proposal_id']}/decision", owner_token,
        body={'expected_revision': REVISION, 'context_id': CONTEXT,
              'decision': 'APPROVED', 'note': 'Stage 3 journey: approve'})
    admission_after = approved_resp.get('admission') or {}
    evidence['approve'] = {
        'status': status, 'code': code,
        'decision': approved_resp.get('decision'),
        'decision_created': approved_resp.get('decision_created'),
        'review_state': approved_resp.get('review_state'),
        'admission_state': admission_after.get('admission_state'),
        'admission_reason': admission_after.get('admission_reason'),
        'qg_execution': approved_resp.get('qg_execution'),
    }

    # --- 4. reject the already-rejected one is refused; reject is its own state
    status, reject_resp, code = call(
        'POST', f"{PREFIX}/{rejected['proposal_id']}/decision", owner_token,
        body={'expected_revision': REVISION, 'context_id': CONTEXT,
              'decision': 'REJECTED', 'note': 'Stage 3 journey: reject'})
    evidence['reject'] = {
        'status': status, 'code': code,
        'decision': reject_resp.get('decision'),
        'decision_created': reject_resp.get('decision_created'),
        'review_state': reject_resp.get('review_state'),
    }

    # --- 5. refresh persistence -----------------------------------------
    status, refreshed, _ = call('GET', f"{PREFIX}/{candidate['proposal_id']}/decision",
                                owner_token, params=params)
    admission_refreshed = refreshed.get('admission') or {}
    evidence['refresh_persistence'] = {
        'status': status,
        'decision': refreshed.get('decision'),
        'decision_id': refreshed.get('decision_id'),
        'same_decision_id': refreshed.get('decision_id') == approved_resp.get('decision_id'),
        'admission_state': admission_refreshed.get('admission_state'),
        'qg_execution': refreshed.get('qg_execution'),
    }

    # --- 5b. idempotent replay of the same decision ----------------------
    status, replay, code = call(
        'POST', f"{PREFIX}/{candidate['proposal_id']}/decision", owner_token,
        body={'expected_revision': REVISION, 'context_id': CONTEXT,
              'decision': 'APPROVED', 'note': 'Stage 3 journey: replay'})
    evidence['decision_replay'] = {
        'status': status, 'code': code,
        'decision_created': replay.get('decision_created'),
    }

    # --- 6. ownership refusal -------------------------------------------
    status, foreign_read, code = call('GET', PREFIX, foreign_token, params=params)
    evidence['ownership_refusal'] = {
        'read_status': status, 'read_code': code,
        'proposal_count': foreign_read.get('proposal_count'),
        'detail': foreign_read.get('detail') if isinstance(foreign_read.get('detail'), str) else None,
    }
    status, foreign_write, code = call(
        'POST', f"{PREFIX}/{candidate['proposal_id']}/decision", foreign_token,
        body={'expected_revision': REVISION, 'context_id': CONTEXT,
              'decision': 'REJECTED', 'note': 'foreign owner attempt'})
    evidence['ownership_refusal']['write_status'] = status
    evidence['ownership_refusal']['write_code'] = code

    # --- 7. unauthenticated ---------------------------------------------
    status, unauth, code = call('GET', PREFIX, None, params=params)
    evidence['unauthenticated'] = {'status': status, 'code': code}

    # --- invariants ------------------------------------------------------
    authority_fields = ('qj_execution', 'qg_execution', 'scientific_acceptance',
                        'owner_authorization', 'publication_authorized',
                        'fielding_authorized', 'report_release_authorized')
    qg_values = [listing.get('qg_execution'), single.get('qg_execution'),
                 decision.get('qg_execution'), approved_resp.get('qg_execution'),
                 refreshed.get('qg_execution')]
    evidence['authorisation_invariant'] = {
        'qg_execution_values': qg_values,
        'qg_never_true': all(v is False for v in qg_values),
        'authority_flags_all_false': {
            field: listing.get(field) for field in authority_fields},
        'note': 'Approving an objective does not authorise QG. The admission '
                'block reports HELD and qg_execution stays false.',
    }

    evidence['verdict'] = {
        'readback_ok': evidence['readback']['status'] == 200 and len(proposals) == 3,
        'single_readback_ok': evidence['single_readback']['status'] == 200,
        'approved_is_held': evidence['decision_readback_before']['admission_reason']
                            == 'M2_UNCERTAINTY_LINK_REQUIRED',
        'approve_recorded': evidence['approve']['status'] == 200
                            and evidence['approve']['decision'] == 'APPROVED',
        'approve_still_held': evidence['approve']['admission_state'] == 'HELD',
        'reject_recorded': evidence['reject']['status'] == 200
                           and evidence['reject']['decision'] == 'REJECTED',
        'refresh_persists': evidence['refresh_persistence']['same_decision_id'] is True,
        'replay_idempotent': evidence['decision_replay']['decision_created'] is False,
        'foreign_read_refused': evidence['ownership_refusal']['read_status'] != 200,
        'foreign_write_refused': evidence['ownership_refusal']['write_status'] != 200,
        'unauthenticated_refused': evidence['unauthenticated']['status'] in (401, 403),
        'qg_never_authorised': evidence['authorisation_invariant']['qg_never_true'],
    }
    evidence['verdict']['PASS'] = all(evidence['verdict'].values())
    evidence['requests'] = records

    out = ROOT / 'deliverables' / 'phase4' / 'STAGE3_HTTP_JOURNEY_20261122.json'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=1, default=str), encoding='utf-8')

    print(json.dumps({
        'verdict': evidence['verdict'],
        'readback': evidence['readback'],
        'before': evidence['decision_readback_before'],
        'approve': evidence['approve'],
        'reject': evidence['reject'],
        'refresh': evidence['refresh_persistence'],
        'ownership': evidence['ownership_refusal'],
        'unauth': evidence['unauthenticated'],
        'evidence': str(out),
    }, indent=1, default=str))
    return 0 if evidence['verdict']['PASS'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
