"""CP-05: the third owner decision REQUEST_REVISION, end to end on a clone.

These tests run against the disposable clone ``project1_workflow_tests`` only.
They are DDL-free: the migration is applied by
``scripts/cp05_apply_candidate_review_v2.py`` and the schema it must have
produced is asserted here, so an unapplied clone fails loudly instead of
passing vacuously.

Every row is written inside one module-level transaction that is rolled back at
teardown, so the clone is left exactly as found. Deferred constraint triggers
(``refresh_workflow``) fire on COMMIT and therefore never run.

If the clone is unreachable the whole module SKIPS with an explicit reason; it
never silently passes.
"""
import json
import re
from uuid import UUID, uuid4

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import DBAPIError
from sqlalchemy.orm import Session

CLONE = 'project1_workflow_tests'
HEX64 = re.compile(r'^[0-9a-f]{64}$')
DIGEST = 'a' * 64


def _clone_engine():
    from sitewise.core.config import settings

    url = make_url(settings.database_url).set(database=CLONE)
    engine = create_engine(url, hide_parameters=True)
    with engine.connect() as connection:
        name = connection.execute(text('select current_database()')).scalar_one()
        if name != CLONE:
            engine.dispose()
            raise RuntimeError(f'resolved database is {name}, not {CLONE}')
        superuser = connection.execute(text(
            'select rolsuper from pg_roles where rolname = current_user')).scalar_one()
        if not superuser:
            engine.dispose()
            raise RuntimeError('fixture inserts need an owner/superuser session on the clone')
    return engine


try:
    ENGINE = _clone_engine()
except Exception as exc:  # pragma: no cover - environment dependent
    pytest.skip(f'clone {CLONE} not reachable ({type(exc).__name__}: {exc}); '
                'CP-05 persistence is unverified here', allow_module_level=True)


@pytest.fixture(scope='module', autouse=True)
def _engine_lifetime():
    yield
    ENGINE.dispose()


@pytest.fixture(scope='module')
def _outer():
    connection = ENGINE.connect()
    transaction = connection.begin()
    try:
        yield connection
    finally:
        transaction.rollback()
        connection.close()


@pytest.fixture
def connection(_outer):
    """Each test runs inside its own savepoint so one failure cannot poison the rest."""
    savepoint = _outer.begin_nested()
    try:
        yield _outer
    finally:
        if savepoint.is_active:
            savepoint.rollback()


def _expect_db_error(connection, statement, params=None):
    """Run a statement expected to be refused, without poisoning the transaction."""
    savepoint = connection.begin_nested()
    try:
        with pytest.raises(DBAPIError) as caught:
            connection.execute(text(statement), params or {})
    finally:
        if savepoint.is_active:
            savepoint.rollback()
    return str(caught.value)


def _insert_candidate(connection, objective_id, question='Which price matters most?'):
    version = uuid4()
    connection.execute(text("""
        INSERT INTO public.m2_review_question_versions
            (id, objective_id, source_receipt, question, options)
        VALUES (:id, :objective, :receipt, :question, CAST(:options AS jsonb))
    """), {'id': version, 'objective': objective_id, 'receipt': json.dumps({'fixture': True}),
           'question': question, 'options': json.dumps([{'code': 'A', 'label': 'Price'}])})
    return version


def test_exact_question_and_options_duplicate_is_refused_for_same_objective(connection, world, repository):
    from sitewise.core.exceptions import ConflictError
    options = [{'code': 'A', 'label': 'Price'}]
    _insert_candidate(connection, world['objective'], 'Synthetic duplicate?')
    receipt = {'candidate': {'question': 'Synthetic duplicate?', 'options': options}}
    with pytest.raises(ConflictError, match='QG_EXACT_CANDIDATE_DUPLICATE'):
        repository.persist_candidate(uuid4(), world['objective'], receipt)
    # Changed answer choices are not silently judged semantically equivalent.
    changed = {'candidate': {'question': 'Synthetic duplicate?',
                             'options': [{'code': 'B', 'label': 'Other'}]}}
    repository.persist_candidate(uuid4(), world['objective'], changed)
    # The same wording/options in a different assessment remain independent.
    other_assessment, other_confirmation, other_objective = uuid4(), uuid4(), uuid4()
    instrument = connection.scalar(text('SELECT instrument_id FROM public.m2_assessments WHERE id=:id'),
                                   {'id': world['assessment']})
    connection.execute(text('INSERT INTO public.m2_assessments '
        '(id,owner_user_id,instrument_id,revision,confirmed_revision) VALUES (:id,:owner,:instrument,0,0)'),
        {'id':other_assessment,'owner':world['owner'],'instrument':instrument})
    connection.execute(text('INSERT INTO public.m2_confirmation_snapshots '
        '(id,assessment_id,assessment_revision,actor_user_id,snapshot_json,snapshot_digest,acknowledged_issue_ids) '
        "VALUES (:id,:assessment,0,:owner,'{}',:digest,'[]')"),
        {'id':other_confirmation,'assessment':other_assessment,'owner':world['owner'],'digest':DIGEST})
    connection.execute(text('INSERT INTO public.m2_confirmed_uncertainties '
        "(id,confirmation_id,actor_user_id,exact_text) VALUES (:id,:confirmation,:owner,'Synthetic objective')"),
        {'id':other_objective,'confirmation':other_confirmation,'owner':world['owner']})
    connection.execute(text('INSERT INTO public.m2_research_objective_sources(objective_id,provenance) '
        "VALUES (:id,CAST('{}' AS jsonb))"), {'id':other_objective})
    independent_id = uuid4()
    repository.persist_candidate(independent_id, other_objective, receipt)
    assert connection.scalar(text('SELECT objective_id FROM public.m2_review_question_versions WHERE id=:id'),
                             {'id':independent_id}) == other_objective


