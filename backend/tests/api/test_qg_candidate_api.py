"""CP-04: the QG candidate engine is reachable over HTTP.

These tests drive the routes with ``TestClient`` and assert the HTTP contract.
They do not call ``DirectQgService`` or ``QgCandidateService`` to produce a
result, because "the engine works" was already proved elsewhere — the claim
here is that a route reaches it, that the result is persisted, and that each
refusal has the documented status.

What is real and what is a double:

* real — the routes, the dependency wiring, ``ConfirmationService``, the M2
  repository and the database. Candidate versions are inserted into
  ``m2_review_question_versions`` and read back through the API.
* double — the persisted-business-context port (no BCB construction is needed
  to test routing, and the packet it must return is a hash-verified contract
  this test can state exactly) and the model runner (no provider call is made).
* patched — ``budget.reserve``, so the suite neither consumes the authorized
  attempt ledger nor depends on how many slots an earlier run spent. The
  exhaustion test re-patches it to raise the real ``BudgetExhausted``.

Every row is written inside one transaction per test that is rolled back at
teardown. Deferred ``refresh_workflow`` triggers fire on COMMIT and therefore
never run. The clone ``project1_workflow_tests`` is the only database used;
if it is unreachable the module SKIPS with an explicit reason.
"""
import copy
import json
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session

from sitewise.api.v1 import m2 as m2_api
from sitewise.api.v1 import qg_candidate as api
from sitewise.core.config import settings
from sitewise.core.exceptions import SiteWiseError
from sitewise.dependencies import (
    get_active_user, get_confirmation_service, get_qg_candidate_service,
    require_entrepreneur,
)
from sitewise.main import auth_error_handler, workflow_held_handler
from sitewise.project1 import budget
from sitewise.project1.budget import BudgetExhausted
from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.measurement_policy import (
    QJ_INVARIANTS_POLICY, MeasurementAuthority,
)
from sitewise.repositories.m2_repository import SqlModelM2Repository
from sitewise.services.confirmation_service import ConfirmationService
from sitewise.services.qg_candidate_service import QgCandidateService

CLONE = 'project1_workflow_tests'
REVISION = 2
DIGEST = 'a' * 64
TEXT = ('Would eligible customers find RM13 acceptable for a 12 oz takeaway '
        'iced latte?')
QUESTION = 'Would you find a 12 oz takeaway iced latte at RM13 acceptable?'


def _clone_engine():
    url = make_url(settings.database_url).set(database=CLONE)
    engine = create_engine(url, hide_parameters=True)
    with engine.connect() as connection:
        name = connection.execute(text('select current_database()')).scalar_one()
        if name != CLONE:
            engine.dispose()
            raise RuntimeError(f'resolved database is {name}, not {CLONE}')
    return engine


try:
    ENGINE = _clone_engine()
except Exception as exc:  # pragma: no cover - environment dependent
    pytest.skip(f'clone {CLONE} not reachable ({type(exc).__name__}: {exc}); '
                'the QG HTTP surface is unverified here', allow_module_level=True)


@pytest.fixture(scope='module', autouse=True)
def _engine_lifetime():
    yield
    ENGINE.dispose()


@pytest.fixture
def connection():
    """One transaction per test, always rolled back."""
    connection = ENGINE.connect()
    transaction = connection.begin()
    try:
        yield connection
    finally:
        transaction.rollback()
        connection.close()


@pytest.fixture(autouse=True)
def budget_guard(monkeypatch):
    """Never touch the authorized attempt ledger from a route test."""
    reserved = []

    def reserve(path=None, scenario='', *, limit=None):
        reserved.append(scenario)
        return len(reserved)

    monkeypatch.setattr(budget, 'reserve', reserve)
    return reserved


