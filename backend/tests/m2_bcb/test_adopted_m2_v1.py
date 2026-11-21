"""Owner-adopted source exercised only against the existing disposable PG lab."""
import json
import os
from pathlib import Path
from uuid import UUID

import pytest
from sqlalchemy import text

from test_postgres_api import lab, case_name  # Existing real HTTP/JWT/PG fixtures.
from scripts.register_m2_v1 import definition, register


def instrument(lab):
    return register(lab['db'], apply=True, expected_database='project1_m2_bcb_test')['instrument_id']


def create(lab):
    iid = instrument(lab)
    return lab['request']('POST', '/assessments', 201, json={'instrument_version_id': iid}).json()['id']


def save(lab, mid, key, value, rev, status=200, state='ANSWERED'):
    return lab['request']('PUT', f'/assessments/{mid}/answers/{key}', status,
        json={'expected_revision': rev, 'answer_state': state, 'value': value})


def test_registration_exact_source_actions_and_idempotency(lab):
    a = register(lab['db'], apply=True, expected_database='project1_m2_bcb_test')
    b = register(lab['db'], apply=True, expected_database='project1_m2_bcb_test')
    assert b['replayed'] and a['instrument_id'] == b['instrument_id']
    d = lab['request']('GET', '/instruments/' + a['instrument_id']).json()
    original = definition()[0]['items']
    assert len(d['items']) == 13
    assert [(q['item_key'], q['question_text'], q['option_values']) for q in d['items']] == [
        (q['item_key'], q['question_text'], q['option_values']) for q in original]
    assert sum(q['answer_kind'] == 'ACTION' for q in d['items']) == 2
    mid = create(lab)
    save(lab, mid, 'M2-20', 'not an answer', 0, 422)
    save(lab, mid, 'M2-21', 'not an answer', 0, 422)
    with pytest.raises(ValueError, match='identity'):
        register(lab['db'], apply=True, expected_database='Dss')


@pytest.mark.parametrize('key,value', [('M2V1-03',['UNDECIDED','COFFEE']),
    ('M2V1-04',['UNDECIDED','STUDENTS']), ('M2V1-08',['UNKNOWN','NONE']),
    ('M2V1-08',['NONE','CUSTOMER_SURVEY']), ('M2V1-09',['NONE','CONCEPT_INTEREST'])])
def test_exclusive_codes_rejected_without_writes(lab, key, value):
    mid = create(lab)
    save(lab, mid, key, value, 0, 422)
    assert lab['request']('GET', '/assessments/' + mid).json()['assessment']['revision'] == 0


def test_conditions_geo_boundary_and_no_prior_confirmation(lab):
    mid = create(lab)
    save(lab, mid, 'M2V1-01', {'jurisdiction':'JOHOR','area_ref':'invented','catalogue_version':'fake'}, 0, 422)
    save(lab, mid, 'M2V1-01', 'UNDECIDED', 0)
    save(lab, mid, 'M2V1-04', ['STUDENTS'], 1)
    d = lab['request']('GET', '/assessments/' + mid).json()
    assert d['assessment']['confirmed_revision'] is None
    assert next(q for q in d['items'] if q['item_key']=='M2V1-05')['derived_value'] == 'STUDENTS'
    save(lab, mid, 'M2V1-05', 'OFFICE_WORKERS', 2, 422)
    save(lab, mid, 'M2V1-11', 'EXPLORE', 2, 422)
    save(lab, mid, 'M2V1-09', ['CONCEPT_INTEREST','PRICE_ACCEPTABILITY'], 2)
    save(lab, mid, 'M2V1-10', 'SERVICE_PREFERENCE', 3, 422)
    save(lab, mid, 'M2V1-10', 'PRICE_ACCEPTABILITY', 3)
    save(lab, mid, 'M2V1-11', 'EXPLORE', 4)
    save(lab, mid, 'M2V1-07', None, 5, 422, 'NOT_APPLICABLE')
    save(lab, mid, 'M2V1-02', 'DELIVERY', 5)
    save(lab, mid, 'M2V1-07', None, 6, 200, 'NOT_APPLICABLE')
    with lab['db'].connect() as c:
        assert c.scalar(text('SELECT count(*) FROM m2_bdj_evaluations WHERE assessment_id=:id'),{'id':UUID(mid)}) == 0