def test_synthetic_owner_prediction_is_version_bound_and_old_version_refused(connection, world, repository):
    """Prediction is a planning value, not a customer response or release."""
    from sitewise.core.exceptions import NotFoundError
    from sitewise.services.confirmation_service import ConfirmationService
    version, successor = uuid4(), uuid4()
    options = json.dumps([{'code':'A','label':'Synthetic A','eligible':True},
                          {'code':'B','label':'Synthetic B','eligible':True}])
    insert = text('INSERT INTO public.m2_review_question_versions '
                  '(id,objective_id,source_receipt,question,options,supersedes) '
                  'VALUES (:id,:objective,:receipt,:question,CAST(:options AS jsonb),:parent)')
    connection.execute(insert, {'id':version,'objective':world['objective'],'receipt':'{}',
        'question':'SYNTHETIC ONLY?', 'options':options,'parent':None})
    service = ConfirmationService(repository)
    result = service.select_desired_option(version, world['owner'], 0, 'A')
    assert result['desired_option'] == 'A'
    assert connection.execute(text('SELECT option_code FROM public.m2_desired_options '
        'WHERE question_version=:id AND actor_id=:actor'),
        {'id':version,'actor':world['owner']}).scalar_one() == 'A'
    with pytest.raises(ValueError):
        service.select_desired_option(version, world['owner'], 0, 'NOT_AN_OPTION')
    connection.execute(insert, {'id':successor,'objective':world['objective'],'receipt':'{}',
        'question':'SYNTHETIC revised?', 'options':options,'parent':version})
    with pytest.raises(NotFoundError):
        service.select_desired_option(version, world['owner'], 0, 'B')
    assert connection.execute(text('SELECT count(*) FROM public.m2_desired_options '
        'WHERE question_version=:id'), {'id':successor}).scalar_one() == 0


def test_synthetic_prediction_http_save_reload_and_invalid_option(connection, world, repository):
    """Real HTTP handler and disposable PostgreSQL; identity is test-injected."""
    from types import SimpleNamespace
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from sitewise.api.v1 import m2
    from sitewise.dependencies import require_entrepreneur, get_confirmation_service
    from sitewise.services.confirmation_service import ConfirmationService
    version = uuid4()
    connection.execute(text('INSERT INTO public.m2_review_question_versions '
        '(id,objective_id,source_receipt,question,options) '
        'VALUES (:id,:objective,:receipt,:question,CAST(:options AS jsonb))'),
        {'id':version,'objective':world['objective'],'receipt':'{}','question':'Synthetic?',
         'options':json.dumps([{'code':'A','label':'Synthetic A','eligible':True}])})
    app = FastAPI()
    app.include_router(m2.router)
    app.dependency_overrides[require_entrepreneur] = lambda: SimpleNamespace(user_id=world['owner'])
    app.dependency_overrides[get_confirmation_service] = lambda: ConfirmationService(repository)
    client = TestClient(app)
    path = f'/research-questions/{version}'
    saved = client.put(path+'/desired-option', json={'expected_revision':0,'option_code':'A'})
    assert saved.status_code == 200
    assert saved.json()['desired_option'] == 'A'
    reloaded = client.get(path+'/entrepreneur-review', params={'expected_revision':0})
    assert reloaded.status_code == 200
    assert reloaded.json()['option_code'] == 'A'
    assert client.put(path+'/desired-option', json={'expected_revision':0,'option_code':'INVALID'}).status_code == 422
    assert connection.execute(text('SELECT option_code FROM public.m2_desired_options WHERE question_version=:id'),
                              {'id':version}).scalar_one() == 'A'


@pytest.mark.parametrize('policy_case', ['valid', 'foreign_owner', 'wrong_objective',
                                        'wrong_revision', 'wrong_hash', 'not_approved'])