def draft(**overrides):
    value = {
        'decision': 'DRAFT',
        'question': QUESTION,
        'justification': 'One neutral question about the confirmed offer.',
        'construct_interpretation': 'Stated acceptability of the confirmed offer.',
        'response_options': ['Acceptable', 'Not acceptable', "Don't know"],
        'response_codes': ['ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW'],
        'routing': {'ACCEPTABLE': 'END', 'NOT_ACCEPTABLE': 'END', 'DONT_KNOW': 'END'},
        'reference_period': 'At the moment the respondent views the offer.',
        'measurement_description': 'Share describing the offer as acceptable.',
        'denominator_specification': ('ACCEPTABLE and NOT_ACCEPTABLE respondents; '
                                      'DONT_KNOW reported separately.'),
        'limitations': 'Stated acceptability only. Not a purchase estimate.',
        'unresolved_assumptions': [],
        'missing_business_facts': [],
        'used_confirmed_facts': ['RM13', '12'],
    }
    value.update(overrides)
    return value


def abstention():
    return {'decision': 'ABSTAIN_NEEDS_REVIEW', 'question': '',
            'justification': 'No price is confirmed.',
            'missing_business_facts': ['PRICE'], 'used_confirmed_facts': []}


def packet(world, *, confirmation_id=None, revision=None, exact_text=TEXT):
    """A hash-verified BCB packet whose identity matches the persisted records."""
    value = {
        'schema_version': 'business-context-package/1.1',
        'assessment_id': str(world['assessment']),
        'confirmation': {
            'status': 'CURRENT_CONFIRMED',
            'id': str(confirmation_id or world['confirmation']),
            'revision': REVISION if revision is None else revision},
        'confirmed_uncertainty': {
            'id': str(world['objective']),
            'confirmation_id': str(confirmation_id or world['confirmation']),
            'actor_user_id': str(world['owner']),
            'exact_text': exact_text},
        'geography': None,
        'permissions': {'qj_execution': False},
        'm2_answers': [{'answer_revision_id': 'SYN-A1', 'item_key': 'M2-04',
                        'value': 'takeaway only'}],
        'supporting_sources': [],
    }
    value['packet_hash'] = digest(value)
    return value


class Contexts:
    """Stands in for PersistedBusinessContextService.retrieve."""

    def __init__(self, value):
        self.value = value
        self.calls = 0

    def retrieve(self, assessment_id, context_id, actor):
        self.calls += 1
        return {'packet': copy.deepcopy(self.value),
                'qj_execution_authorized': False}


class Runner:
    """A fake model runner that records the governed stage it was asked for."""

    def __init__(self, *outputs):
        self.outputs = list(outputs) or [draft()]
        self.stages = []
        self.calls = 0

    def __call__(self, stage, payload, output_type):
        self.stages.append(stage)
        self.calls += 1
        return copy.deepcopy(self.outputs[min(self.calls - 1, len(self.outputs) - 1)])


@pytest.fixture
def world(connection):
    owner, reviewer = uuid4(), uuid4()
    for user_id in (owner, reviewer):
        connection.execute(text("""
            INSERT INTO public.users
                (user_id, email, role, account_status, email_verified, created_at, updated_at)
            VALUES (:id, :email, 'entrepreneur', 'active', true, now(), now())
        """), {'id': user_id, 'email': f'cp04-{user_id.hex[:12]}@example.test'})

    instrument = uuid4()
    connection.execute(text("""
        INSERT INTO public.m2_instrument_versions
            (id, code, version_tag, approval_state, schema_digest)
        VALUES (:id, :code, 'CP04-FIXTURE', 'AUTHORIZED', :digest)
    """), {'id': instrument, 'code': f'CP04-{instrument.hex[:8]}', 'digest': DIGEST})

    assessment = uuid4()
    connection.execute(text("""
        INSERT INTO public.m2_assessments
            (id, owner_user_id, instrument_id, revision, confirmed_revision)
        VALUES (:id, :owner, :instrument, :revision, :revision)
    """), {'id': assessment, 'owner': owner, 'instrument': instrument,
           'revision': REVISION})

    confirmation = uuid4()
    connection.execute(text("""
        INSERT INTO public.m2_confirmation_snapshots
            (id, assessment_id, assessment_revision, actor_user_id,
             snapshot_json, snapshot_digest, acknowledged_issue_ids)
        VALUES (:id, :assessment, :revision, :owner, '{}', :digest, '[]')
    """), {'id': confirmation, 'assessment': assessment, 'revision': REVISION,
           'owner': owner, 'digest': DIGEST})

    objective = uuid4()
    connection.execute(text("""
        INSERT INTO public.m2_confirmed_uncertainties
            (id, confirmation_id, actor_user_id, exact_text)
        VALUES (:id, :confirmation, :owner, :text)
    """), {'id': objective, 'confirmation': confirmation, 'owner': owner,
           'text': TEXT})
    connection.execute(text("""
        INSERT INTO public.m2_research_objective_sources (objective_id, provenance)
        VALUES (:id, CAST(:provenance AS jsonb))
    """), {'id': objective, 'provenance': json.dumps({
        'confirmation_id': str(confirmation), 'assessment_id': str(assessment),
        'assessment_revision': REVISION, 'snapshot_digest': DIGEST})})

    return {'connection': connection, 'owner': owner, 'reviewer': reviewer,
            'assessment': assessment, 'confirmation': confirmation,
            'objective': objective, 'context': uuid4()}


