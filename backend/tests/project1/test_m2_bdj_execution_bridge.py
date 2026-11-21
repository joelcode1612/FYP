"""Synthetic M2 route tests; no provider or live database is contacted."""
from contextlib import contextmanager
from types import SimpleNamespace
from uuid import UUID

from fastapi import FastAPI
from fastapi.testclient import TestClient

from sitewise.api.v1 import m2
from sitewise.dependencies import get_m2_service, require_entrepreneur
from sitewise.project1.contracts import WorkflowHeld
from sitewise.main import workflow_held_handler
from sitewise.services import m2_bdj_execution

ASSESSMENT = UUID('00000000-0000-4000-8000-000000000001')
OWNER = UUID('00000000-0000-4000-8000-000000000002')
CONFIRMATION = UUID('00000000-0000-4000-8000-000000000003')


class Service:
    def __init__(self, confirmed=True):
        self.confirmed = confirmed
        self.repo = SimpleNamespace(latest_confirmation=self.latest)
        self.checked = []

    def latest(self, assessment, owner):
        assert (assessment, owner) == (ASSESSMENT, OWNER)
        return {'id': CONFIRMATION} if self.confirmed else None

    @contextmanager
    def locked_confirmed_source(self, assessment, owner, **kwargs):
        self.checked.append((assessment, owner, kwargs))
        yield {'confirmation_id': CONFIRMATION}


def client_for(service):
    app = FastAPI()
    app.include_router(m2.router, prefix='/api/v1/m2')
    app.add_exception_handler(WorkflowHeld, workflow_held_handler)
    app.dependency_overrides[get_m2_service] = lambda: service
    app.dependency_overrides[require_entrepreneur] = lambda: SimpleNamespace(user_id=OWNER)
    return TestClient(app)


def test_missing_confirmation_does_not_reach_execution(monkeypatch):
    service = Service(confirmed=False)
    calls = []
    monkeypatch.setattr(m2_bdj_execution, 'execute_confirmed_bdj',
                        lambda *args: calls.append(args))
    response = client_for(service).post(f'/api/v1/m2/assessments/{ASSESSMENT}/bdj/evaluate',
                                        json={'expected_revision': 4})
    assert response.status_code == 409
    assert response.json()['detail']['code'] == 'M2_CONFIRMATION_REQUIRED'
    assert calls == []


def test_current_confirmation_reaches_server_orchestrator(monkeypatch):
    service = Service()
    calls = []
    def execute(svc, user, assessment, revision):
        calls.append((svc, user.user_id, assessment, revision))
        return {'outcome': 'SYNTHETIC_TEST_ONLY'}
    monkeypatch.setattr(m2_bdj_execution, 'execute_confirmed_bdj', execute)
    response = client_for(service).post(f'/api/v1/m2/assessments/{ASSESSMENT}/bdj/evaluate',
                                        json={'expected_revision': 4})
    assert response.status_code == 200
    assert service.checked[0][2] == {'confirmation_id': CONFIRMATION, 'expected_revision': 4}
    assert calls == [(service, OWNER, ASSESSMENT, 4)]


def test_caller_cannot_mark_real_source_synthetic(monkeypatch):
    calls = []
    monkeypatch.setattr(m2_bdj_execution, 'execute_confirmed_bdj',
                        lambda *args: calls.append(args))
    response = client_for(Service()).post(f'/api/v1/m2/assessments/{ASSESSMENT}/bdj/evaluate',
        json={'expected_revision': 4, 'data_class': 'SYNTHETIC_NONHUMAN'})
    assert response.status_code == 422
    assert calls == []


def test_disclosure_hold_from_server_is_not_zero_findings(monkeypatch):
    def held(*args):
        raise WorkflowHeld('DISCLOSURE_REAL_DATA_NOT_AUTHORIZED')
    monkeypatch.setattr(m2_bdj_execution, 'execute_confirmed_bdj', held)
    response = client_for(Service()).post(f'/api/v1/m2/assessments/{ASSESSMENT}/bdj/evaluate',
                                        json={'expected_revision': 4})
    assert response.status_code in (409, 503)
    assert response.json()['detail']['code'] == 'DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'