def test_fixed_option_candidate_http_postgres_readback_isolated_authority(connection, world, repository, policy_case):
    """Actual route/service/repository, synthetic policy and in-process model double."""
    from types import SimpleNamespace
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from sitewise.api.v1 import qg_candidate
    from sitewise.dependencies import require_entrepreneur, get_qg_candidate_service
    from sitewise.project1.contracts import digest
    from sitewise.services.confirmation_service import ConfirmationService
    from sitewise.services.qg_candidate_service import QgCandidateService
    from sitewise.project1.contracts import WorkflowHeld
    from sitewise.main import workflow_held_handler

    confirmation = connection.scalar(text('SELECT confirmation_id FROM public.m2_confirmed_uncertainties WHERE id=:id'),
                                     {'id':world['objective']})
    packet = {'schema_version':'business-context-package/1.1', 'assessment_id':str(world['assessment']),
        'confirmation':{'status':'CURRENT_CONFIRMED','id':str(confirmation),'revision':0},
        'confirmed_uncertainty':{'id':str(world['objective']),'confirmation_id':str(confirmation),
            'actor_user_id':str(world['owner']),'exact_text':'Fixture research uncertainty.'},
        'geography':None,'permissions':{'qj_execution':False},
        'm2_answers':[{'answer_revision_id':'SYNTHETIC-A1','item_key':'M2-04','value':'Synthetic cafe'}],
        'supporting_sources':[]}
    packet['packet_hash'] = digest(packet)
    class Contexts:
        def retrieve(self, *args): return {'packet':packet, 'qj_execution_authorized':False}
    class Authority:
        measurement_policy_version = 'SYNTHETIC-ONLY'
        def resolve_version(self, source): return {'uncertainty_version':'SYNTHETIC-1'}
        def require_current(self, source, task): pass
    options = [{'code':'YES','label':'Yes','order':0},{'code':'NO','label':'No','order':1}]
    raw = {'decision':'DRAFT','question':'Would you consider the proposed cafe?',
        'justification':'Synthetic test candidate','construct_interpretation':'Stated interest',
        'response_options':['Yes','No'],'response_codes':['YES','NO'],'routing':{'YES':'END','NO':'END'},
        'reference_period':'','measurement_description':'Proposed interest',
        'denominator_specification':'YES and NO respondents','limitations':'Synthetic proposal; no observations.',
        'unresolved_assumptions':[],'missing_business_facts':[],
        'used_confirmed_facts':[str(world['objective'])],
        'fixed_measurement':{'contract_version':'P1-QG-FIXED-OPTION-1.0','response_format':'BINARY_CHOICE',
            'construct':'Interest','population':'Synthetic test population','options':options,
            'min_selections':1,'max_selections':1,'interpretation':'Proposed interest',
            'limitations':'Synthetic proposal; no observations.'}}
    calls = []
    def runner(*args): calls.append('QG'); return raw
    def policy(assessment, context, actor, objective, source):
        resolved = {'policy_version':'SYNTHETIC-ONLY', 'assessment_id':str(assessment),
            'context_id':str(context),'objective_id':objective['objective_id'],
            'owner_id':str(actor.user_id),'objective_approved':True,
            'authority_reference':'ISOLATED-SYNTHETIC-TEST-ONLY',
            'objective_version':'SYNTHETIC-1',
            'assessment_revision':0,'context_hash':source['packet_hash'],
            'approved_population':'Synthetic test population',
            'supported_formats':['BINARY_CHOICE'],'period_required':False}
        if policy_case == 'foreign_owner': resolved['owner_id'] = str(uuid4())
        if policy_case == 'wrong_objective': resolved['objective_id'] = str(uuid4())
        if policy_case == 'wrong_revision': resolved['assessment_revision'] = 1
        if policy_case == 'wrong_hash': resolved['context_hash'] = '0' * 64
        if policy_case == 'not_approved': resolved['objective_approved'] = False
        return resolved
    service = QgCandidateService(contexts=Contexts(), confirmation=ConfirmationService(repository),
        authority=Authority(), runner=runner, enabled=True, fixed_policy_resolver=policy)
    service._reserve = lambda _objective: lambda _attempt: None
    app = FastAPI()
    app.add_exception_handler(WorkflowHeld, workflow_held_handler)
    app.include_router(qg_candidate.router)
    app.dependency_overrides[require_entrepreneur] = lambda: SimpleNamespace(user_id=world['owner'],role='entrepreneur')
    app.dependency_overrides[get_qg_candidate_service] = lambda: service
    client = TestClient(app)
    before_count = connection.scalar(text('SELECT count(*) FROM public.m2_review_question_versions WHERE objective_id=:id'),
                                     {'id': world['objective']})
    response = client.post(f"/research-objectives/{world['objective']}/qg-candidate",
        json={'expected_revision':0,'context_id':str(uuid4())})
    if policy_case != 'valid':
        assert response.status_code == 503, response.text
        assert response.json()['detail']['code'] == 'QG_FIXED_POLICY_SOURCE_MISMATCH'
        assert calls == []
        assert connection.scalar(text('SELECT count(*) FROM public.m2_review_question_versions WHERE objective_id=:id'),
                                 {'id': world['objective']}) == before_count
        return
    assert response.status_code == 200, response.text
    body=response.json()
    assert body['candidate']['fixed_measurement']['response_format']=='BINARY_CHOICE'
    assert body['fielding_authorized'] is False and calls == ['QG']
    stored=connection.execute(text('SELECT objective_id,options,source_receipt FROM public.m2_review_question_versions WHERE id=:id'),
        {'id':UUID(body['version'])}).mappings().one()
    assert stored['objective_id']==world['objective']
    assert [item['code'] for item in stored['options']]==['YES','NO']
    assert packet['packet_hash'] in stored['source_receipt']
    reread=client.get('/research-questions/'+body['version'])
    assert reread.status_code==200 and reread.json()['objective_id']==str(world['objective'])
    assert reread.json()['fixed_measurement']['response_format']=='BINARY_CHOICE'
    assert reread.json()['source_fingerprint']==packet['packet_hash']