def build_app(world, *, runner, contexts=None, confirmation=None, fixed_policy_resolver=None):
    app = FastAPI()
    app.include_router(api.router, prefix='/m2')
    # The owner-review decision route already exists in m2.py; it is included so
    # the revision test proves the decision travels over HTTP rather than by
    # calling the repository directly.
    app.include_router(m2_api.router, prefix='/m2')
    app.add_exception_handler(SiteWiseError, auth_error_handler)
    app.add_exception_handler(WorkflowHeld, workflow_held_handler)

    session = Session(bind=world['connection'])
    service = QgCandidateService(
        contexts=contexts or Contexts(packet(world)),
        confirmation=confirmation or ConfirmationService(SqlModelM2Repository(session)),
        authority=MeasurementAuthority(QJ_INVARIANTS_POLICY,
                                       lab_scope_record='CP04-HTTP-TEST'),
        runner=runner,
        enabled=True, fixed_policy_resolver=fixed_policy_resolver)
    app.dependency_overrides[get_qg_candidate_service] = lambda: service
    # The existing owner-review route takes the same ConfirmationService, so the
    # decision is recorded through the identical repository and session.
    app.dependency_overrides[get_confirmation_service] = lambda: service.confirmation
    app.dependency_overrides[require_entrepreneur] = lambda: SimpleNamespace(
        user_id=world['owner'], role='entrepreneur')
    app.dependency_overrides[get_active_user] = lambda: SimpleNamespace(
        user_id=world['reviewer'], role='entrepreneur')
    return TestClient(app), service


def prepare(client, world, *, revision=REVISION, context=None):
    return client.post(
        f"/m2/research-objectives/{world['objective']}/qg-candidate",
        json={'expected_revision': revision,
              'context_id': str(context or world['context'])})


def history(client, world, revision=REVISION):
    return client.get(
        f"/m2/research-objectives/{world['objective']}/research-questions",
        params={'expected_revision': revision})


def count_versions(world):
    return world['connection'].execute(text("""
        SELECT count(*) FROM public.m2_review_question_versions WHERE objective_id=:id
    """), {'id': world['objective']}).scalar_one()


def assign(world, candidate):
    world['connection'].execute(text("""
        INSERT INTO public.m2_candidate_review_assignments
            (candidate_id, reviewer_id, authority_reference)
        VALUES (:candidate, :reviewer, 'CP04-TEST-REVIEWER')
    """), {'candidate': candidate, 'reviewer': world['reviewer']})


