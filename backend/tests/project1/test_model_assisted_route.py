"""Model-assisted route: gates, error mapping, persistence, no leakage.

All provider calls go through a fixture provider; there is no network, no paid
dispatch and no TokenHarbor credential in this file. The database is the
isolated clone under the restricted principal. The packet source is injected
because the real M2 projection carries no synthetic data-class marker, so the
route's real-data refusal is the production behaviour and the synthetic packet
is the test's authorized input.

Set:

    PROJECT1_CLONE_URL        login as p1ai_engine (SET ROLE p1ai_runtime)
    PROJECT1_CLONE_ADMIN_URL  fixture setup only
"""
import hashlib
import json
import os
from pathlib import Path
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from sitewise.api.v1 import project1_workflow as api
from sitewise.core.config import settings
from sitewise.db.session import get_db
from sitewise.domain import bdj_candidate_rules
from sitewise.main import workflow_held_handler
from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.prompts import PROMPTS
from sitewise.project1.provider import ModelRunner
from sitewise.project1.runs import effective_policy_fingerprint, work_identity_for

RESTRICTED_URL = os.environ.get('PROJECT1_CLONE_URL')
ADMIN_URL = os.environ.get('PROJECT1_CLONE_ADMIN_URL')
CLONE = 'project1_workflow_tests'

if not (RESTRICTED_URL and ADMIN_URL):
    pytest.skip('PROJECT1_CLONE_URL and PROJECT1_CLONE_ADMIN_URL required',
                allow_module_level=True)
if make_url(RESTRICTED_URL).database != CLONE or make_url(ADMIN_URL).database != CLONE:
    pytest.skip('clone-only tests; refusing a non-clone database', allow_module_level=True)

ENDPOINT_PATH = '/project1-workflow/assessments/{assessment}/business-understanding/model-assisted'
ANSWER_TAKEAWAY = 'We are takeaway-only.'
ANSWER_DINE = 'DINE_IN_FOCUSED'
PROMPT_TEXT = 'You are a bounded business declaration reviewer.'


def synthetic_packet(assessment_id, revision, data_class='SYNTHETIC_NONHUMAN'):
    content = {
        'schema_version': 'project1-m2-projection/1-candidate',
        'assessment_id': str(assessment_id), 'assessment_revision': revision,
        'instrument_id': str(uuid4()), 'instrument_version': 'M2-20261113-1',
        'instrument_digest': '0' * 64,
        'declarations': [
            {'item_key': 'M2-04', 'question': 'Describe the service format.',
             'item_version_id': 'item-04-v1', 'definition_digest': '1' * 64,
             'answer_revision_id': 'answer-04-r1', 'answer_revision': revision,
             'answer_state': 'ANSWERED', 'value': ANSWER_TAKEAWAY,
             'trust_class': 'ENTREPRENEUR_DECLARED'},
            {'item_key': 'M2-05', 'question': 'Select the service format.',
             'item_version_id': 'item-05-v1', 'definition_digest': '2' * 64,
             'answer_revision_id': 'answer-05-r1', 'answer_revision': revision,
             'answer_state': 'ANSWERED', 'value': ANSWER_DINE,
             'trust_class': 'ENTREPRENEUR_DECLARED'},
        ],
        'governance_items': ['M2-20', 'M2-21'],
        'excluded_items': {'M2-11': 'DEFERRED', 'M2-15': 'PRIVACY_PENDING'},
        'confirmed': True, 'facts_independently_verified': False,
        'data_class': data_class, 'purpose': 'SYNTHETIC_BDJ_DIAGNOSTIC',
    }
    return {**content, 'source_fingerprint': digest(content)}


class FixtureProvider:
    """Same call surface as TokenHarbor; no network and a call counter."""
    mode = 'json_schema'

    def __init__(self, output=None, error=None):
        self.output, self.error, self.calls = output, error, 0

    def complete(self, messages, output_type):
        self.calls += 1
        if self.error is not None:
            raise self.error
        return self.output


def valid_output():
    return {'issues': [], 'overall_note': 'No model issues.'}


def invalid_output():
    return {'issues': [{
        'rule_id': 'NOT_A_REGISTERED_RULE', 'kind': 'UNSUPPORTED_ASSERTION',
        'source_refs': [{'item_key': 'M2-04', 'answer_revision_id': 'answer-04-r1',
                         'item_version_id': 'item-04-v1', 'quote': ANSWER_TAKEAWAY}],
        'observed_condition': 'Synthetic.', 'counterargument': 'Synthetic.',
        'justification': 'Synthetic.', 'next_action': 'Synthetic.'}],
        'overall_note': 'One invalid candidate.'}