def test_bridge_reuses_existing_gates_source_and_runner(monkeypatch):
    from sitewise.api.v1 import project1_workflow as workflow
    session, runtime = object(), object()
    service = SimpleNamespace(repo=SimpleNamespace(session=session))
    user = SimpleNamespace(user_id=OWNER)
    events = []
    packet = {'source_fingerprint': 'synthetic-fixture', 'data_class': 'SYNTHETIC_NONHUMAN'}
    monkeypatch.setattr(workflow, 'configuration_gate', lambda s: events.append(('config', s)))
    monkeypatch.setattr(workflow, 'model_assisted_gate', lambda: events.append(('policy',)))
    monkeypatch.setattr(workflow, 'source', lambda s, u, a, r: packet)
    monkeypatch.setattr(workflow, 'get_runtime_engine', lambda: runtime)
    runner = object()
    monkeypatch.setattr(workflow, 'configured_runner', runner)
    def orchestrator(**kw):
        events.append(('orchestrator', kw))
        assert kw['current_fingerprint']() == packet['source_fingerprint']
        return {'outcome': 'synthetic-orchestrator-double'}
    monkeypatch.setattr(m2_bdj_execution, 'run_model_assisted', orchestrator)
    result = m2_bdj_execution.execute_confirmed_bdj(service, user, ASSESSMENT, 4)
    assert result['outcome'] == 'synthetic-orchestrator-double'
    assert [x[0] for x in events] == ['config', 'policy', 'orchestrator']
    assert events[-1][1]['runner_factory'] is runner
    assert events[-1][1]['runtime_engine'] is runtime
    assert events[-1][1]['packet'] is packet


def test_unadopted_rules_do_not_create_an_immutable_run(monkeypatch):
    from sitewise.project1 import model_assisted
    calls = []
    monkeypatch.setattr(model_assisted, 'validate_synthetic', lambda **kw: None)
    def refuse(*args):
        raise WorkflowHeld('BDJ_RULE_ADOPTION_REQUIRED')
    monkeypatch.setattr(model_assisted, 'load_rules', refuse)
    monkeypatch.setattr(model_assisted, 'ensure_run', lambda *args: calls.append(args))
    import pytest
    with pytest.raises(WorkflowHeld, match='BDJ_RULE_ADOPTION_REQUIRED'):
        model_assisted.run_model_assisted(
            packet={'assessment_id': str(ASSESSMENT), 'assessment_revision': 4,
                    'source_fingerprint': 'fixture'}, actor_id=OWNER,
            runtime_engine=object(), runner_factory=object(), current_fingerprint=lambda: 'fixture')
    assert calls == []


def test_m2v1_legacy_rules_cannot_dispatch_or_create_run(monkeypatch):
    from sitewise.project1 import model_assisted
    import pytest
    calls = []
    monkeypatch.setattr(model_assisted, 'validate_synthetic', lambda **kw: None)
    monkeypatch.setattr(model_assisted, 'load_rules', lambda *args: SimpleNamespace())
    monkeypatch.setattr(model_assisted, 'ensure_run', lambda *args: calls.append(args))
    with pytest.raises(WorkflowHeld, match='BDJ_INSTRUMENT_RULESET_UNVERIFIED'):
        model_assisted.run_model_assisted(
            packet={'assessment_id': str(ASSESSMENT), 'assessment_revision': 4,
                    'source_fingerprint': 'fixture', 'instrument_version': 'M2V1-20261114-1'},
            actor_id=OWNER, runtime_engine=object(), runner_factory=object(),
            current_fingerprint=lambda: 'fixture')
    assert calls == []


def test_current_result_requires_matching_confirmation_and_rechecks_source(monkeypatch):
    import pytest
    from sitewise.api.v1 import project1_workflow as workflow
    from sitewise.core.exceptions import ConflictError
    service = SimpleNamespace(repo=SimpleNamespace(session=object()))
    user = SimpleNamespace(user_id=OWNER)
    packet = {'source_fingerprint': 'a' * 64, 'confirmation': {'confirmation_id': str(CONFIRMATION)}}
    monkeypatch.setattr(workflow, 'source', lambda *args: packet)
    monkeypatch.setattr(workflow, 'get_runtime_engine', lambda: object())
    monkeypatch.setattr(m2_bdj_execution, 'results_for_assessment', lambda *args, **kw: [])
    result = m2_bdj_execution.read_current_bdj(service, user, ASSESSMENT, CONFIRMATION, 4)
    assert result['status'] == 'NO_CURRENT_RESULT' and result['result'] is None
    with pytest.raises(ConflictError):
        m2_bdj_execution.read_current_bdj(service, user, ASSESSMENT, OWNER, 4)
    packets = iter([packet, {**packet, 'source_fingerprint': 'b' * 64}])
    monkeypatch.setattr(workflow, 'source', lambda *args: next(packets))
    with pytest.raises(ConflictError):
        m2_bdj_execution.read_current_bdj(service, user, ASSESSMENT, CONFIRMATION, 4)


def test_current_result_api_uses_authenticated_owner_and_selected_source(monkeypatch):
    service = Service()
    calls = []
    def read(svc, user, assessment, confirmation, revision):
        calls.append((svc, user.user_id, assessment, confirmation, revision))
        return {'status': 'NO_CURRENT_RESULT'}
    monkeypatch.setattr(m2_bdj_execution, 'read_current_bdj', read)
    response = client_for(service).get(f'/api/v1/m2/assessments/{ASSESSMENT}/bdj/current',
        params={'confirmation_id': str(CONFIRMATION), 'expected_revision': 4})
    assert response.status_code == 200
    assert response.headers['cache-control'] == 'private, no-store'
    assert calls == [(service, OWNER, ASSESSMENT, CONFIRMATION, 4)]