# 1. prepare ---------------------------------------------------------------
def test_fixed_option_candidate_http_persistence_with_isolated_policy(world):
    """Injected test-only authority and fake model; never enables fielding."""
    value = draft(fixed_measurement={
        'contract_version': 'P1-QG-FIXED-OPTION-1.0',
        'response_format': 'SINGLE_CHOICE', 'construct': 'Stated acceptability',
        'population': 'Synthetic eligible respondents',
        'options': [
            {'code': 'ACCEPTABLE', 'label': 'Acceptable', 'order': 0},
            {'code': 'NOT_ACCEPTABLE', 'label': 'Not acceptable', 'order': 1},
            {'code': 'DONT_KNOW', 'label': "Don't know", 'order': 2},
        ],
        'min_selections': 1, 'max_selections': 1,
        'interpretation': 'Proposed stated acceptability',
        'limitations': 'Synthetic fixture only; not an observed response.',
    })
    def policy(assessment, context, actor, objective, source):
        return {'policy_version': 'SYNTHETIC-TEST-ONLY',
                'assessment_id': str(assessment), 'context_id': str(context),
                'owner_id': str(actor.user_id), 'objective_approved': True,
                'authority_reference': 'ISOLATED-SYNTHETIC-TEST-ONLY',
                'objective_version': objective['objective_id'],
                'objective_id': objective['objective_id'],
                'assessment_revision': source['confirmation']['revision'],
                'context_hash': source['packet_hash'],
                'approved_population': 'Synthetic eligible respondents',
                'supported_formats': ['SINGLE_CHOICE'], 'period_required': False}
    runner = Runner(value)
    client, _ = build_app(world, runner=runner, fixed_policy_resolver=policy)
    response = prepare(client, world)
    assert response.status_code == 200, response.json()
    body = response.json()
    assert body['status'] == 'VALIDATED_OUTPUT'
    assert body['candidate']['fixed_measurement']['response_format'] == 'SINGLE_CHOICE'
    assert body['field_authority']['flutter_compatibility'] == 'NOT_VERIFIED'
    assert body['fielding_authorized'] is False
    assert body['admission']['semantic_source_review_required'] is True
    assert count_versions(world) == 1
    read = client.get('/m2/research-questions/' + body['version'])
    assert read.status_code == 200
    assert read.json()['objective_id'] == str(world['objective'])
    assert runner.calls == 1


@pytest.mark.parametrize(('field', 'code'), [
    ('assessment', 'QG_CONTEXT_ASSESSMENT_MISMATCH'),
    ('objective', 'QG_CONTEXT_OBJECTIVE_MISMATCH'),
    ('confirmation', 'QG_CONTEXT_CONFIRMATION_MISMATCH'),
])
def test_identical_objective_text_cannot_substitute_other_source_identity(world, field, code):
    value = packet(world)
    if field == 'assessment':
        value['assessment_id'] = str(uuid4())
    elif field == 'objective':
        value['confirmed_uncertainty']['id'] = str(uuid4())
    else:
        value['confirmed_uncertainty']['confirmation_id'] = str(uuid4())
    value['packet_hash'] = digest({k: v for k, v in value.items() if k != 'packet_hash'})
    runner = Runner(draft())
    client, _ = build_app(world, runner=runner, contexts=Contexts(value))
    before = count_versions(world)
    response = prepare(client, world)
    assert response.status_code == 409
    assert response.json()['detail']['code'] == code
    assert count_versions(world) == before
    assert runner.calls == 0


def test_fixed_option_hold_returns_503_before_runner_or_candidate_write(world):
    runner = Runner(draft())
    client, _ = build_app(world, runner=runner)
    before = count_versions(world)
    response = prepare(client, world)
    assert response.status_code == 503
    assert response.json()['detail']['code'] == 'QG_FIXED_OPTION_ADMISSION_UNAVAILABLE'
    assert count_versions(world) == before
    assert not runner.calls


def test_prepare_returns_a_candidate_version_and_field_authority(world):
    client, _ = build_app(world, runner=Runner(draft()))
    response = prepare(client, world)
    body = response.json()
    assert response.status_code == 200, body
    assert response.headers['Cache-Control'] == 'no-store'

    assert body['status'] == 'VALIDATED_OUTPUT'
    assert UUID(body['version'])
    assert body['candidate']['question'] == QUESTION
    assert body['candidate_authority'] == 'ENTREPRENEUR_REVIEW_ONLY'
    assert body['field_authority']['scientifically_adopted'] is False
    assert body['field_authority']['fielding_authorized'] is False
    for flag in ('scientific_acceptance', 'owner_authorization',
                 'publication_authorized', 'fielding_authorized',
                 'report_release_authorized'):
        assert body[flag] is False
    assert len(body['attempts']) == 1
    assert body['composition']['qj_executed'] is False
    assert body['missing_business_facts'] == []
    # The confirmed source text is not echoed back on this route.
    assert TEXT not in json.dumps(body)

    stored = world['connection'].execute(text("""
        SELECT question, options, source_receipt, supersedes
        FROM public.m2_review_question_versions WHERE id=:id
    """), {'id': UUID(body['version'])}).mappings().one()
    assert stored['question'] == QUESTION
    assert stored['supersedes'] is None
    assert [(o['code'], o['label']) for o in stored['options']] == [
        ('ACCEPTABLE', 'Acceptable'), ('NOT_ACCEPTABLE', 'Not acceptable'),
        ('DONT_KNOW', "Don't know")]
    assert all(o['eligible'] is True for o in stored['options'])
    receipt = json.loads(stored['source_receipt'])
    assert receipt['candidate']['question'] == QUESTION
    assert receipt['candidate']['source_version'] == str(world['objective'])