@pytest.fixture(scope='module')
def engines():
    restricted = create_engine(RESTRICTED_URL, hide_parameters=True)
    admin = create_engine(ADMIN_URL, hide_parameters=True)
    yield restricted, admin
    restricted.dispose()
    admin.dispose()


@pytest.fixture(autouse=True)
def configured(monkeypatch):
    rule_file = Path(bdj_candidate_rules.__file__).read_bytes()
    monkeypatch.setattr(settings, 'tokenharbor_enabled', True)
    monkeypatch.setattr(settings, 'project1_rules_version', 'BDJ-RULESET-0.2-CAND')
    monkeypatch.setattr(settings, 'project1_rules_sha256',
                        hashlib.sha256(rule_file).hexdigest())
    monkeypatch.setattr(settings, 'project1_rules_adoption_receipt',
                        'CP04A-TEST-RECEIPT')


@pytest.fixture
def case(engines):
    restricted, admin = engines
    actor, instrument, assessment = uuid4(), uuid4(), uuid4()
    revision = 2
    with admin.begin() as conn:
        conn.execute(text(
            "INSERT INTO public.users(user_id,email,role,account_status,email_verified,"
            "created_at,updated_at) VALUES (:id,:email,'entrepreneur','active',true,"
            "now(),now())"), {'id': actor, 'email': f'cp04a.route.{actor.hex}@example.test'})
        conn.execute(text(
            "INSERT INTO public.m2_instrument_versions(id,code,version_tag,approval_state,"
            "schema_digest) VALUES (:id,:code,'SYN-V1','AUTHORIZED',:h)"),
            {'id': instrument, 'code': 'ROUTE-' + instrument.hex[:12], 'h': 'b' * 64})
        conn.execute(text(
            'INSERT INTO public.m2_assessments(id,owner_user_id,instrument_id,revision)'
            ' VALUES (:a,:o,:i,:r)'), {'a': assessment, 'o': actor, 'i': instrument,
                                       'r': revision})
    return SimpleNamespace(restricted=restricted, admin=admin, actor=actor,
                           assessment=assessment, revision=revision)


def build_app(case, *, packet_source, provider):
    def runner_factory(ledger, disclosure, prompts):
        return ModelRunner(provider, ledger, prompts, disclosure=disclosure)

    app = FastAPI()
    app.include_router(api.router, prefix='/project1-workflow')
    app.add_exception_handler(WorkflowHeld, workflow_held_handler)
    app.dependency_overrides[api.configuration_gate] = lambda: None
    app.dependency_overrides[api.get_packet_source] = lambda: packet_source
    app.dependency_overrides[api.get_runtime_engine] = lambda: case.restricted
    app.dependency_overrides[api.get_runner_factory] = lambda: runner_factory
    app.dependency_overrides[api.require_entrepreneur] = lambda: SimpleNamespace(
        user_id=case.actor)
    # Packet fixtures do not open any source DB, including the original Dss.
    app.dependency_overrides[api.get_workflow_source_db] = lambda: None
    return TestClient(app)


def source_for(case, packet, owners=None):
    owners = owners or {}

    def read(session, user, assessment_id, revision):
        if owners and owners.get(assessment_id) != user.user_id:
            raise HTTPException(404, detail='Assessment not found.')
        return packet
    return read


def post(client, case, revision=None):
    return client.post(
        ENDPOINT_PATH.format(assessment=case.assessment),
        json={'expected_revision': case.revision if revision is None else revision})


