"""Isolated actual FastAPI routes/DI and SQLite fixture persistence.

Synthetic signed JWTs exercise the existing verifier, role and ownership checks.
SQLite does not establish PostgreSQL RLS, lock isolation or scientific approval.
"""
import json
import os
from pathlib import Path
import time
from uuid import uuid4

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import APIRouter, Depends, FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, insert, select, func
from sqlalchemy.pool import StaticPool
from sqlmodel import Session

if os.environ.get('P1_OFFLINE_GUARD') != '1':
    pytest.skip('Run scripts/run_project1_offline.py; live configuration is prohibited.', allow_module_level=True)

from sitewise.main import app
from sitewise import dependencies as deps
from sitewise.core.security import SupabaseJWTVerifier
from sitewise.db.session import get_db
from sitewise.db.m2_session import get_m2_db
from sitewise.db.analytics_session import get_analytics_db
from sitewise.db.models.user import User
from sitewise.db.models.assessment import Assessment
from sitewise.db.models import m2_schema as m2
from scripts.cp04b.verify import registered_api_routes, SAFE_FAKE_URL, classify_route


def test_verifier_keeps_driver_and_effective_prefix_and_inherited_dependencies():
    assert SAFE_FAKE_URL.startswith('postgresql+psycopg2://')
    def parent_guard(): pass
    def service(): pass
    child = APIRouter(dependencies=[Depends(parent_guard)])
    @child.get('/record')
    def endpoint(value=Depends(service)): return {}
    parent = APIRouter()
    parent.include_router(child, prefix='/child')
    application = FastAPI()
    application.include_router(parent, prefix='/api')
    rows = list(registered_api_routes(application.routes))
    route, path, dependant = rows[0]
    assert path == '/api/child/record'
    assert {d.call for d in dependant.dependencies} == {parent_guard, service}
    for file, kind in [('src/sitewise/api/v1/reports.py','report'),
                       ('src/sitewise/api/v1/assessments.py','explanation')]:
        assert not classify_route({'file':file,'path':'/api/v1/assessments/{id}/'+kind},kind)


@pytest.fixture
def lab(monkeypatch):
    db = create_engine('sqlite://', poolclass=StaticPool, connect_args={'check_same_thread':False})
    User.__table__.create(db)
    Assessment.__table__.create(db)
    m2.m2_metadata.create_all(db)
    actor, other, suspended, agent = [uuid4() for _ in range(4)]
    aid = uuid4()
    with Session(db) as session:
        for uid, role, status in [(actor,'entrepreneur','active'),(other,'entrepreneur','active'),
                                  (suspended,'entrepreneur','suspended'),(agent,'agent','active')]:
            session.add(User(user_id=uid,email=f'{uid}@test.invalid',role=role,
                account_status=status,email_verified=True))
        session.add(Assessment(assessment_id=aid,user_id=actor,property_id='TEST-PROPERTY'))
        session.commit()
    def memory_session():
        with Session(db) as session: yield session
    app.dependency_overrides[get_db] = memory_session
    app.dependency_overrides[get_m2_db] = memory_session
    app.dependency_overrides[get_analytics_db] = memory_session
    key = ec.generate_private_key(ec.SECP256R1())
    public = jwt.algorithms.ECAlgorithm.to_jwk(key.public_key(), as_dict=True)
    public.update(kid='p1-offline',use='sig',alg='ES256')
    verifier = SupabaseJWTVerifier(jwks_url='https://test.invalid/jwks',issuer='https://test.invalid/auth/v1',audiences=['authenticated'])
    verifier.jwks._keys = {'p1-offline':public}
    verifier.jwks._fetched_at = time.monotonic()
    monkeypatch.setattr(deps,'_verifier',verifier)
    def headers(uid=actor):
        now = int(time.time())
        token = jwt.encode({'sub':str(uid),'email':f'{uid}@test.invalid',
            'email_verified':True,'iss':'https://test.invalid/auth/v1','aud':'authenticated',
            'iat':now,'exp':now+600},key,algorithm='ES256',headers={'kid':'p1-offline'})
        return {'Authorization':'Bearer '+token}
    client = TestClient(app)  # no lifespan: never create_all on configured engines
    yield client, headers, actor, other, suspended, agent, aid, db
    client.close()
    app.dependency_overrides.clear()
    db.dispose()