def _insert_assignment(connection, candidate_id, reviewer_id, authority='TEST-REVIEWER'):
    connection.execute(text("""
        INSERT INTO public.m2_candidate_review_assignments
            (candidate_id, reviewer_id, authority_reference)
        VALUES (:candidate, :reviewer, :authority)
    """), {'candidate': candidate_id, 'reviewer': reviewer_id, 'authority': authority})


def _insert_review(connection, candidate_id, reviewer_id, decision, rationale='Fixture decision.',
                   context_hash=DIGEST):
    connection.execute(text("""
        INSERT INTO public.m2_candidate_owner_reviews
            (candidate_id, reviewer_id, decision, rationale, context_hash)
        VALUES (:candidate, :reviewer, :decision, :rationale, :context_hash)
    """), {'candidate': candidate_id, 'reviewer': reviewer_id, 'decision': decision,
           'rationale': rationale, 'context_hash': context_hash})


@pytest.fixture
def world(connection):
    """A fresh owner/reviewer/assessment/objective/assignment chain per test."""
    owner_id, reviewer_id = uuid4(), uuid4()
    for user_id, email in ((owner_id, f'owner-{owner_id}@example.test'),
                           (reviewer_id, f'reviewer-{reviewer_id}@example.test')):
        connection.execute(text("""
            INSERT INTO public.users
                (user_id, email, role, account_status, email_verified, created_at, updated_at)
            VALUES (:id, :email, 'entrepreneur', 'active', true, now(), now())
        """), {'id': user_id, 'email': email})

    instrument_id = uuid4()
    connection.execute(text("""
        INSERT INTO public.m2_instrument_versions
            (id, code, version_tag, approval_state, schema_digest)
        VALUES (:id, :code, 'CP05-FIXTURE', 'AUTHORIZED', :digest)
    """), {'id': instrument_id, 'code': f'CP05-{instrument_id.hex[:8]}', 'digest': DIGEST})

    assessment_id = uuid4()
    connection.execute(text("""
        INSERT INTO public.m2_assessments
            (id, owner_user_id, instrument_id, revision, confirmed_revision)
        VALUES (:id, :owner, :instrument, 0, 0)
    """), {'id': assessment_id, 'owner': owner_id, 'instrument': instrument_id})

    confirmation_id = uuid4()
    connection.execute(text("""
        INSERT INTO public.m2_confirmation_snapshots
            (id, assessment_id, assessment_revision, actor_user_id,
             snapshot_json, snapshot_digest, acknowledged_issue_ids)
        VALUES (:id, :assessment, 0, :owner, '{}', :digest, '[]')
    """), {'id': confirmation_id, 'assessment': assessment_id, 'owner': owner_id,
           'digest': DIGEST})

    objective_id = uuid4()
    connection.execute(text("""
        INSERT INTO public.m2_confirmed_uncertainties
            (id, confirmation_id, actor_user_id, exact_text)
        VALUES (:id, :confirmation, :owner, 'Fixture research uncertainty.')
    """), {'id': objective_id, 'confirmation': confirmation_id, 'owner': owner_id})
    connection.execute(text("""
        INSERT INTO public.m2_research_objective_sources (objective_id, provenance)
        VALUES (:id, CAST(:provenance AS jsonb))
    """), {'id': objective_id,
           'provenance': json.dumps({'confirmation_id': str(confirmation_id),
                                     'assessment_id': str(assessment_id),
                                     'assessment_revision': 0,
                                     'snapshot_digest': DIGEST})})

    candidate_id = _insert_candidate(connection, objective_id)
    _insert_assignment(connection, candidate_id, reviewer_id)

    return {'owner': owner_id, 'reviewer': reviewer_id, 'assessment': assessment_id,
            'objective': objective_id, 'candidate': candidate_id, 'digest': DIGEST}