def test_m2_route_to_existing_runner_and_private_result_store(case, monkeypatch):
    """Private DB and synthetic packet only; no TokenHarbor network access."""
    from contextlib import contextmanager
    from sitewise.api.v1 import m2
    from sitewise.dependencies import get_m2_service

    packet = synthetic_packet(case.assessment, case.revision)
    confirmation_id = uuid4()
    packet['confirmation'] = {'confirmation_id': str(confirmation_id), 'snapshot_digest': 'd' * 64}
    packet['source_fingerprint'] = digest({k: v for k, v in packet.items() if k != 'source_fingerprint'})
    provider = FixtureProvider(valid_output())
    source = source_for(case, packet)
    client = build_app(case, packet_source=source, provider=provider)

    class ConfirmedFixture:
        repo = SimpleNamespace(session=object())

        def __init__(self):
            self.repo.latest_confirmation = lambda assessment, actor: {'id': confirmation_id}

        @contextmanager
        def locked_confirmed_source(self, assessment, actor, **kwargs):
            assert assessment == case.assessment and actor == case.actor
            assert kwargs['expected_revision'] == case.revision
            yield {'source_status': 'SYNTHETIC_TEST_ONLY'}

    client.app.include_router(m2.router, prefix='/api/v1/m2')
    client.app.dependency_overrides[get_m2_service] = ConfirmedFixture
    monkeypatch.setattr(api, 'configuration_gate', lambda session: None)
    monkeypatch.setattr(api, 'source', source)
    monkeypatch.setattr(api, 'get_runtime_engine', lambda: case.restricted)
    monkeypatch.setattr(api, 'configured_runner',
        lambda ledger, disclosure, prompts: ModelRunner(provider, ledger, prompts, disclosure=disclosure))
    response = client.post(f'/api/v1/m2/assessments/{case.assessment}/bdj/evaluate',
                           json={'expected_revision': case.revision})
    assert response.status_code == 200, response.text
    assert provider.calls == 1
    body = response.json()
    assert body['finding_authority'] == 'CANDIDATE_ONLY'
    assert body['assessment_id'] == str(case.assessment)
    assert result_row(case, body['result_id'])['validation_status'] == 'valid'
    assert attempt_count(case) == 1
    from sitewise.project1.result_store import results_for_assessment
    from sitewise.project1.key_custody import LocalKeyCustody
    current = results_for_assessment(case.restricted, case.actor, case.assessment,
        payload_custody=LocalKeyCustody(), expected_revision=case.revision,
        expected_fingerprint=packet['source_fingerprint'])
    assert len(current) == 1 and str(current[0]['result_id']) == body['result_id']
    assert results_for_assessment(case.restricted, case.actor, case.assessment,
        payload_custody=LocalKeyCustody(), expected_revision=case.revision,
        expected_fingerprint='f' * 64) == []
    assert results_for_assessment(case.restricted, uuid4(), case.assessment,
        payload_custody=LocalKeyCustody(), expected_revision=case.revision,
        expected_fingerprint=packet['source_fingerprint']) == []
    read = client.get(f'/api/v1/m2/assessments/{case.assessment}/bdj/current',
                      params={'confirmation_id': str(confirmation_id), 'expected_revision':case.revision})
    assert read.status_code == 200, read.text
    assert read.json()['status'] == 'COMPLETED_WITH_FINDINGS'
    assert read.json()['result']['result_id'] == body['result_id']
    assert provider.calls == 1


def result_row(case, result_id):
    with case.admin.connect() as conn:
        return conn.execute(text(
            'SELECT review_outcome, execution_outcome, validation_status, finding_count,'
            ' result_payload::text AS payload FROM project1_ai.bdj_results'
            ' WHERE result_id=:id'), {'id': result_id}).mappings().one()


def run_count(case):
    with case.admin.connect() as conn:
        return conn.execute(text(
            'SELECT count(*) FROM project1_ai.runs WHERE assessment_id=:a'),
            {'a': case.assessment}).scalar()


def attempt_count(case):
    with case.admin.connect() as conn:
        return conn.execute(text(
            'SELECT count(*) FROM project1_ai.attempts a JOIN project1_ai.runs r'
            ' ON r.id=a.run_id WHERE r.assessment_id=:a'),
            {'a': case.assessment}).scalar()


# 1. happy path -------------------------------------------------------------
def test_happy_path_persists_and_returns_candidate_only(case):
    packet = synthetic_packet(case.assessment, case.revision)
    provider = FixtureProvider(valid_output())
    client = build_app(case, packet_source=source_for(case, packet), provider=provider)
    response = post(client, case)
    assert response.status_code == 200
    body = response.json()
    assert body['finding_authority'] == 'CANDIDATE_ONLY'
    assert body['status_contract'] == 'UNRECONCILED_PROPOSAL'
    assert all(value is False for key, value in body.items()
               if key in {'scientific_acceptance', 'owner_authorization',
                          'publication_authorized', 'fielding_authorized',
                          'report_release_authorized'})
    assert body['review_outcome'] == 'reviewed'
    assert body['execution_outcome'] == 'returned'
    assert body['validation_status'] == 'valid'
    assert len(body['findings']) == 1
    assert provider.calls == 1

    row = result_row(case, body['result_id'])
    assert row['review_outcome'] == 'reviewed'
    assert row['execution_outcome'] == 'returned'
    assert row['validation_status'] == 'valid'
    assert row['finding_count'] == len(body['findings'])
    # Current model path writes the validated payload but does not bind an
    # individually reviewable finding row; make that lifecycle gap observable.
    with case.admin.connect() as conn:
        linked = conn.execute(text('SELECT count(*) FROM project1_ai.bdj_result_findings '
                                   'WHERE result_id=:result_id'),
                              {'result_id': UUID(body['result_id'])}).scalar_one()
    assert linked == 0