def test_readiness_real_auth_owner_scope_and_no_research_side_effects(lab):
    client, headers, actor, other, suspended, agent, aid, db = lab
    path=f'/api/v1/project1-read/assessments/{aid}/readiness'
    assert client.get(path).status_code == 401
    assert client.get(path,headers={'Authorization':'Bearer invalid'}).status_code == 401
    assert client.get(path,headers=headers(other)).status_code == 403
    assert client.get(path,headers=headers(suspended)).status_code == 403
    assert client.get(path,headers=headers(agent)).status_code == 403
    assert client.get(f'/api/v1/project1-read/assessments/{uuid4()}/readiness',headers=headers()).status_code == 404
    response=client.get(path,headers=headers())
    assert response.status_code == 200
    assert response.headers['cache-control'] == 'no-store'
    data=response.json()
    assert data['assessment_id'] == str(aid) and data['property_id']=='TEST-PROPERTY'
    assert all(data[k]['state']=='held' for k in ['review','questionnaire','report','activity'])
    assert data['fielding_authorized'] is False and data['report_release_authorized'] is False
    assert client.post(path,json={'fielding_authorized':True},headers=headers()).status_code == 405
    global_data=client.get('/api/v1/project1-read/readiness',headers=headers()).json()
    assert global_data['assessment_id'] is None
    if os.environ.get('P1_CONTRACT_OUTPUT'):
        Path(os.environ['P1_CONTRACT_OUTPUT']).write_text(json.dumps(global_data),encoding='utf-8')
    with Session(db) as session:
        record=session.get(Assessment,aid)
        assert record.report_generated_at is None and record.requirements_saved_at is None
        assert session.execute(select(m2.assessments)).all()==[]