@pytest.fixture
def repository(connection):
    """The real adapter on the same connection; the session owns a savepoint."""
    from sitewise.repositories.m2_repository import SqlModelM2Repository

    session = Session(bind=connection)
    try:
        yield SqlModelM2Repository(session)
    finally:
        session.close()


def test_applied_schema_matches_the_migration(connection):
    definitions = dict(connection.execute(text("""
        SELECT conname, pg_get_constraintdef(oid)
        FROM pg_constraint
        WHERE conrelid = 'public.m2_candidate_owner_reviews'::regclass AND contype = 'c'
    """)).all())

    decision = definitions['m2_candidate_owner_reviews_decision_check']
    assert 'APPROVE_FOR_REVIEW' in decision
    assert 'REJECT' in decision
    assert 'REQUEST_REVISION' in decision
    assert 'm2_candidate_owner_reviews_revision_context' in definitions
    assert 'm2_candidate_owner_reviews_context_hash_format' in definitions

    column = connection.execute(text("""
        SELECT data_type, character_maximum_length, is_nullable
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'm2_candidate_owner_reviews'
          AND column_name = 'context_hash'
    """)).one_or_none()
    assert column is not None, ('clone is missing context_hash; run '
                                'scripts/cp05_apply_candidate_review_v2.py --apply')
    assert tuple(column) == ('character varying', 64, 'YES')

    assert connection.execute(text("""
        SELECT count(*) FROM pg_trigger
        WHERE tgrelid = 'public.m2_candidate_owner_reviews'::regclass
          AND tgname = 'm2_owner_review_append_only' AND NOT tgisinternal
    """)).scalar_one() == 1


def test_decision_check_accepts_all_three_decisions_and_rejects_an_unknown_one(connection, world):
    accepted = {}
    for decision in ('APPROVE_FOR_REVIEW', 'REJECT', 'REQUEST_REVISION'):
        candidate = _insert_candidate(connection, world['objective'])
        _insert_assignment(connection, candidate, world['reviewer'])
        _insert_review(connection, candidate, world['reviewer'], decision)
        accepted[decision] = candidate

    stored = connection.execute(text("""
        SELECT candidate_id, decision FROM public.m2_candidate_owner_reviews
        WHERE candidate_id = ANY(:ids)
    """), {'ids': list(accepted.values())}).all()
    assert {str(row.candidate_id): row.decision for row in stored} == {
        str(candidate): decision for decision, candidate in accepted.items()}

    unknown = _insert_candidate(connection, world['objective'])
    _insert_assignment(connection, unknown, world['reviewer'])
    message = _expect_db_error(connection, """
        INSERT INTO public.m2_candidate_owner_reviews
            (candidate_id, reviewer_id, decision, rationale, context_hash)
        VALUES (:candidate, :reviewer, 'REQUEST_REWRITE', 'Fixture.', :digest)
    """, {'candidate': unknown, 'reviewer': world['reviewer'], 'digest': DIGEST})
    assert 'm2_candidate_owner_reviews_decision_check' in message


def test_request_revision_requires_a_context_hash(connection, world):
    candidate = _insert_candidate(connection, world['objective'])
    _insert_assignment(connection, candidate, world['reviewer'])
    message = _expect_db_error(connection, """
        INSERT INTO public.m2_candidate_owner_reviews
            (candidate_id, reviewer_id, decision, rationale, context_hash)
        VALUES (:candidate, :reviewer, 'REQUEST_REVISION', 'Fixture.', NULL)
    """, {'candidate': candidate, 'reviewer': world['reviewer']})
    assert 'm2_candidate_owner_reviews_revision_context' in message


def test_context_hash_format_is_enforced(connection, world):
    candidate = _insert_candidate(connection, world['objective'])
    _insert_assignment(connection, candidate, world['reviewer'])
    for malformed in ('A' * 64, 'a' * 63, 'z' * 64):
        message = _expect_db_error(connection, """
            INSERT INTO public.m2_candidate_owner_reviews
                (candidate_id, reviewer_id, decision, rationale, context_hash)
            VALUES (:candidate, :reviewer, 'APPROVE_FOR_REVIEW', 'Fixture.', :digest)
        """, {'candidate': candidate, 'reviewer': world['reviewer'], 'digest': malformed})
        assert 'm2_candidate_owner_reviews_context_hash_format' in message


def test_repository_persists_the_context_hash_of_the_joined_snapshot(connection, world, repository):
    row = repository.record_owner_review(
        world['candidate'], world['reviewer'], 'APPROVE_FOR_REVIEW', 'Clear enough to field.')

    assert row is not None
    assert row['decision'] == 'APPROVE_FOR_REVIEW'
    assert row['context_hash'] == world['digest']
    assert HEX64.match(row['context_hash'])
    stored = connection.execute(text("""
        SELECT context_hash FROM public.m2_candidate_owner_reviews WHERE candidate_id = :id
    """), {'id': world['candidate']}).scalar_one()
    assert stored == world['digest']