# 2. QJ is never invoked ---------------------------------------------------
def test_only_the_qg_stage_is_dispatched_even_across_a_retry(world):
    runner = Runner(draft(question='Would you find a 12 oz latte at RM12 acceptable?'),
                    draft())
    client, _ = build_app(world, runner=runner)
    body = prepare(client, world).json()

    assert body['status'] == 'VALIDATED_OUTPUT'
    assert len(body['attempts']) == 2
    assert body['attempts'][0]['code'] == 'QG_UNSOURCED_AMOUNT'
    assert runner.stages == ['QG', 'QG']
    assert 'QJ' not in runner.stages


# 3. abstention ------------------------------------------------------------
def test_abstention_returns_200_and_persists_nothing(world):
    client, _ = build_app(world, runner=Runner(abstention()))
    response = prepare(client, world)
    body = response.json()

    assert response.status_code == 200, body
    assert body['status'] == 'VALID_ABSTENTION'
    assert body['version'] is None
    assert body['missing_business_facts'] == ['PRICE']
    assert body['candidate']['question'] == ''
    assert body['fielding_authorized'] is False
    assert count_versions(world) == 0


def test_a_model_that_never_validates_returns_503_and_persists_nothing(world):
    """Three recoverable failures exhaust the cycle; no version may be created."""
    runner = Runner(draft(question='Would you find a 12 oz latte at RM12 acceptable?'))
    client, _ = build_app(world, runner=runner)
    response = prepare(client, world)

    assert response.status_code == 503
    assert response.json()['detail']['code'] == 'QG_RETRY_EXHAUSTED'
    assert runner.calls == 3
    assert count_versions(world) == 0


# 4. stale revision --------------------------------------------------------
def test_stale_expected_revision_returns_409(world):
    runner = Runner(draft())
    client, _ = build_app(world, runner=runner)
    response = prepare(client, world, revision=REVISION - 1)

    assert response.status_code == 409
    assert response.json()['detail']['code'] == 'QG_CONTEXT_REVISION_STALE'
    assert runner.calls == 0
    assert count_versions(world) == 0


# 5. budget ----------------------------------------------------------------
def test_budget_exhaustion_returns_429(world, monkeypatch):
    def exhausted(path=None, scenario='', *, limit=None):
        raise BudgetExhausted('budget exhausted: 50/50 calls already spent')

    monkeypatch.setattr(budget, 'reserve', exhausted)
    runner = Runner(draft())
    client, _ = build_app(world, runner=runner)
    response = prepare(client, world)

    assert response.status_code == 429
    assert response.json()['detail']['code'] == 'MODEL_ATTEMPT_BUDGET_EXHAUSTED'
    assert runner.calls == 0
    assert count_versions(world) == 0


# 6. history ---------------------------------------------------------------
def test_history_returns_the_persisted_version(world):
    client, _ = build_app(world, runner=Runner(draft()))
    version = prepare(client, world).json()['version']

    response = history(client, world)
    body = response.json()
    assert response.status_code == 200, body
    assert response.headers['Cache-Control'] == 'no-store'
    assert body['version_count'] == 1
    assert body['objective'] == TEXT
    entry = body['versions'][0]
    assert entry['version'] == version
    assert entry['depth'] == 0
    assert entry['supersedes'] is None
    assert entry['status'] == 'PENDING'
    assert entry['decision'] is None
    assert entry['question'] == QUESTION
    assert body['fielding_authorized'] is False