def test_actual_m2_di_revision_bdj_confirmation_and_downstream_hold(lab):
    client, headers, actor, other, suspended, agent, aid, db = lab
    iid, item = uuid4(), uuid4()
    # Synthetic authorization is confined to this disposable fixture.
    with db.begin() as connection:
        connection.execute(insert(m2.instruments).values(id=iid,code='M2-TEST',version_tag='SYNTHETIC',
            approval_state='AUTHORIZED',schema_digest='a'*64))
        connection.execute(insert(m2.items).values(id=item,instrument_id=iid,item_key='M2-04',
            question_text='Synthetic source declaration',requiredness='OPTIONAL',answer_kind='TEXT',
            option_values=[],allowed_states=['ANSWERED','NOT_PROVIDED'],lifecycle='ACTIVE',sort_order=1))
    response=client.post('/api/v1/m2/assessments',headers=headers(),json={'instrument_version_id':str(iid)})
    assert response.status_code==201,response.text
    mid=response.json()['id']
    path=f'/api/v1/m2/assessments/{mid}'
    update={'expected_revision':0,'answer_state':'ANSWERED','value':'Original synthetic café declaration.'}
    changed=client.put(path+'/answers/M2-04',headers=headers(),json=update)
    assert changed.status_code==200,changed.text
    assert client.put(path+'/answers/M2-04',headers=headers(),json=update).status_code==409
    assert client.get(path,headers=headers(other)).status_code==404
    evaluated=client.post(path+'/bdj/evaluate',headers=headers(),json={'expected_revision':1})
    assert evaluated.status_code==200,evaluated.text
    assert evaluated.json()['evaluation_state']=='EVALUATED_CANDIDATE'
    assert evaluated.json()['qj_handoff_authorized'] is False
    assert client.post(path+'/review',headers=headers(),json={'expected_revision':1}).status_code==200
    confirmed=client.post(path+'/confirm',headers=headers(),json={'expected_revision':1,'acknowledged_issue_ids':[]})
    assert confirmed.status_code==200,confirmed.text
    result=confirmed.json()
    assert not result.get('qj_handoff_authorized',False)
    before=client.get(path,headers=headers()).json()
    assert before['current_confirmation_valid'] is True
    from uuid import UUID
    confirmation_id = str(result['confirmation']['id']) if 'confirmation' in result else str(result['id'])
    query = {'confirmation_id': confirmation_id, 'expected_revision': 1}
    counts_before = {}
    with Session(db) as session:
        counts_before = {t.name: session.execute(select(func.count()).select_from(t)).scalar()
                         for t in m2.m2_metadata.sorted_tables}
    reviewed = client.get(path+'/confirmed-review', headers=headers(), params=query)
    assert reviewed.status_code == 200, reviewed.text
    data = reviewed.json()
    assert reviewed.headers['cache-control'] == 'no-store'
    assert data['assessment_id'] == mid and data['confirmation_id'] == confirmation_id
    assert data['answers'][0]['value'] == update['value']
    assert {e['kind'] for e in data['activity']} == {
        'ANSWER_SAVED', 'BDJ_EVALUATED', 'REVIEW_RECORDED', 'CONTEXT_CONFIRMED'}
    assert data['activity_truncated'] is False
    assert data['fielding_authorized'] is data['report_release_authorized'] is False
    with Session(db) as session:
        assert counts_before == {t.name: session.execute(select(func.count()).select_from(t)).scalar()
                                 for t in m2.m2_metadata.sorted_tables}
    assert client.get(path+'/confirmed-review', params=query).status_code == 401
    assert client.get(path+'/confirmed-review', headers=headers(other), params=query).status_code == 404
    assert client.get(path+'/confirmed-review', headers=headers(), params={**query,
        'confirmation_id': str(uuid4())}).status_code == 404
    assert client.get(path+'/confirmed-review', headers=headers(), params={**query,
        'expected_revision': -1}).status_code == 422
    # Validly hashed but altered source values must still fail the existing
    # persisted-current-answer integrity check; restore the isolated fixture.
    with db.begin() as connection:
        row = connection.execute(select(m2.confirmations).where(
            m2.confirmations.c.id == UUID(confirmation_id))).mappings().one()
        original_digest = row['snapshot_digest']
        connection.execute(m2.confirmations.update().where(m2.confirmations.c.id == UUID(confirmation_id))
            .values(snapshot_digest='0'*64))
    assert client.get(path+'/confirmed-review', headers=headers(), params=query).status_code == 409
    with db.begin() as connection:
        connection.execute(m2.confirmations.update().where(m2.confirmations.c.id == UUID(confirmation_id))
            .values(snapshot_digest=original_digest))
    output = os.environ.get('P1_CONTRACT_OUTPUT')
    if output:
        Path(output).with_name('confirmed_review_contract.json').write_text(json.dumps(data), encoding='utf-8')
    # Confirmation in M2 cannot bind a workspace or field a questionnaire.
    readiness=client.get(f'/api/v1/project1-read/assessments/{aid}/readiness',headers=headers()).json()
    assert readiness['review']['code']=='M2_BINDING_REQUIRED'
    assert readiness['questionnaire']['state']=='held'
    assert readiness['report_release_authorized'] is False
    changed=client.put(path+'/answers/M2-04',headers=headers(),json={**update,'expected_revision':1,'value':'Revised declaration.'})
    assert changed.status_code==200,changed.text
    after=client.get(path,headers=headers()).json()
    assert after['current_confirmation_valid'] is False
    assert client.get(path+'/confirmed-review', headers=headers(), params=query).status_code == 409
    assert client.post(path+'/confirm',headers=headers(),json={'expected_revision':1}).status_code==409