@pytest.mark.parametrize('rationale', [None, '', '   '])
def test_review_default_rationale_is_persisted_by_assigned_reviewer(connection, world, repository, rationale):
    from sitewise.services.confirmation_service import ConfirmationService
    from sitewise.api.v1.m2 import CandidateReviewRequest
    body = {'decision':'REQUEST_REVISION'}
    if rationale is not None: body['rationale'] = rationale
    payload = CandidateReviewRequest(**body)
    result = ConfirmationService(repository).record_owner_review(
        world['candidate'], world['reviewer'], payload.decision, payload.rationale)
    assert result['rationale'] == 'No rationale provided by reviewer.'
    assert connection.execute(text('SELECT rationale FROM public.m2_candidate_owner_reviews WHERE candidate_id=:id'),
                              {'id':world['candidate']}).scalar_one() == 'No rationale provided by reviewer.'
    assert result['fielding_authorized'] is False


def test_request_revision_then_child_version_is_linked_and_reviewable(connection, world, repository):
    request = repository.record_owner_review(
        world['candidate'], world['reviewer'], 'REQUEST_REVISION',
        'The question mixes two price concepts; regenerate it.')
    assert request is not None
    assert request['decision'] == 'REQUEST_REVISION'
    assert HEX64.match(request['context_hash'])

    child = uuid4()
    receipt = {'context': {'fixture': True},
               'evaluation': {'fixture': True},
               'candidate': {'question': 'Which single price matters most?',
                             'options': [{'code': 'A', 'label': 'Price'}]}}
    repository.persist_candidate(child, world['objective'], receipt, supersedes=world['candidate'])

    linked = connection.execute(text("""
        SELECT supersedes FROM public.m2_review_question_versions WHERE id = :id
    """), {'id': child}).scalar_one()
    assert linked == world['candidate']

    assignment = connection.execute(text("""
        SELECT reviewer_id, authority_reference
        FROM public.m2_candidate_review_assignments WHERE candidate_id = :id
    """), {'id': child}).all()
    assert [tuple(row) for row in assignment] == [(world['reviewer'], 'TEST-REVIEWER')]

    queue = repository.assigned_candidate_reviews(world['reviewer'])
    current = {row['id'] for row in queue}
    assert child in current, 'the revision is not in the reviewer queue: the loop dead-ends'
    assert world['candidate'] not in current, 'the superseded version is still offered as current'

    follow_up = repository.record_owner_review(
        child, world['reviewer'], 'APPROVE_FOR_REVIEW', 'Now it asks one price.')
    assert follow_up is not None
    assert follow_up['candidate_id'] == child


def test_revision_of_a_parent_without_request_revision_is_refused(connection, world, repository):
    assert repository.record_owner_review(
        world['candidate'], world['reviewer'], 'APPROVE_FOR_REVIEW', 'Approved.') is not None

    receipt = {'context': {'fixture': True}, 'evaluation': {'fixture': True},
               'candidate': {'question': 'A second current version?', 'options': []}}
    with pytest.raises(ValueError, match='REQUEST_REVISION'):
        repository.persist_candidate(uuid4(), world['objective'], receipt,
                                     supersedes=world['candidate'])


def test_supersedes_allows_only_one_child_per_version(connection, world, repository):
    repository.record_owner_review(world['candidate'], world['reviewer'], 'REQUEST_REVISION',
                                   'Regenerate.')

    def receipt(question):
        return {'context': {'fixture': True}, 'evaluation': {'fixture': True},
                'candidate': {'question': question, 'options': []}}

    repository.persist_candidate(uuid4(), world['objective'], receipt('First child.'),
                                 supersedes=world['candidate'])
    message = _expect_db_error(connection, """
        INSERT INTO public.m2_review_question_versions
            (id, objective_id, source_receipt, question, options, supersedes)
        VALUES (:id, :objective, '{}', 'Second child.', '[]', :parent)
    """, {'id': uuid4(), 'objective': world['objective'], 'parent': world['candidate']})
    assert 'm2_review_question_versions_supersedes_key' in message