# 7. revision without a decision ------------------------------------------
def test_revision_without_request_revision_returns_409(world):
    runner = Runner(draft())
    client, _ = build_app(world, runner=runner)
    version = prepare(client, world).json()['version']
    assert runner.calls == 1

    response = client.post(f'/m2/research-questions/{version}/revision',
                           json={'expected_revision': REVISION,
                                 'context_id': str(world['context'])})
    assert response.status_code == 409
    assert response.json()['detail']['code'] == 'QG_CANDIDATE_REVISION_NOT_REQUESTED'
    assert runner.calls == 1, 'a refused revision must not dispatch the model'
    assert count_versions(world) == 1


# 8. review decision, then revision --------------------------------------
def test_owner_review_request_revision_then_revision_persists_a_child(world):
    revised_question = 'Would you say a 12 oz takeaway iced latte at RM13 is acceptable?'
    client, _ = build_app(world, runner=Runner(draft(),
                                               draft(question=revised_question)))
    version = prepare(client, world).json()['version']
    assign(world, UUID(version))

    review = client.post(f'/m2/research-questions/{version}/owner-review',
                         json={'decision': 'REQUEST_REVISION',
                               'rationale': 'Ask about one price concept only.'})
    assert review.status_code == 201, review.json()
    assert review.json()['decision'] == 'REQUEST_REVISION'
    assert review.json()['fielding_authorized'] is False

    revised = client.post(f'/m2/research-questions/{version}/revision',
                          json={'expected_revision': REVISION,
                                'context_id': str(world['context'])})
    body = revised.json()
    assert revised.status_code == 200, body
    assert body['status'] == 'VALIDATED_OUTPUT'
    assert body['candidate']['question'] == revised_question
    child = UUID(body['version'])
    assert child != UUID(version)

    stored = world['connection'].execute(text("""
        SELECT supersedes FROM public.m2_review_question_versions WHERE id=:id
    """), {'id': child}).scalar_one()
    assert stored == UUID(version)

    inherited = world['connection'].execute(text("""
        SELECT reviewer_id FROM public.m2_candidate_review_assignments WHERE candidate_id=:id
    """), {'id': child}).scalar_one()
    assert inherited == world['reviewer']

    entries = history(client, world).json()['versions']
    assert [entry['version'] for entry in entries] == [version, str(child)]
    assert [entry['status'] for entry in entries] == ['REQUEST_REVISION', 'PENDING']
    assert entries[1]['supersedes'] == version
    assert entries[1]['depth'] == 1


# 9. revision that changes nothing -----------------------------------------
def test_a_revision_that_reproduces_the_parent_returns_409(world):
    """A version id is a receipt digest: identical output IS the parent version."""
    client, _ = build_app(world, runner=Runner(draft()))
    version = prepare(client, world).json()['version']
    assign(world, UUID(version))
    assert client.post(f'/m2/research-questions/{version}/owner-review',
                       json={'decision': 'REQUEST_REVISION',
                             'rationale': 'Regenerate.'}).status_code == 201

    response = client.post(f'/m2/research-questions/{version}/revision',
                           json={'expected_revision': REVISION,
                                 'context_id': str(world['context'])})
    assert response.status_code == 409
    assert response.json()['detail']['code'] == 'QG_CANDIDATE_REVISION_UNCHANGED'
    assert count_versions(world) == 1
    stored = world['connection'].execute(text("""
        SELECT supersedes FROM public.m2_review_question_versions WHERE id=:id
    """), {'id': UUID(version)}).scalar_one()
    assert stored is None, 'the parent must not become its own child'


# 10. read one candidate ---------------------------------------------------
def test_read_returns_the_candidate_with_its_status_and_authority(world):
    client, _ = build_app(world, runner=Runner(draft()))
    version = prepare(client, world).json()['version']

    response = client.get(f'/m2/research-questions/{version}')
    body = response.json()
    assert response.status_code == 200, body
    assert response.headers['Cache-Control'] == 'no-store'
    assert body['version'] == version
    assert body['status'] == 'PENDING'
    assert body['question'] == QUESTION
    assert body['objective_id'] == str(world['objective'])
    assert body['field_authority']['scientifically_adopted'] is False
    assert body['admission']['uncertainty_version'] == str(world['objective'])
    assert body['fielding_authorized'] is False