def test_confirmed_review_real_findings_bounded_history_and_missing_stream(lab, monkeypatch):
    from uuid import UUID
    from datetime import datetime, timezone, timedelta
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    from sitewise.services.confirmation_service import ConfirmationService
    client, headers, actor, other, suspended, agent, aid, db = lab
    iid, item = uuid4(), uuid4()
    with db.begin() as connection:
        connection.execute(insert(m2.instruments).values(id=iid, code='TEST-REVIEW',
            version_tag='SYNTHETIC', approval_state='AUTHORIZED', schema_digest='b'*64))
        connection.execute(insert(m2.items).values(id=item, instrument_id=iid, item_key='M2-04',
            question_text='Synthetic declaration', requiredness='OPTIONAL', answer_kind='TEXT',
            option_values=[], allowed_states=['ANSWERED'], lifecycle='ACTIVE', sort_order=1))
    mid = client.post('/api/v1/m2/assessments', headers=headers(),
        json={'instrument_version_id':str(iid)}).json()['id']
    path = f'/api/v1/m2/assessments/{mid}'
    assert client.put(path+'/answers/M2-04', headers=headers(), json={
        'expected_revision':0, 'answer_state':'ANSWERED', 'value':'We guarantee profit.'}).status_code == 200
    evaluated = client.post(path+'/bdj/evaluate', headers=headers(),json={'expected_revision':1})
    assert evaluated.status_code == 200, evaluated.text
    finding = evaluated.json()['findings'][0]
    with Session(db) as session:
        ConfirmationService(SqlModelM2Repository(session)).record_finding_decision(UUID(mid), actor,
            finding_id=UUID(finding['id']), expected_revision=1, decision='KEEP_ORIGINAL', request_id=uuid4())
    assert client.post(path+'/review', headers=headers(), json={'expected_revision':1}).status_code == 200
    response = client.post(path+'/confirm', headers=headers(), json={
        'expected_revision':1, 'acknowledged_issue_ids':[finding['id']]})
    assert response.status_code == 200, response.text
    cid = response.json()['id']
    query = {'confirmation_id':cid, 'expected_revision':1}
    response = client.get(path+'/confirmed-review', headers=headers(), params=query)
    assert response.status_code == 200, response.text
    assert response.json()['findings'][0]['source_answer_ids'] == finding['source_answer_ids']
    assert 'CLARIFICATION_RECORDED' in {e['kind'] for e in response.json()['activity']}
    # A previously confirmed finding with a foreign answer reference is rejected.
    with db.begin() as connection:
        connection.execute(m2.findings.update().where(m2.findings.c.id == UUID(finding['id']))
            .values(source_answer_ids=[str(uuid4())]))
    assert client.get(path+'/confirmed-review', headers=headers(), params=query).status_code == 409
    with db.begin() as connection:
        connection.execute(m2.findings.update().where(m2.findings.c.id == UUID(finding['id']))
            .values(source_answer_ids=finding['source_answer_ids']))
        # Test-only extra real-shaped receipts exercise global bounding/tie-breaks.
        for i in range(55):
            connection.execute(insert(m2.clarification_events).values(id=uuid4(), assessment_id=UUID(mid),
                assessment_revision=1, finding_id=UUID(finding['id']), actor_user_id=actor,
                decision='KEEP_ORIGINAL', event_sequence=i+2, request_id=uuid4(),
                created_at=datetime(2026,1,1,tzinfo=timezone.utc)+timedelta(seconds=i)))
    response = client.get(path+'/confirmed-review', headers=headers(), params=query)
    assert response.status_code == 200, response.text
    data = response.json()
    assert len(data['activity']) == 50 and data['activity_truncated'] is True
    assert len({e['event_id'] for e in data['activity']}) == 50
    assert data['activity'] == sorted(data['activity'],
        key=lambda e:(e['occurred_at'], e['event_id']), reverse=True)
    # Simulate the actual missing-stream deployment gap in disposable data only.
    m2.clarification_events.drop(db)
    response = client.get(path+'/confirmed-review', headers=headers(), params=query)
    assert response.status_code == 503, response.text
    assert response.json()['detail']['code'] == 'M2_REVIEW_SOURCE_UNAVAILABLE'
    assert response.headers['cache-control'] == 'no-store'