def test_history_stays_append_only(connection, world):
    _insert_review(connection, world['candidate'], world['reviewer'], 'REJECT', 'Not usable.')

    update_message = _expect_db_error(connection, """
        UPDATE public.m2_candidate_owner_reviews SET decision = 'APPROVE_FOR_REVIEW'
        WHERE candidate_id = :id
    """, {'id': world['candidate']})
    assert 'append-only' in update_message.lower()

    delete_message = _expect_db_error(connection, """
        DELETE FROM public.m2_candidate_owner_reviews WHERE candidate_id = :id
    """, {'id': world['candidate']})
    assert 'append-only' in delete_message.lower()

    version_message = _expect_db_error(connection, """
        UPDATE public.m2_review_question_versions SET question = 'Rewritten'
        WHERE id = :id
    """, {'id': world['candidate']})
    assert 'append-only' in version_message.lower()

    still = connection.execute(text("""
        SELECT decision, rationale FROM public.m2_candidate_owner_reviews
        WHERE candidate_id = :id
    """), {'id': world['candidate']}).one()
    assert tuple(still) == ('REJECT', 'Not usable.')


def test_approval_and_rejection_persist_and_read_back(connection, world, repository):
    """CP-09 scenario 14: both terminal decisions survive a round trip.

    One review row per candidate (``ON CONFLICT(candidate_id) DO NOTHING``), so the
    two decisions are recorded on two distinct candidates of the same objective.
    """
    approved = repository.record_owner_review(
        world['candidate'], world['reviewer'], 'APPROVE_FOR_REVIEW', 'Usable as written.')
    assert approved is not None
    assert approved['decision'] == 'APPROVE_FOR_REVIEW'
    assert approved['rationale'] == 'Usable as written.'

    rejected = _insert_candidate(connection, world['objective'], 'Which second price matters?')
    _insert_assignment(connection, rejected, world['reviewer'])
    refused = repository.record_owner_review(
        rejected, world['reviewer'], 'REJECT', 'Two price concepts in one question.')
    assert refused is not None
    assert refused['decision'] == 'REJECT'

    stored = connection.execute(text("""
        SELECT candidate_id, decision, rationale FROM public.m2_candidate_owner_reviews
        ORDER BY candidate_id
    """)).all()
    assert {row[0]: (row[1], row[2]) for row in stored} == {
        world['candidate']: ('APPROVE_FOR_REVIEW', 'Usable as written.'),
        rejected: ('REJECT', 'Two price concepts in one question.'),
    }

    queue = {row['id']: row['decision']
             for row in repository.assigned_candidate_reviews(world['reviewer'])}
    assert queue[world['candidate']] == 'APPROVE_FOR_REVIEW'
    assert queue[rejected] == 'REJECT'


def test_a_recorded_decision_cannot_be_flipped_by_a_second_review(connection, world, repository):
    """The second insert is ignored, not merged: history must not rewrite itself."""
    assert repository.record_owner_review(
        world['candidate'], world['reviewer'], 'REJECT', 'Not usable.') is not None

    assert repository.record_owner_review(
        world['candidate'], world['reviewer'], 'APPROVE_FOR_REVIEW', 'Changed my mind.') is None

    still = connection.execute(text("""
        SELECT decision, rationale FROM public.m2_candidate_owner_reviews
        WHERE candidate_id = :id
    """), {'id': world['candidate']}).one()
    assert tuple(still) == ('REJECT', 'Not usable.')


def test_api_enum_agrees_with_the_database_constraint(connection):
    """A value the DB rejects would surface as a 500, not a 422."""
    from pydantic import ValidationError

    from sitewise.api.v1.m2 import CandidateReviewRequest

    for decision in ('APPROVE_FOR_REVIEW', 'REJECT', 'REQUEST_REVISION'):
        assert CandidateReviewRequest(decision=decision, rationale='Reason.').decision == decision

    with pytest.raises(ValidationError):
        CandidateReviewRequest(decision='REQUEST_REWRITE', rationale='Reason.')

    admitted = connection.execute(text("""
        SELECT pg_get_constraintdef(oid) FROM pg_constraint
        WHERE conrelid = 'public.m2_candidate_owner_reviews'::regclass
          AND conname = 'm2_candidate_owner_reviews_decision_check'
    """)).scalar_one()
    for decision in ('APPROVE_FOR_REVIEW', 'REJECT', 'REQUEST_REVISION'):
        assert decision in admitted


# --- V3.1: assessment owner self-review -------------------------------------
def test_owner_can_record_all_three_decisions_on_their_own_candidates(connection, world, repository):
    """The owner no longer needs an independent reviewer to decide their own candidate.

    An owner assignment is inserted so the FK to m2_candidate_review_assignments
    is satisfied; the bug was the ``m.owner_user_id<>a.reviewer_id`` guard, which
    refused exactly this (candidate, owner) pair. One review per candidate, so
    each decision goes on its own version of the same objective.
    """
    recorded = {}
    for decision in ('APPROVE_FOR_REVIEW', 'REJECT', 'REQUEST_REVISION'):
        candidate = _insert_candidate(connection, world['objective'])
        _insert_assignment(connection, candidate, world['owner'], 'SELF-REVIEW')
        row = repository.record_owner_review(
            candidate, world['owner'], decision, f'Owner chose {decision}.')

        assert row is not None, decision
        assert row['candidate_id'] == candidate
        assert row['reviewer_id'] == world['owner'], 'owner branch must persist the bound :reviewer'
        assert row['decision'] == decision
        assert row['rationale'] == f'Owner chose {decision}.'
        assert row['context_hash'] == world['digest']
        recorded[candidate] = decision

    stored = connection.execute(text("""
        SELECT candidate_id, reviewer_id, decision FROM public.m2_candidate_owner_reviews
        WHERE candidate_id = ANY(:ids)
    """), {'ids': list(recorded)}).all()
    assert {row.candidate_id: (row.reviewer_id, row.decision) for row in stored} == {
        candidate: (world['owner'], decision) for candidate, decision in recorded.items()}