def test_revision_persistence_submission_review_confirmation(lab):
    mid = create(lab)
    lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',409,json={'expected_revision':0})
    values={'M2V1-01':'UNDECIDED','M2V1-02':'DINE_IN','M2V1-03':['COFFEE'],
        'M2V1-04':['STUDENTS'],'M2V1-06':'QUALITY','M2V1-08':['NONE'],
        'M2V1-09':['CONCEPT_INTEREST'],'M2V1-11':'EXPLORE'}
    for revision,(key,value) in enumerate(values.items()): save(lab,mid,key,value,revision)
    save(lab,mid,'M2V1-02','HYBRID',8)
    save(lab,mid,'M2V1-02','DELIVERY',8,409)
    lab['request']('GET',f'/assessments/{mid}',404,uid=lab['other'])
    lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',json={'expected_revision':9})
    lab['request']('POST',f'/assessments/{mid}/review',json={'expected_revision':9})
    confirmed=lab['request']('POST',f'/assessments/{mid}/confirm',json={'expected_revision':9,'acknowledged_issue_ids':[]}).json()
    with lab['db'].connect() as c:
        rows=c.execute(text('SELECT assessment_revision,answer_state,value_json FROM m2_answer_revisions WHERE assessment_id=:id ORDER BY assessment_revision'),{'id':UUID(mid)}).mappings().all()
    assert len(rows)==9 and rows[1]['value_json']=='DINE_IN' and rows[-1]['value_json']=='HYBRID'
    snapshot=confirmed['snapshot_json']
    assert {x['item_key']:x['value'] for x in snapshot['derived_selections']} == {'M2V1-05':'STUDENTS','M2V1-10':'CONCEPT_INTEREST'}
    path = f"/confirmations/{confirmed['id']}/research-objectives"
    intent = dict(origin='ENTREPRENEUR', objective='Explore concept interest', expected_revision=9)
    lab['request']('POST', path, 404, uid=lab['other'], json=intent)
    lab['request']('POST', path, 409, json={**intent, 'expected_revision':8})
    lab['request']('POST', path, 409, json={**intent, 'origin':'BDJ'})
    objective = lab['request']('POST', path, 201, json=intent).json()
    with lab['db'].connect() as connection:
        persisted = connection.scalar(text('SELECT provenance FROM m2_research_objective_sources WHERE objective_id=:id'), {'id':UUID(objective['id'])})
    assert persisted == objective['source']
    assert persisted['priority'] == 'CONCEPT_INTEREST'
    assert persisted['answer_revisions']['M2V1-11']['value'] == 'EXPLORE'
    assert not objective['qj_execution_authorized']
    from test_postgres_api import confirmed as confirm_fixture
    other_mid, other_cid, _ = confirm_fixture(lab, 'We guarantee profit.', uncertainty=False)
    finding = lab['request']('GET', f'/assessments/{other_mid}/business-understanding').json()['findings'][0]
    bdj_intent = dict(origin='BDJ', expected_revision=3, finding_id=finding['id'],
                      objective='Review the unsupported profit claim')
    bdj_objective = lab['request']('POST', f'/confirmations/{other_cid}/research-objectives',
                                   201, json=bdj_intent).json()
    assert bdj_objective['source']['finding_id'] == finding['id']
    assert bdj_objective['source']['finding_decision_id']
    lab['request']('POST', path, 409, json={**bdj_intent, 'expected_revision':9})
    from sitewise.project1.contracts import QJOutput
    for saved, rev in ((objective, 9), (bdj_objective, 3)):
        endpoint = f"/research-objectives/{saved['id']}/qj-context?expected_revision={rev}"
        context = lab['request']('GET', endpoint).json()
        assert context['objective'] == saved['exact_text'] and context['source'] == saved['source']
        lab['request']('GET', endpoint, 404, uid=lab['other'])
        # Controlled synthetic HOLD replay. Schema validation only; no dispatch.
        replay = QJOutput.model_validate(dict(route='HOLD', justification='Synthetic insufficient context', measurement=None))
        assert replay.measurement is None and not context['qj_execution_authorized']
    def synthetic_hold(identifier):
        with lab['db'].begin() as connection:
            connection.execute(text("""INSERT INTO m2_research_clarifications
                VALUES (:id,'Specific alternatives missing','Explore general category interest')"""),
                {'id':UUID(identifier)})
    for action in ('EXPLORE','CLARIFY'):
        saved = lab['request']('POST', path, 201, json=intent).json()
        synthetic_hold(saved['id'])
        route = f"/research-objectives/{saved['id']}/confirmed-revisions"
        payload = dict(expected_revision=9, action=action)
        if action == 'CLARIFY':
            payload['clarification'] = 'Compare coffee and tea.'
        lab['request']('POST', route, 404, uid=lab['other'], json=payload)
        child = lab['request']('POST', route, 201, json=payload).json()
        assert child['source']['parent_objective_id'] == saved['id']
        lab['request']('POST', route, 409, json=payload)
        if action == 'EXPLORE':
            assert child['exact_text'] == 'Explore general category interest'
            synthetic_hold(child['id'])
            lab['request']('POST', f"/research-objectives/{child['id']}/confirmed-revisions",409,json=payload)
        else:
            assert child['exact_text'] == intent['objective']
            assert child['source']['clarification'] == payload['clarification']
    from uuid import uuid4
    def synthetic_candidate(previous=None):
        version = uuid4()
        with lab['db'].begin() as connection:
            connection.execute(text("""INSERT INTO m2_review_question_versions VALUES
              (:id,:objective,'SYNTHETIC-BANK-RECEIPT','Which category?',
               CAST(:options AS jsonb),
               :previous)"""), dict(id=version,objective=UUID(objective['id']),previous=previous, options=json.dumps([dict(code="A",label="Coffee",eligible=True),dict(code="B",label="Skip",eligible=False)])))
        return version
    version = synthetic_candidate()
    read = f'/research-questions/{version}/entrepreneur-review?expected_revision=9'
    write = f'/research-questions/{version}/desired-option'
    original = lab['request']('GET',read).json()
    assert original['option_code'] is None
    for code in ('B','invented'):
        lab['request']('PUT',write,422,json=dict(expected_revision=9,option_code=code))
    lab['request']('PUT',write,404,uid=lab['other'],json=dict(expected_revision=9,option_code='A'))
    lab['request']('PUT',write,json=dict(expected_revision=9,option_code='A'))
    assert lab['request']('GET',read).json() == {**original,'option_code':'A'}
    successor = synthetic_candidate(version)
    lab['request']('PUT',write,404,json=dict(expected_revision=9,option_code='A'))
    assert lab['request']('GET',f'/research-questions/{successor}/entrepreneur-review?expected_revision=9').json()['option_code'] is None
    from test_postgres_api import bind, build
    bind(lab, mid, confirmed['id'], objective['id'], test_concept='Synthetic independently bound concept')
    packet = build(lab, mid, confirmed['id'], revision=9).json()['packet']
    from types import SimpleNamespace
    from sitewise.project1.research import ResearchWorkflow
    bind(lab, other_mid, other_cid, bdj_objective['id'])
    bdj_packet = build(lab, other_mid, other_cid).json()['packet']
    observed = []
    def replay(stage, payload, schema):
        assert stage == 'QJ'
        observed.append(payload['research_objective']['source']['origin'])
        return dict(route='HOLD', justification='Specific alternatives missing', measurement=None)
    def read_context(identifier, actor, revision):
        assert actor == lab['actor']
        return lab['request']('GET',f'/research-objectives/{identifier}/qj-context?expected_revision={revision}').json()
    for stored, saved, revision in ((packet,objective,9),(bdj_packet,bdj_objective,3)):
        authority = SimpleNamespace(admit_qj=lambda p: {'uncertainty_version':saved['id']},
                                    require_current=lambda p,t: None)
        workflow = ResearchWorkflow(SimpleNamespace(get_context=lambda _:stored),authority,None,replay)
        from sqlalchemy.orm import Session
        from sitewise.repositories.m2_repository import SqlModelM2Repository
        from sitewise.services.confirmation_service import ConfirmationService
        with Session(lab['db']) as session:
            service = ConfirmationService(SqlModelM2Repository(session))
            result = workflow.execute_objective(None,UUID(saved['id']),lab['actor'],revision,service,
                clarification_policy=lambda ctx,qj: (qj['justification'],'Explore general category interest'))
            recorded = service.repo.objective_limitation(UUID(saved['id']))
            assert recorded['limitation'] == result['qj']['justification']
            assert recorded['broader_objective'] == 'Explore general category interest'
            if saved is objective:
                route = f"/research-objectives/{saved['id']}/confirmed-revisions"
                payload = dict(expected_revision=revision, action="EXPLORE")
                revised = lab['request']('POST', route, 201, json=payload).json()
                final = workflow.execute_objective(None,UUID(revised['id']),lab['actor'],revision,service,
                    clarification_policy=lambda ctx,qj: (qj['justification'],'Another proposal'))
                assert final['qg'] is None and final['bank'] == 'not_checked'
                assert service.repo.objective_limitation(UUID(revised['id']))['broader_objective'] is None
                lab['request']('POST', f"/research-objectives/{revised['id']}/confirmed-revisions",409,json=payload)
            # Independent controlled suitable replay on the confirmed child.
            evaluated = revised if saved is objective else saved
            if evaluated:
                authority.admit_qj = lambda p: {'uncertainty_version':evaluated['id']}
                measurement = dict(uncertainty_version=evaluated['id'], construct='stated interest',
                    population='adult respondents', timeframe='this month', stimulus='category interest',
                    response_options=['Interested','Unsure'], response_codes=['I','U'],
                    routing={'I':'END','U':'END'}, denominator='valid respondents',
                    source_refs=[evaluated['id']], limitations='Synthetic stated interest only.')
                receipt = dict(outcome='verified_equivalent',item_version='SYN-BANK-V2',approval_receipt='SYN-ONLY')
                authority.validate_measurement = lambda *args: None
                workflow.bank = SimpleNamespace(lookup=lambda *args:receipt, verify_receipt=lambda *args:None)
                workflow.runner = lambda stage,*args: dict(route='CUSTOMER_SURVEY_CANDIDATE',
                    justification='Synthetic replay', measurement=measurement) if stage=='QJ' else pytest.fail(stage)
                candidate = dict(match_classification='PARTIAL_CONTEXT' if saved is objective else 'CLASSIFICATION_UNCERTAIN',question='How interested are you in this category?',source_version='SYN-BANK-V2',
                    source_receipt='SYN-ONLY',options=[dict(code='I',label='Interested',eligible=True),
                                                     dict(code='U',label='Unsure',eligible=False)])
                def ingest():
                    return workflow.execute_objective(None,UUID(evaluated['id']),lab['actor'],revision,service,
                        candidate_policy=lambda *args:candidate)['candidate_version']
                version_id = ingest()
                assert ingest() == version_id
                review_url = f'/research-questions/{version_id}/entrepreneur-review?expected_revision={revision}'
                if saved is objective and os.environ.get('PART_TWO_CROSS_APP') == '1':
                    import importlib.util
                    import httpx
                    from sitewise.api.v1 import customer_questionnaire as cq_api
                    from sitewise.domain.customer_questionnaire import digest
                    spec = importlib.util.spec_from_file_location('cq_isolation_helpers',
                        Path(__file__).parents[1]/'cq_runtime/test_postgres_api.py')
                    helpers = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(helpers)
                    with lab['db'].begin() as c:
                        c.execute(text('CREATE TABLE test_cq_authority(release_id uuid PRIMARY KEY,enabled boolean NOT NULL)'))
                    lab['app'].dependency_overrides[cq_api.get_cq_authority] = lambda: helpers.TestOnlyAuthority(
                        'project1_m2_bcb_test','M2_BCB_PRIVATE_CLUSTER')
                    rid, manifest = helpers.release(lab, mode='C0')
                    def cq(method, path, actor, **kwargs):
                        response = httpx.request(method,lab['base']+'/api/v1/cq'+path,
                            headers={'Authorization':'Bearer '+lab['token'](actor)},**kwargs)
                        response.raise_for_status()
                        return response.json()
                    campaign = cq('POST',f'/assessments/{mid}/campaign',lab['actor'],json={'release_id':rid})
                    cq('POST',f"/campaigns/{campaign['id']}/participants",lab['actor'],
                        json={'respondent_id':str(lab['other'])})
                    customer = cq('POST','/sessions',lab['other'],json={'campaign_id':campaign['id'],
                        'manifest_hash':digest(manifest),'locale':'EN'})
                    session_url = '/sessions/'+customer['session_id']
                    original_session = cq('GET',session_url,lab['other'])
                    original_manifest = cq('GET','/manifests/'+rid,lab['other'])
                before = lab['request']('GET',review_url).json()
                lab['request']('PUT',f'/research-questions/{version_id}/desired-option',
                               json=dict(expected_revision=revision,option_code='I'))
                assert lab['request']('GET',review_url).json() == {**before,'option_code':'I'}
                if saved is objective and os.environ.get('PART_TWO_CROSS_APP') == '1':
                    assert cq('GET',session_url,lab['other']) == original_session
                    assert cq('GET','/manifests/'+rid,lab['other']) == original_manifest
                    assert 'desired_option' not in json.dumps(original_session)
                    lab['request']('GET',review_url,404,uid=lab['other'])
                    def respondent_request(method,path,expected=200,json=None):
                        data=cq(method,path,lab['other'],**({'json':json} if json else {}))
                        assert 'desired_option' not in str(data) and 'broader_objective' not in str(data)
                        assert str(version_id) not in str(data)
                        return data
                    harness={'request':respondent_request}
                    consented=helpers.post(harness,customer,'consent',dict(request_id=str(uuid4()),
                        consented=True,consent_version=manifest['consent_version']))
                    completed=helpers.complete(harness,consented)
                    submitted=helpers.post(harness,completed,'submit',dict(request_id=str(uuid4())))
                    assert submitted['receipt']['execution_scope']=='ISOLATED_TEST'
                    overview=lab['request']('GET',f'/assessments/{mid}/workflow-overview').json()['projection_data']
                    assert any(c['receipts']==1 and c['sessions']==1 for c in overview['campaigns'])
                    assert 'respondent_user_id' not in str(overview['campaigns'])
                decision = dict(decision='REJECT' if saved is objective else 'APPROVE_FOR_REVIEW',rationale='Synthetic scope limitation retained')
                url = f'/research-questions/{version_id}/owner-review'
                lab['request']('POST',url,404,json=decision)
                with lab['db'].begin() as conn:
                    conn.execute(text('INSERT INTO m2_candidate_review_assignments VALUES (:v,:r,:ref)'),
                                 dict(v=UUID(version_id),r=lab['other'],ref='SYNTHETIC REVIEW ASSIGNMENT'))
                if os.environ.get('OWNER_BROWSER') == '1':
                    import subprocess
                    from sitewise.db.models.favourite_property import FavouriteProperty
                    FavouriteProperty.__table__.create(lab['db'],checkfirst=True)
                    cfg = Path(os.environ['M2_BCB_PRIVATE_CLUSTER'])/'owner-browser.json'
                    try:
                        cfg.write_text(json.dumps(dict(base=lab['base'],token=lab['token'](lab['other']),
                            ownerReview=True,decision=decision,output=os.environ['M2_BCB_EVIDENCE'])))
                        subprocess.run(['node',str(Path(__file__).resolve().parents[3]/'fyp_jaspr_web/tool/part_two_live_http.cjs'),
                                        str(cfg)],check=True,timeout=95)
                    finally:
                        cfg.unlink(missing_ok=True)
                    assigned=lab['request']('GET','/candidate-review-assignments',uid=lab['other']).json()['assignments']
                    review={**next(x for x in assigned if x['id']==version_id)}
                else:
                    review = lab['request']('POST',url,201,uid=lab['other'],json=decision).json()
                if saved is objective and os.environ.get('V14_PREVIEW') == '1':
                    from v14_preview_fixture import reviewed_current_source
                    with lab['db'].connect() as check:
                        assert not reviewed_current_source(check,mid,version_id,revision)
                if os.environ.get('V14_PREVIEW') == '1' and saved is bdj_objective:
                    from v14_preview_fixture import exercise
                    exercise(lab, helpers, cq, other_mid, version_id, revision)
                assert review['rationale'] == decision['rationale'] and review['decision'] == decision['decision']
                if 'fielding_authorized' in review:
                    assert not review['scientific_acceptance'] and not review['fielding_authorized']
                lab['request']('POST',url,404,uid=lab['other'],json=decision)
        assert result['qj']['route'] == 'HOLD' and result['bank'] == 'not_checked'
        assert result['qg'] is None
    if os.environ.get('RESEARCH_BROWSER') == '1':
        import subprocess
        for label in ('Browser missing detail','Browser proposed exploration'):
            pending = lab['request']('POST',path,201,json={**intent,'objective':label}).json()
            synthetic_hold(pending['id'])
        config = Path(os.environ['M2_BCB_PRIVATE_CLUSTER'])/'research-browser.json'
        try:
            config.write_text(json.dumps(dict(base=lab['base'],token=lab['token'](lab['actor']),
                assessment=mid,confirmation=confirmed['id'],researchReview=True,output=os.environ['M2_BCB_EVIDENCE'])))
            subprocess.run(['node',str(Path(__file__).resolve().parents[3]/'fyp_jaspr_web/tool/part_two_live_http.cjs'),
                            str(config)],check=True,timeout=110)
        finally:
            config.unlink(missing_ok=True)
    assert observed == ['ENTREPRENEUR','ENTREPRENEUR','BDJ']
    description = packet['business_description']
    assert description['source_question_ids'] == [f'M2V1-{n:02}' for n in (2,3,4,5,6)]
    assert 'coffee' in description['text'].lower()
    assert 'student' in description['text'].lower()
    assert 'Synthetic independently bound concept' not in description['text']
    overview_url=f'/assessments/{mid}/workflow-overview'
    overview=lab['request']('GET',overview_url).json()
    history=overview_url+'?sequence='+str(overview['projection_sequence'])
    assert overview['is_current'] and overview['assessment_revision']==9
    assert len(overview['projection_data']['objectives'])>=3
    assert any(c['owner_decision']=='REJECT' for c in overview['projection_data']['candidates'])
    assert overview['projection_data']['scientific_review']=='NOT_VERIFIED'
    lab['request']('GET',overview_url,404,uid=lab['other'])
    with lab['db'].begin() as connection:
        connection.execute(text('SELECT refresh_m2_workflow(:id)'),{'id':UUID(mid)})
        metrics={}
        for label,query in [('accumulated','SELECT projection_data FROM assessment_workflow_projection WHERE assessment_id=:id ORDER BY projection_sequence DESC LIMIT 1'),
                            ('direct','SELECT summary FROM m2_workflow_summary WHERE assessment_id=:id')]:
            metrics[label]=connection.scalar(text('EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) '+query),{'id':UUID(mid)})
        metrics['idempotent_refresh']=connection.scalar(text('EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT refresh_m2_workflow(:id)'),{'id':UUID(mid)})
        metrics['storage_bytes']=connection.scalar(text('SELECT sum(pg_column_size(p)) FROM assessment_workflow_projection p WHERE assessment_id=:id'),{'id':UUID(mid)})
        Path(os.environ['M2_BCB_EVIDENCE'],'projection_performance.json').write_text(json.dumps(metrics))
    assert lab['request']('GET',overview_url).json()==overview
    save(lab,mid,'M2V1-03',['BAKED_GOODS'],9)
    d=lab['request']('GET',f'/assessments/{mid}').json()
    lab['request']('GET', f"/research-objectives/{objective['id']}/qj-context?expected_revision=9", 404)
    assert lab['request']('GET',history).json()=={**overview,'is_current':False}
    assert lab['request']('GET',overview_url).json()['assessment_revision']==10
    assert d['current_confirmation_valid'] is False
    save(lab,mid,'M2V1-09',['NONE'],10)
    # Former decision stays in revision history; it is no longer applicable.
    lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',json={'expected_revision':11})
    lab['request']('POST',f'/assessments/{mid}/review',json={'expected_revision':11})
    inactive=lab['request']('POST',f'/assessments/{mid}/confirm',json={'expected_revision':11,'acknowledged_issue_ids':[]}).json()
    assert 'M2V1-11' in inactive['snapshot_json']['inactive_answer_keys']
    Path(os.environ['M2_BCB_EVIDENCE'],'adopted_source_readback.json').write_text(json.dumps({
        'environment':'DISPOSABLE_POSTGRESQL','assessment_id':mid,'saved_revisions':[dict(r) for r in rows],
        'confirmation':confirmed,'current_confirmation_invalid_after_edit':True},indent=2,default=str),encoding='utf-8')