# 2. invalid model output ---------------------------------------------------
def test_invalid_model_output_is_rejected_without_findings(case):
    packet = synthetic_packet(case.assessment, case.revision)
    provider = FixtureProvider(invalid_output())
    client = build_app(case, packet_source=source_for(case, packet), provider=provider)
    body = post(client, case).json()
    assert body['review_outcome'] == 'rejected'
    assert body['validation_status'] == 'invalid'
    assert body['findings'] == []
    row = result_row(case, body['result_id'])
    assert row['review_outcome'] == 'rejected'
    assert row['validation_status'] == 'invalid'
    assert row['payload'] is None
    assert row['finding_count'] == 0


# 3. transport failure ------------------------------------------------------
def test_transport_failure_persists_unknown_outcome_and_holds(case):
    packet = synthetic_packet(case.assessment, case.revision)
    provider = FixtureProvider(error=WorkflowHeld('E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN'))
    client = build_app(case, packet_source=source_for(case, packet), provider=provider)
    response = post(client, case)
    assert response.status_code == 503
    assert response.json()['detail']['code'] == 'E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN'
    with case.admin.connect() as conn:
        row = conn.execute(text(
            'SELECT review_outcome, execution_outcome, validation_status, finding_count'
            ' FROM project1_ai.bdj_results b JOIN project1_ai.runs r ON r.id=b.run_id'
            ' WHERE r.assessment_id=:a'), {'a': case.assessment}).mappings().one()
    assert row['execution_outcome'] == 'unknown_outcome'
    assert row['review_outcome'] is None
    assert row['validation_status'] == 'not_validated'
    assert row['finding_count'] == 0


# 4. stale ------------------------------------------------------------------
def test_stale_review_drops_findings(case):
    packet = synthetic_packet(case.assessment, case.revision)
    provider = FixtureProvider(valid_output())
    calls = {'n': 0}

    def changing_source(session, user, assessment_id, revision):
        calls['n'] += 1
        if calls['n'] == 1:
            return packet
        return {**packet, 'source_fingerprint': '9' * 64}

    client = build_app(case, packet_source=changing_source, provider=provider)
    body = post(client, case).json()
    assert body['review_outcome'] == 'stale'
    assert body['findings'] == []
    row = result_row(case, body['result_id'])
    assert row['review_outcome'] == 'stale'
    assert row['finding_count'] == 0


# 5. real-data refusal ------------------------------------------------------
def test_real_data_is_refused_before_a_run_or_dispatch(case):
    packet = synthetic_packet(case.assessment, case.revision, data_class='REAL_PERSONAL')
    provider = FixtureProvider(valid_output())
    client = build_app(case, packet_source=source_for(case, packet), provider=provider)
    response = post(client, case)
    assert response.status_code == 409
    assert response.json()['detail']['code'] == 'DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'
    assert provider.calls == 0
    assert run_count(case) == 0


# 6. idempotency ------------------------------------------------------------
def test_second_identical_call_does_not_dispatch(case):
    packet = synthetic_packet(case.assessment, case.revision)
    provider = FixtureProvider(valid_output())
    client = build_app(case, packet_source=source_for(case, packet), provider=provider)
    first = post(client, case)
    second = post(client, case)
    assert first.status_code == 200
    assert second.status_code == 409
    assert second.json()['detail']['code'] == 'MODEL_STAGE_ALREADY_RESERVED'
    assert provider.calls == 1
    assert attempt_count(case) == 1