# 10. context integrity ----------------------------------------------------
def test_a_packet_from_another_confirmation_returns_409(world):
    other = uuid4()
    contexts = Contexts(packet(world, confirmation_id=other))
    runner = Runner(draft())
    client, _ = build_app(world, runner=runner, contexts=contexts)
    response = prepare(client, world)

    assert response.status_code == 409
    assert response.json()['detail']['code'] == 'QG_CONTEXT_CONFIRMATION_MISMATCH'
    assert runner.calls == 0
    assert count_versions(world) == 0


def test_a_packet_with_another_objective_returns_409(world):
    contexts = Contexts(packet(world, exact_text='A different research objective.'))
    runner = Runner(draft())
    client, _ = build_app(world, runner=runner, contexts=contexts)
    response = prepare(client, world)

    assert response.status_code == 409
    assert response.json()['detail']['code'] == 'QG_CONTEXT_OBJECTIVE_MISMATCH'
    assert runner.calls == 0
    assert count_versions(world) == 0


# 11. ownership ------------------------------------------------------------
def test_another_owner_cannot_read_the_candidate(world):
    client, _ = build_app(world, runner=Runner(draft()))
    version = prepare(client, world).json()['version']

    client.app.dependency_overrides[require_entrepreneur] = lambda: SimpleNamespace(
        user_id=uuid4(), role='entrepreneur')
    response = client.get(f'/m2/research-questions/{version}')
    assert response.status_code == 404
    assert response.json()['detail']['code'] == 'QG_CANDIDATE_NOT_FOUND'


# 12. V3.1: a real candidate must carry a persisted objective id ------------
def test_prepare_refuses_a_qg_input_with_no_persisted_objective(world, monkeypatch):
    """facts_from_packet may emit objective_id=None offline; never on this path."""
    from sitewise.project1.direct_qg_service import DirectQgService

    real = DirectQgService.prepare_candidate

    def without_objective(self, **kwargs):
        result = real(self, **kwargs)
        result['objective_id'] = None
        return result

    monkeypatch.setattr(DirectQgService, 'prepare_candidate', without_objective)
    client, _ = build_app(world, runner=Runner(draft()))
    response = prepare(client, world)

    assert response.status_code == 409, response.json()
    assert response.json()['detail']['code'] == 'QG_OBJECTIVE_NOT_PERSISTED'
    assert count_versions(world) == 0


def test_prepare_refuses_a_qg_input_for_a_different_objective(world, monkeypatch):
    from sitewise.project1.direct_qg_service import DirectQgService

    real = DirectQgService.prepare_candidate

    def wrong_objective(self, **kwargs):
        result = real(self, **kwargs)
        result['objective_id'] = str(uuid4())
        return result

    monkeypatch.setattr(DirectQgService, 'prepare_candidate', wrong_objective)
    client, _ = build_app(world, runner=Runner(draft()))
    response = prepare(client, world)

    assert response.status_code == 409, response.json()
    assert response.json()['detail']['code'] == 'QG_OBJECTIVE_NOT_PERSISTED'
    assert count_versions(world) == 0


def test_prepare_refuses_a_null_objective_id_before_context_resolution(world):
    from sitewise.core.exceptions import ConflictError

    _, service = build_app(world, runner=Runner(draft()))
    with pytest.raises(ConflictError) as caught:
        service.prepare(None, world['owner'], REVISION, world['context'])
    assert str(caught.value) == 'QG_OBJECTIVE_NOT_PERSISTED'
    assert count_versions(world) == 0


# 13. V3.1: a candidate is never readable at a stale confirmation revision --
def test_owner_cannot_read_their_candidate_at_a_stale_confirmation_revision(world):
    client, _ = build_app(world, runner=Runner(draft()))
    version = prepare(client, world).json()['version']
    assert client.get(f'/m2/research-questions/{version}').status_code == 200

    # Move the assessment's confirmation backwards while the candidate and its
    # confirmation snapshot still exist. candidate_version must close the read.
    world['connection'].execute(text("""
        UPDATE public.m2_assessments SET confirmed_revision = :stale WHERE id = :id
    """), {'stale': REVISION - 1, 'id': world['assessment']})

    response = client.get(f'/m2/research-questions/{version}')
    assert response.status_code == 404
    assert response.json()['detail']['code'] == 'QG_CANDIDATE_NOT_FOUND'