def test_projection_atomic_rollback_and_concurrent_rebuild(lab):
    from concurrent.futures import ThreadPoolExecutor

    mid = create(lab)
    url = f'/assessments/{mid}/workflow-overview'
    initial = lab['request']('GET', url).json()
    with lab['db'].connect() as connection:
        transaction = connection.begin()
        connection.execute(text('UPDATE m2_assessments SET revision=revision+1 WHERE id=:id'), {'id': mid})
        connection.execute(text('SET CONSTRAINTS refresh_workflow IMMEDIATE'))
        assert lab['request']('GET', url).json() == initial
        transaction.rollback()
    assert lab['request']('GET', url).json() == initial

    def rebuild(_):
        with lab['db'].begin() as connection:
            connection.execute(text('SELECT refresh_m2_workflow(:id)'), {'id': mid})

    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(rebuild, range(8)))
    assert lab['request']('GET', url).json() == initial
    # Simulate deployment before projection installation in this disposable cluster.
    with lab['db'].begin() as connection:
        connection.execute(text('ALTER TABLE assessment_workflow_projection RENAME TO test_hidden_projection'))
    try:
        lab['request']('GET', url, 503)
        assert 'assignments' in lab['request']('GET','/candidate-review-assignments',uid=lab['other']).json()
    finally:
        with lab['db'].begin() as connection:
            connection.execute(text('ALTER TABLE test_hidden_projection RENAME TO assessment_workflow_projection'))