# 7. revision mismatch ------------------------------------------------------
def test_conflicting_run_revision_is_refused_without_dispatch(case):
    packet = synthetic_packet(case.assessment, case.revision + 1)
    policy = effective_policy_fingerprint()
    # Manufacture the only state the guard exists for: a row whose stored
    # revision disagrees with the work identity it was inserted under.
    with case.admin.begin() as conn:
        conn.execute(text(
            'INSERT INTO project1_ai.runs(id,owner_user_id,assessment_id,'
            'assessment_revision,source_fingerprint,policy_fingerprint,work_identity)'
            ' VALUES (:r,:o,:a,:rev,:s,:p,:w)'),
            {'r': uuid4(), 'o': case.actor, 'a': case.assessment,
             'rev': case.revision, 's': 'c' * 64, 'p': policy,
             'w': work_identity_for(case.assessment, case.revision + 1, policy)})
    provider = FixtureProvider(valid_output())
    client = build_app(case, packet_source=source_for(case, packet), provider=provider)
    response = post(client, case, revision=case.revision + 1)
    assert response.status_code == 409
    assert response.json()['detail']['code'] == 'WORKFLOW_RUN_REVISION_MISMATCH'
    assert provider.calls == 0
    assert attempt_count(case) == 0


def test_conflicting_run_fingerprint_is_refused_without_dispatch(case):
    packet = synthetic_packet(case.assessment, case.revision)
    policy = effective_policy_fingerprint()
    with case.admin.begin() as conn:
        conn.execute(text(
            'INSERT INTO project1_ai.runs(id,owner_user_id,assessment_id,'
            'assessment_revision,source_fingerprint,policy_fingerprint,work_identity)'
            ' VALUES (:r,:o,:a,:rev,:s,:p,:w)'),
            {'r': uuid4(), 'o': case.actor, 'a': case.assessment,
             'rev': case.revision, 's': 'c' * 64, 'p': policy,
             'w': work_identity_for(case.assessment, case.revision, policy)})
    provider = FixtureProvider(valid_output())
    client = build_app(case, packet_source=source_for(case, packet), provider=provider)
    response = post(client, case)
    assert response.status_code == 409
    assert response.json()['detail']['code'] == 'WORKFLOW_RUN_SOURCE_MISMATCH'
    assert provider.calls == 0
    assert attempt_count(case) == 0


# 8. owner isolation --------------------------------------------------------
def test_other_owner_cannot_reach_the_assessment(case):
    packet = synthetic_packet(case.assessment, case.revision)
    provider = FixtureProvider(valid_output())
    client = build_app(
        case, packet_source=source_for(case, packet, {case.assessment: uuid4()}),
        provider=provider)
    response = post(client, case)
    assert response.status_code == 404
    assert provider.calls == 0
    assert run_count(case) == 0


# 9. flag off ---------------------------------------------------------------
def test_flag_off_returns_model_assisted_not_configured(case, monkeypatch):
    monkeypatch.setattr(settings, 'tokenharbor_enabled', False)
    packet = synthetic_packet(case.assessment, case.revision)
    provider = FixtureProvider(valid_output())
    client = build_app(case, packet_source=source_for(case, packet), provider=provider)
    response = post(client, case)
    assert response.status_code == 503
    assert response.json()['detail']['code'] == 'MODEL_ASSISTED_NOT_CONFIGURED'
    assert provider.calls == 0
    assert run_count(case) == 0


# 10. no leaked content -----------------------------------------------------
def test_response_and_error_bodies_carry_no_prompt_or_answer_text(case):
    packet = synthetic_packet(case.assessment, case.revision)
    provider = FixtureProvider(valid_output())
    client = build_app(case, packet_source=source_for(case, packet), provider=provider)
    happy = json.dumps(post(client, case).json())
    for secret in (PROMPT_TEXT, ANSWER_TAKEAWAY, ANSWER_DINE, 'source_refs', 'quote'):
        assert secret not in happy

    failing = FixtureProvider(error=WorkflowHeld('E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN'))
    error_client = build_app(case, packet_source=source_for(case, packet),
                             provider=failing)
    error = json.dumps(post(error_client, case).json())
    for secret in (PROMPT_TEXT, ANSWER_TAKEAWAY, ANSWER_DINE, 'Traceback'):
        assert secret not in error


