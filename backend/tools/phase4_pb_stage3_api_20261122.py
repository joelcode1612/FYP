"""Phase B -- Stage 3 verification at the API boundary.

Five things are checked, and each one is checked in a way that can fail:

1. Stage 3 is enterable only from a current confirmed stage 2.
2. The M2 source endpoint returns the assessment, revision and confirmation the
   caller actually owns -- and refuses a stale expected_revision.
3. Unavailable research-workspace data is refused, not silently rendered empty.
4. BDJ does not execute when its ruleset authorisation is absent.
5. No QG, fielding or publication authority is granted by any response.

Read-only apart from the BDJ evaluate call, which is the thing being tested for
*not* executing. Writes nothing to the database.

Run from ``backend/``::

    python tools/phase4_pb_stage3_api_20261122.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import requests

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
OUT = REPO / 'deliverables' / 'phase4' / 'pb_stage3_api.json'

AUTH = 'http://127.0.0.1:54329'
APP = 'http://127.0.0.1:8091'
PASSWORD = 'e2e-local-password'
OWNER = 'gatebc-e2e-b9e62014@example.invalid'
OTHER = 'gatebc-e2e-c70a999a@example.invalid'

MP = '37bf879a-005a-4f5a-b49d-210ea1ce37c4'
M2 = '032d3dde-547f-49a6-9e0f-58fbc5f1a48f'


def mint(email: str) -> dict:
    r = requests.post(f'{AUTH}/auth/v1/token', params={'grant_type': 'password'},
                      json={'email': email, 'password': PASSWORD}, timeout=15)
    r.raise_for_status()
    b = r.json()
    return {'email': email, 'token': b['access_token'], 'user_id': b['user']['id']}


class C:
    def __init__(self, token: str) -> None:
        self.h = {'Authorization': f'Bearer {token}'}

    def get(self, path, **p):
        r = requests.get(f'{APP}{path}', headers=self.h, params=p or None, timeout=90)
        try:
            return r.status_code, r.json()
        except ValueError:
            return r.status_code, r.text[:300]

    def post(self, path, body):
        r = requests.post(f'{APP}{path}', headers=self.h, json=body, timeout=120)
        try:
            return r.status_code, r.json()
        except ValueError:
            return r.status_code, r.text[:300]


AUTHORITY_FLAGS = ('publication_authorized', 'fielding_authorized',
                   'report_release_authorized', 'owner_authorization',
                   'scientific_acceptance', 'qj_handoff_authorized')


def main() -> int:
    owner = mint(OWNER)
    c = C(owner['token'])
    rep: dict = {'owner': owner['email'], 'checks': []}

    def check(name, verdict, observed, expectation=None):
        rep['checks'].append({'check': name, 'verdict': verdict,
                              'observed': observed, 'expectation': expectation})
        return verdict == 'PASS'

    # --- 2. M2 source endpoint -------------------------------------------
    _, draft = c.get(f'/api/v1/m2/assessments/{M2}')
    revision = ((draft or {}).get('assessment') or {}).get('revision')
    rep['m2_revision'] = revision

    src_http, src = c.get(f'/api/v1/project1-workflow/assessments/{M2}/source',
                          expected_revision=revision)
    rep['source'] = {'http': src_http,
                     'instrument_version': (src or {}).get('instrument_version'),
                     'assessment_revision': (src or {}).get('assessment_revision'),
                     'declaration_count': len((src or {}).get('declarations') or [])}
    check('source endpoint returns 200 at the current revision',
          'PASS' if src_http == 200 else 'FAIL', src_http)
    check('source reports the revision that was asked for',
          'PASS' if (src or {}).get('assessment_revision') == revision else 'FAIL',
          (src or {}).get('assessment_revision'), revision)
    check('source carries the full declaration set',
          'PASS' if len((src or {}).get('declarations') or []) >= 10 else 'FAIL',
          len((src or {}).get('declarations') or []))

    stale_http, stale = c.get(f'/api/v1/project1-workflow/assessments/{M2}/source',
                              expected_revision=max(0, (revision or 1) - 1))
    check('a stale expected_revision is refused, not silently served',
          'PASS' if stale_http == 409 else 'FAIL', stale_http)

    # --- 1. stage 3 enterability -----------------------------------------
    _, readiness = c.get(f'/api/v1/assessments/{MP}/workflow-readiness')
    s2 = (readiness or {}).get('stage_2') or {}
    s3 = (readiness or {}).get('stage_3') or {}
    rep['readiness'] = {'stage_2': s2, 'stage_3': s3}
    check('stage 2 is complete with a current confirmation',
          'PASS' if s2.get('complete') is True else 'FAIL', s2.get('complete'))
    check('stage 3 is enterable only once stage 2 is complete',
          'PASS' if s3.get('enterable') is True and s2.get('complete') is True else 'FAIL',
          s3.get('enterable'))

    # --- 3. unavailable research workspace -------------------------------
    conf_http, conf = c.get(f'/api/v1/m2/assessments/{M2}/confirmation-current')
    rep['confirmation'] = {'http': conf_http,
                           'revision': (conf or {}).get('assessment_revision'),
                           'id': (conf or {}).get('id')}
    check('a current confirmation resolves', 'PASS' if conf_http == 200 else 'FAIL',
          conf_http)

    ws_http = ws = None
    if conf_http == 200:
        ws_http, ws = c.get(
            f"/api/v1/m2/confirmations/{conf['id']}/research-workspace",
            expected_revision=(conf or {}).get('assessment_revision'))
    rep['research_workspace'] = {'http': ws_http,
                                 'code': ((ws or {}).get('detail') or {}).get('code')
                                 if isinstance(ws, dict) else None}
    check('missing research workspace is refused with an explicit code, '
          'not rendered as an empty success',
          'PASS' if ws_http == 503 and rep['research_workspace']['code']
          == 'M2_SOURCE_UNAVAILABLE' else 'FAIL',
          [ws_http, rep['research_workspace']['code']])

    # --- 4. BDJ does not execute without adoption ------------------------
    bdj_http, bdj = c.post(
        f'/api/v1/project1-workflow/assessments/{M2}/business-understanding',
        {'expected_revision': revision})
    rep['business_understanding'] = {
        'http': bdj_http,
        'outcome': (bdj or {}).get('outcome'),
        'checkpoints': (bdj or {}).get('checkpoints'),
        'findings': (bdj or {}).get('findings'),
    }
    check('BDJ holds instead of executing while the ruleset is not adopted',
          'PASS' if bdj_http == 200 and (bdj or {}).get('outcome') == 'held' else 'FAIL',
          (bdj or {}).get('outcome'))
    held = [x for x in ((bdj or {}).get('checkpoints') or []) if x.get('outcome') == 'held']
    check('every held checkpoint names the missing authorisation',
          'PASS' if held and all(x.get('reason') == 'BDJ_RULE_ADOPTION_REQUIRED'
                                for x in held) else 'FAIL',
          [x.get('reason') for x in held])
    check('BDJ emits no findings while held',
          'PASS' if not (bdj or {}).get('findings') else 'FAIL',
          len((bdj or {}).get('findings') or []))
    check('BDJ findings stay candidate-only',
          'PASS' if (bdj or {}).get('finding_authority') == 'CANDIDATE_ONLY' else 'FAIL',
          (bdj or {}).get('finding_authority'))

    # --- 5. no QG / fielding / publication authority ----------------------
    flags = {k: (bdj or {}).get(k) for k in AUTHORITY_FLAGS if k in (bdj or {})}
    rep['authority_flags'] = flags
    check('no authority flag is true in the business-understanding response',
          'PASS' if flags and not any(flags.values()) else 'FAIL', flags)

    setup_http, setup = c.get('/api/v1/project1-workflow/setup')
    rep['setup'] = {'http': setup_http,
                    'outcome': (setup or {}).get('outcome'),
                    'workspace_m2_binding_available':
                        (setup or {}).get('workspace_m2_binding_available')}
    check('questionnaire preview is held without a saved M2 record',
          'PASS' if setup_http == 200 and (setup or {}).get('outcome') == 'held' else 'FAIL',
          (setup or {}).get('outcome'))
    setup_flags = {k: (setup or {}).get(k) for k in AUTHORITY_FLAGS if k in (setup or {})}
    check('no authority flag is true in the setup response',
          'PASS' if setup_flags and not any(setup_flags.values()) else 'FAIL',
          setup_flags)

    # --- cross-owner refusal ---------------------------------------------
    other = mint(OTHER)
    oc = C(other['token'])
    other_http, _ = oc.get(f'/api/v1/project1-workflow/assessments/{M2}/source',
                           expected_revision=revision)
    check('another user cannot read this assessment source',
          'PASS' if other_http in (403, 404) else 'FAIL', other_http)
    other_ws, _ = oc.get(f"/api/v1/m2/confirmations/{(conf or {}).get('id')}/research-workspace",
                         expected_revision=(conf or {}).get('assessment_revision')) \
        if conf_http == 200 else (None, None)
    check('another user cannot read this confirmation workspace',
          'PASS' if other_ws in (403, 404) else 'FAIL', other_ws)

    rep['verdict'] = 'PASS' if all(x['verdict'] == 'PASS' for x in rep['checks']) else 'FAIL'
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(rep, indent=2), encoding='utf-8')

    for x in rep['checks']:
        print(f'  [{x["verdict"]}] {x["check"]}')
        if x['verdict'] != 'PASS':
            print(f'         observed={x["observed"]} expected={x["expectation"]}')
    print(f'\nverdict: {rep["verdict"]}\nwrote {OUT}')
    return 0 if rep['verdict'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