def test_current_instrument_release_preview(lab):
    """A new current-instrument candidate, with independent test-only version grants."""
    if os.environ.get('V14_CURRENT') != '1':
        pytest.skip('Explicit isolated V1.4 customer preview only.')
    import importlib.util
    import httpx
    from types import SimpleNamespace
    from sqlalchemy.orm import Session
    from test_postgres_api import bind, build
    from sitewise.project1.research import ResearchWorkflow
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    from sitewise.services.confirmation_service import ConfirmationService
    from v14_preview_fixture import exercise
    mid=create(lab)
    values={'M2V1-01':'UNDECIDED','M2V1-02':'DINE_IN','M2V1-03':['COFFEE'],
            'M2V1-04':['STUDENTS'],'M2V1-06':'QUALITY','M2V1-08':['NONE'],
            'M2V1-09':['CONCEPT_INTEREST'],'M2V1-11':'EXPLORE'}
    for n,(key,value) in enumerate(values.items()):
        save(lab,mid,key,value,n)
    revision=len(values)
    body={'expected_revision':revision}
    for action in ['bdj/evaluate','review']:
        lab['request']('POST',f'/assessments/{mid}/{action}',json=body)
    confirmation=lab['request']('POST',f'/assessments/{mid}/confirm',json={**body,'acknowledged_issue_ids':[]}).json()
    objective=lab['request']('POST',f"/confirmations/{confirmation['id']}/research-objectives",201,
        json={**body,'origin':'ENTREPRENEUR','objective':'Measure stated interest in the proposed coffee category.'}).json()
    bind(lab,mid,confirmation['id'],objective['id'],test_concept='Isolated current-instrument context binding')
    packet=build(lab,mid,confirmation['id'],revision=revision).json()['packet']
    measurement=dict(uncertainty_version=objective['id'],construct='stated interest',population='adult respondents',
        timeframe='this month',stimulus='Proposed coffee category',response_options=['Interested','Unsure'],
        response_codes=['I','U'],routing={'I':'END','U':'END'},denominator='valid respondents',
        source_refs=[objective['id']],limitations='Isolated technical fixture.')
    bank=dict(outcome='verified_equivalent',item_version='SYN-V14-COFFEE-1',approval_receipt='TEST-ONLY-V14')
    authority=SimpleNamespace(admit_qj=lambda _:dict(uncertainty_version=objective['id']),require_current=lambda *_:None,
                              validate_measurement=lambda *_:None)
    def replay(stage,*_):
        assert stage=='QJ'
        return dict(route='CUSTOMER_SURVEY_CANDIDATE',justification='Controlled V1.4 replay',measurement=measurement)
    workflow=ResearchWorkflow(SimpleNamespace(get_context=lambda _:packet),authority,
        SimpleNamespace(lookup=lambda *_:bank,verify_receipt=lambda *_:None),replay)
    with Session(lab['db']) as db:
        version=workflow.execute_objective(None,UUID(objective['id']),lab['actor'],revision,
            ConfirmationService(SqlModelM2Repository(db)),candidate_policy=lambda *_:dict(
                question='How interested are you in this coffee category?',source_version=bank['item_version'],
                match_classification='TEST_ONLY',source_receipt=bank['approval_receipt'],
                options=[dict(code='I',label='Interested',eligible=True),dict(code='U',label='Unsure',eligible=False)]))['candidate_version']
    with lab['db'].begin() as db:
        db.execute(text('INSERT INTO m2_candidate_review_assignments VALUES (:v,:r,:ref)'),
                   dict(v=version,r=lab['other'],ref='TEST-ONLY-V14'))
        db.execute(text('CREATE TABLE IF NOT EXISTS test_cq_authority(release_id uuid PRIMARY KEY,enabled boolean NOT NULL)'))
    import subprocess
    from sitewise.db.models.favourite_property import FavouriteProperty
    FavouriteProperty.__table__.create(lab['db'],checkfirst=True)
    cfg=Path(os.environ['M2_BCB_PRIVATE_CLUSTER'])/'v14-browser.json'
    try:
        for actor,props in [(lab['actor'],dict(previewObjective=True,assessment=mid,confirmation=confirmation['id'],
                              revision=revision,objective=objective['exact_text'])),
                            (lab['other'],dict(ownerReview=True,decision=dict(decision='APPROVE_FOR_REVIEW',
                              rationale='Continue isolated mechanical review.')))]:
            cfg.write_text(json.dumps(dict(base=lab['base'],token=lab['token'](actor),
                output=os.environ['M2_BCB_EVIDENCE'],**props)))
            subprocess.run(['node',str(Path(__file__).resolve().parents[3]/'fyp_jaspr_web/tool/part_two_live_http.cjs'),
                            str(cfg)],check=True,timeout=95)
    finally:
        cfg.unlink(missing_ok=True)
    spec=importlib.util.spec_from_file_location('v14_cq_helpers',Path(__file__).parents[1]/'cq_runtime/test_postgres_api.py')
    helpers=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helpers)
    def cq(method,path,actor,**kwargs):
        response=httpx.request(method,lab['base']+'/api/v1/cq'+path,
            headers={'Authorization':'Bearer '+lab['token'](actor)},**kwargs)
        response.raise_for_status()
        return response.json()
    exercise(lab,helpers,cq,mid,version,revision)