# 11. disclosure ordering ---------------------------------------------------
# project1_ai.runs is append-only: a refusal that happens after ensure_run()
# leaves an orphan row no later code can delete. Both a pre-provisioning code and
# a code that used to fire at dispatch must leave zero runs and zero attempts.
def test_real_data_refusal_creates_no_run_and_no_attempt(case):
    packet = synthetic_packet(case.assessment, case.revision,
                              data_class='REAL_PERSONAL')
    provider = FixtureProvider(valid_output())
    client = build_app(case, packet_source=source_for(case, packet), provider=provider)
    response = post(client, case)
    assert response.status_code == 409
    assert response.json()['detail']['code'] == 'DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'
    assert run_count(case) == 0
    assert attempt_count(case) == 0
    assert provider.calls == 0


def test_dispatch_time_disclosure_code_also_creates_no_run(case):
    """DISCLOSURE_SOURCE_CLASS_INVALID used to fire inside require_current().

    require_current() runs during dispatch, which is after ensure_run(), so this
    code used to leave an orphan run row. The preflight now decides it first.

    (DISCLOSURE_RECEIPT_REQUIRED cannot be reached through the route: the route's
    own configuration gate raises MODEL_ASSISTED_NOT_CONFIGURED before the
    predicate runs, which is also a pre-provisioning refusal. The unit test
    test_disclosure_contract.py covers the receipt code directly.)
    """
    content = {k: v for k, v in synthetic_packet(case.assessment, case.revision).items()
               if k != 'source_fingerprint'}
    content['schema_version'] = 'project1-m2-projection/2-final'
    packet = {**content, 'source_fingerprint': digest(content)}
    provider = FixtureProvider(valid_output())
    client = build_app(case, packet_source=source_for(case, packet), provider=provider)
    response = post(client, case)
    body = response.json()
    assert body['detail']['code'] == 'DISCLOSURE_SOURCE_CLASS_INVALID', body
    assert response.status_code == 409, body
    assert run_count(case) == 0
    assert attempt_count(case) == 0
    assert provider.calls == 0


# 13. Activity History V1.1 readback ---------------------------------------
def conflict_output():
    """A finding that passes validation, so a real quote reaches the payload.

    SERVICE_FORMAT_EXPLICIT_CONFLICT is an IMPLEMENTED_CANDIDATE rule over
    M2-04 + M2-05 (bdj_candidate_rules.RULE_CATALOGUE). The packet declares a
    takeaway-only narrative and a dine-in selection, so the conflict is real.
    """
    return {'issues': [{
        'rule_id': 'SERVICE_FORMAT_EXPLICIT_CONFLICT',
        'kind': 'SOURCE_CONFLICT',
        'source_refs': [
            {'item_key': 'M2-04', 'answer_revision_id': 'answer-04-r1',
             'item_version_id': 'item-04-v1', 'quote': ANSWER_TAKEAWAY},
            {'item_key': 'M2-05', 'answer_revision_id': 'answer-05-r1',
             'item_version_id': 'item-05-v1', 'quote': ANSWER_DINE}],
        'observed_condition': 'Takeaway-only narrative alongside a dine-in selection.',
        'counterargument': 'The two declarations may describe different formats.',
        'justification': 'Both declarations are current and quoted exactly.',
        'next_action': 'Confirm which service format applies.'}],
        'overall_note': 'One conflict candidate.'}


def history(case, actor=None, assessment=None):
    client = build_app(case, packet_source=source_for(case, {}),
                       provider=FixtureProvider(valid_output()))
    if actor is not None:
        client.app.dependency_overrides[api.require_entrepreneur] = (
            lambda: SimpleNamespace(user_id=actor))
    return client.get(ENDPOINT_PATH.format(assessment=assessment or case.assessment)
                      .replace('/business-understanding/model-assisted', '/results'))


def test_history_returns_the_persisted_result_with_candidate_authority(case):
    packet = synthetic_packet(case.assessment, case.revision)
    client = build_app(case, packet_source=source_for(case, packet),
                       provider=FixtureProvider(conflict_output()))
    posted = post(client, case)
    assert posted.status_code == 200, posted.json()
    result_id = posted.json()['result_id']

    response = history(case)
    assert response.status_code == 200
    body = response.json()
    assert response.headers['Cache-Control'] == 'no-store'
    assert body['result_count'] == 1
    row = body['results'][0]
    assert row['result_id'] == result_id
    assert row['review_outcome'] == 'reviewed'
    assert row['execution_outcome'] == 'returned'
    assert row['validation_status'] == 'valid'
    assert row['finding_authority'] == 'CANDIDATE_ONLY'
    assert row['finding_count'] == 1
    assert body['status_contract'] == 'UNRECONCILED_PROPOSAL'
    assert all(value is False for key, value in body.items()
               if key in {'scientific_acceptance', 'owner_authorization',
                          'publication_authorized', 'fielding_authorized',
                          'report_release_authorized'})