def test_non_owner_without_an_assignment_is_refused(connection, world, repository):
    """A stranger with no assignment matches neither OR branch and fails closed."""
    stranger = uuid4()
    candidate = _insert_candidate(connection, world['objective'])
    _insert_assignment(connection, candidate, world['reviewer'])  # only an independent reviewer

    assert repository.record_owner_review(
        candidate, stranger, 'APPROVE_FOR_REVIEW', 'Not my assessment.') is None
    assert connection.execute(text("""
        SELECT count(*) FROM public.m2_candidate_owner_reviews WHERE candidate_id = :id
    """), {'id': candidate}).scalar_one() == 0


def test_independent_reviewer_with_an_assignment_still_works(connection, world, repository):
    """The owner branch must not break the existing independent-reviewer path."""
    # world['candidate'] already carries an assignment for world['reviewer'] and
    # is owned by a different user (world['owner']).
    row = repository.record_owner_review(
        world['candidate'], world['reviewer'], 'APPROVE_FOR_REVIEW',
        'Reviewed on scientific grounds.')
    assert row is not None
    assert row['reviewer_id'] == world['reviewer']
    assert row['reviewer_id'] != world['owner']
    assert row['decision'] == 'APPROVE_FOR_REVIEW'
    assert row['context_hash'] == world['digest']


def test_owner_branch_decisions_stay_inside_the_database_check(connection, world, repository):
    """Every decision the owner branch accepts is one the DB CHECK admits."""
    definition = connection.execute(text("""
        SELECT pg_get_constraintdef(oid) FROM pg_constraint
        WHERE conrelid = 'public.m2_candidate_owner_reviews'::regclass
          AND conname = 'm2_candidate_owner_reviews_decision_check'
    """)).scalar_one()
    for decision in ('APPROVE_FOR_REVIEW', 'REJECT', 'REQUEST_REVISION'):
        assert decision in definition
        candidate = _insert_candidate(connection, world['objective'])
        _insert_assignment(connection, candidate, world['owner'], 'SELF-REVIEW')
        row = repository.record_owner_review(
            candidate, world['owner'], decision, f'Owner recorded {decision}.')
        assert row is not None and row['decision'] == decision

    bad = _insert_candidate(connection, world['objective'])
    _insert_assignment(connection, bad, world['owner'], 'SELF-REVIEW')
    message = _expect_db_error(connection, """
        INSERT INTO public.m2_candidate_owner_reviews
            (candidate_id, reviewer_id, decision, rationale, context_hash)
        VALUES (:candidate, :reviewer, 'REQUEST_REWRITE', 'Fixture.', :digest)
    """, {'candidate': bad, 'reviewer': world['owner'], 'digest': DIGEST})
    assert 'm2_candidate_owner_reviews_decision_check' in message


def test_owner_review_history_is_append_only(connection, world, repository):
    """Neither a second decision nor an UPDATE/DELETE can rewrite an owner's record."""
    _insert_assignment(connection, world['candidate'], world['owner'], 'SELF-REVIEW')
    row = repository.record_owner_review(
        world['candidate'], world['owner'], 'REJECT', 'Owner rejects this wording.')
    assert row is not None and row['reviewer_id'] == world['owner']

    assert repository.record_owner_review(
        world['candidate'], world['owner'], 'APPROVE_FOR_REVIEW', 'Changed my mind.') is None

    update_message = _expect_db_error(connection, """
        UPDATE public.m2_candidate_owner_reviews SET decision = 'APPROVE_FOR_REVIEW'
        WHERE candidate_id = :id
    """, {'id': world['candidate']})
    assert 'append-only' in update_message.lower()

    delete_message = _expect_db_error(connection, """
        DELETE FROM public.m2_candidate_owner_reviews WHERE candidate_id = :id
    """, {'id': world['candidate']})
    assert 'append-only' in delete_message.lower()

    still = connection.execute(text("""
        SELECT decision, rationale, reviewer_id FROM public.m2_candidate_owner_reviews
        WHERE candidate_id = :id
    """), {'id': world['candidate']}).one()
    assert (still.decision, still.rationale, still.reviewer_id) == (
        'REJECT', 'Owner rejects this wording.', world['owner'])