def test_history_projection_excludes_the_quote_sentinel(case):
    """The entrepreneur's answer text must appear neither in the response nor at rest.

    The finding carries two exact quotes (M2-04 and M2-05). Two separate
    guarantees are asserted here, and the second is the stronger one:

    1. the History response contains neither quote, nor the payload column;
    2. the stored ``result_payload`` does not contain them either.

    The second changed on 2026-11-17. The payload previously held the verbatim
    evidence span, and this test asserted its presence to prove the projection
    was doing the excluding. ``redact_payload()`` now strips ``quote`` before the
    INSERT, so answer text is no longer retained in plaintext in
    ``project1_ai.bdj_results`` at all. The evidence span remains recoverable
    from the encrypted ``bdj_raw_responses`` row under audit access, and the
    pointer rows in ``bdj_result_sources`` are unchanged.
    """
    packet = synthetic_packet(case.assessment, case.revision)
    client = build_app(case, packet_source=source_for(case, packet),
                       provider=FixtureProvider(conflict_output()))
    assert post(client, case).status_code == 200

    body = history(case).json()
    serialised = json.dumps(body)
    assert ANSWER_TAKEAWAY not in serialised
    assert ANSWER_DINE not in serialised
    assert 'result_payload' not in serialised
    assert 'bdj_raw_responses' not in serialised

    row = body['results'][0]
    assert len(row['references']) == 2
    for reference in row['references']:
        assert set(reference) == {'item_key', 'answer_revision_id', 'item_version_id'}

    # At rest the quote is gone too -- the exclusion is not merely a projection.
    with case.admin.connect() as conn:
        stored = conn.execute(text(
            'SELECT result_payload::text FROM project1_ai.bdj_results'
            ' WHERE result_id=:id'), {'id': row['result_id']}).scalar()
        pointers = conn.execute(text(
            'SELECT count(*) FROM project1_ai.bdj_result_sources'
            ' WHERE result_id=:id'), {'id': row['result_id']}).scalar()
    assert stored is not None, 'a reviewed result must still carry its structured payload'
    assert ANSWER_TAKEAWAY not in stored
    assert ANSWER_DINE not in stored
    assert '"quote"' not in stored
    # Sealed at rest: the payload is an envelope, so even the finding text is not
    # readable from the column. The finding is still recoverable through the
    # authorised read path, which is what the assertions above and below prove.
    assert '__payload_envelope__' in stored and '"v1"' in stored
    assert 'SERVICE_FORMAT_EXPLICIT_CONFLICT' not in stored
    assert pointers == 2, 'the source pointer rows must be untouched by redaction'
    # Substance survives the sealing: the finding is intact on readback.
    assert any(f.get('rule_id') == 'SERVICE_FORMAT_EXPLICIT_CONFLICT'
               for f in row['findings']), 'the sealed payload must still decrypt to the finding'


def test_history_is_owner_scoped(case):
    packet = synthetic_packet(case.assessment, case.revision)
    client = build_app(case, packet_source=source_for(case, packet),
                       provider=FixtureProvider(conflict_output()))
    assert post(client, case).status_code == 200

    intruder = uuid4()
    with case.admin.begin() as conn:
        conn.execute(text(
            "INSERT INTO public.users(user_id,email,role,account_status,email_verified,"
            "created_at,updated_at) VALUES (:id,:email,'entrepreneur','active',true,"
            "now(),now())"), {'id': intruder,
                              'email': f'cp04a.intruder.{intruder.hex}@example.test'})
    body = history(case, actor=intruder).json()
    assert body['result_count'] == 0
    assert body['results'] == []


def test_history_reads_the_same_row_twice_across_clients(case):
    """A fresh client is a fresh process for this purpose: the row is durable."""
    packet = synthetic_packet(case.assessment, case.revision)
    client = build_app(case, packet_source=source_for(case, packet),
                       provider=FixtureProvider(conflict_output()))
    result_id = post(client, case).json()['result_id']
    first = history(case).json()
    second = history(case).json()
    assert [r['result_id'] for r in first['results']] == [result_id]
    assert [r['result_id'] for r in second['results']] == [result_id]
