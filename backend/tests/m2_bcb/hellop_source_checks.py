"""Existing PostgreSQL lab and M2 contracts with supplied, unadopted source."""
import json
import os
from pathlib import Path
import subprocess
from uuid import UUID, uuid4

import pytest
from sqlalchemy import text
from sqlalchemy.engine import make_url

from hellop_fixture import load_hellop, sample_answers, SOURCE_SHA256


def fixture_instrument(lab):
    url = make_url(os.environ['DATABASE_URL'])
    assert (url.host, url.port, url.database) == ('127.0.0.1', 55441, 'project1_m2_bcb_test')
    assert os.environ.get('M2_BCB_PRIVATE_CLUSTER')
    if 'hellop_source' in lab:
        return lab['hellop_source']
    source = load_hellop()
    from sitewise.db.models.m2_schema import instruments, items
    from sitewise.services.business_context_v1 import source_hash
    iid = uuid4()
    version = 'NOT_ADOPTED-HELLOP-' + SOURCE_SHA256[:12] + '-' + iid.hex[:8]
    with lab['db'].begin() as conn:
        conn.execute(instruments.insert().values(id=iid, code='TEST_ONLY', version_tag=version,
            approval_state='DRAFT', schema_digest=source_hash(source)))
        for order, item in enumerate(source['items']):
            allowed = [] if item['answer_kind'] == 'ACTION' else ['ANSWERED',
                'NOT_PROVIDED' if item['requiredness'] == 'REQUIRED' else 'SKIPPED_OPTIONAL']
            conn.execute(items.insert().values(id=uuid4(), instrument_id=iid, item_key=item['item_key'],
                question_text=item['question_text'], requiredness=item['requiredness'], answer_kind=item['answer_kind'],
                option_values=item['options'], allowed_states=allowed, lifecycle=item['lifecycle'], sort_order=order))
    # Confirm the real guard remains closed before simulating the registration
    # state used by the existing synthetic lab. Never change production authority.
    lab['request']('POST', '/assessments', 409, json={'instrument_version_id': str(iid)})
    with lab['db'].begin() as conn:
        conn.execute(instruments.update().where(instruments.c.id == iid).values(approval_state='AUTHORIZED'))
    source.update(instrument_id=str(iid), version=version, backend_url=lab['base'],
        private_execution_registration_state='AUTHORIZED',
        registration_state_note='TEST FIXTURE ONLY: the existing API requires this DB state. It is not an adoption or scientific decision.')
    out = Path(os.environ['M2_BCB_EVIDENCE'])
    (out/'hellop_source_fixture.json').write_text(json.dumps(source,ensure_ascii=False,indent=2),encoding='utf-8')
    lab['hellop_source'] = source
    return source


def test_HELLOP_source_validation_persistence_and_authority_boundary(lab):
    source = fixture_instrument(lab)
    created = lab['request']('POST', '/assessments', 201,
        json={'instrument_version_id': source['instrument_id']}).json()
    mid = created['id']
    assert created['confirmed_revision'] is None and created['revision'] == 0
    catalog = lab['request']('GET', '/instruments/' + source['instrument_id']).json()
    assert len(catalog['items']) == 23
    assert {x['item_key']: x['question_text'] for x in catalog['items']} == {x['item_key']: x['question_text'] for x in source['items']}
    assert {x['item_key']: x['option_values'] for x in catalog['items']} == {x['item_key']: x['options'] for x in source['items']}
    lab['request']('POST', f'/assessments/{mid}/bdj/evaluate', 409, json={'expected_revision': 0})
    invalid = [('M2-01', 'NOT_A_SOURCE_OPTION'), ('M2-02', [source['items'][1]['options'][0]]),
        ('M2-11', 'A. Lower'), ('M2-20', 'A. Confirm reviewed answers'), ('M2-21', 'A. Yes, confirm')]
    for key, value in invalid:
        lab['request']('PUT', f'/assessments/{mid}/answers/{key}', 422,
            json={'expected_revision': 0, 'answer_state': 'ANSWERED', 'value': value})
    answers = sample_answers(source)
    for revision, item in enumerate(answers):
        lab['request']('PUT', f"/assessments/{mid}/answers/{item['item_key']}", json={
            'expected_revision': revision, 'answer_state': item['answer_state'], 'value': item['value']})
    lab['request']('PUT', f'/assessments/{mid}/answers/M2-04', 409,
        json={'expected_revision': 0, 'answer_state': 'ANSWERED', 'value': 'Stale test edit'})
    saved = lab['request']('GET', '/assessments/' + mid).json()
    assert saved['assessment']['revision'] == 20 and saved['assessment']['confirmed_revision'] is None
    assert set(saved['answers']) == {x['item_key'] for x in answers}
    assert saved['answers']['M2-15']['value_json'] is None
    assert saved['answers']['M2-15']['answer_state'] == 'SKIPPED_OPTIONAL'
    with lab['db'].connect() as conn:
        assert conn.execute(text('SELECT count(*) FROM m2_bdj_evaluations WHERE assessment_id=:id'), {'id': mid}).scalar_one() == 0
        assert conn.execute(text('SELECT count(*) FROM m2_confirmation_snapshots WHERE assessment_id=:id'), {'id': mid}).scalar_one() == 0
    worksheet = lab['request']('POST', f'/assessments/{mid}/bdj/evaluate', json={'expected_revision': 20}).json()
    assert worksheet['evaluation_state'] == 'EVALUATED_CANDIDATE'
    assert 'UNSUPPORTED_PROFIT_GUARANTEE' in {f['rule_id'] for f in worksheet['findings']}
    assert worksheet['publication_authorized'] is False and worksheet['qj_handoff_authorized'] is False
    out = Path(os.environ['M2_BCB_EVIDENCE'])
    (out/'hellop_api_readback.json').write_text(json.dumps({'scope': 'TEST_ONLY / NOT_ADOPTED',
        'production_authority': source['production_authority'], 'assessment': saved, 'worksheet': worksheet,
        'input_values': answers, 'prior_confirmation_required': False},ensure_ascii=False,indent=2),encoding='utf-8')


@pytest.mark.parametrize('item_key,indices', [('M2-09', [0,1,2]), ('M2-13', [0,1,2,3]),
    ('M2-16', [0,1]), ('M2-17', [0,6])])
def test_HELLOP_source_conditions_not_silently_claimed_supported(lab,item_key,indices):
    source = fixture_instrument(lab)
    item = next(i for i in source['items'] if i['item_key'] == item_key)
    mid = lab['request']('POST', '/assessments', 201,
        json={'instrument_version_id': source['instrument_id']}).json()['id']
    value = [item['options'][i] for i in indices]
    response = lab['request']('PUT', f'/assessments/{mid}/answers/{item_key}', (200,422),
        json={'expected_revision':0,'answer_state':'ANSWERED','value':value})
    evidence = {'item_key':item_key,'condition_from_source':item['question_text'],
        'submitted_value':value,'expected_for_source_condition':422,'actual_http':response.status_code,
        'classification':'EXISTING_IMPLEMENTATION_GAP' if response.status_code==200 else 'SUPPORTED',
        'production_authority':'M2_INSTRUMENT_AUTHORITY_UNVERIFIED'}
    path=Path(os.environ['M2_BCB_EVIDENCE'])/'source_condition_gaps.ndjson'
    with path.open('a',encoding='utf-8') as f:f.write(json.dumps(evidence,ensure_ascii=False)+'\n')
    if response.status_code == 200:
        pytest.xfail('Source condition not enforced by the existing string-option DTO: '+item_key)


def test_HELLOP_actual_Jaspr_source_form_revision_and_BDJ_handoff(lab):
    if os.environ.get('M2_HELLOP_BROWSER') != '1':
        pytest.skip('Enable explicit isolated supplied-source browser test.')
    source = fixture_instrument(lab)
    from sitewise.db.models.favourite_property import FavouriteProperty
    FavouriteProperty.__table__.create(lab['db'],checkfirst=True)
    root = Path(__file__).resolve().parents[3]
    out = Path(os.environ['M2_BCB_EVIDENCE'])
    cfg = Path(os.environ['M2_BCB_PRIVATE_CLUSTER'])/'hellop_browser_identity.json'
    cfg.write_text(json.dumps({'base':lab['base'],'token':lab['token'](lab['actor']),'assessment':'',
        'createViaUI':True,'startLabel':'Start M2 TEST_ONLY · '+source['version'],
        'hellop':{'source':source,'answers':sample_answers(source)},'output':str(out)}),encoding='utf-8')
    try:
        result=subprocess.run(['node',str(root/'fyp_jaspr_web/tool/part_two_live_http.cjs'),str(cfg)],
            cwd=root,capture_output=True,text=True,encoding='utf-8',timeout=240)
        (out/'hellop_browser_execution.log').write_text(result.stdout+result.stderr,encoding='utf-8')
        assert result.returncode==0,result.stdout+result.stderr
    finally:cfg.unlink(missing_ok=True)
    browser=json.loads((out/'browser_http.json').read_text(encoding='utf-8'))
    mid=browser['created_assessment_id']
    with lab['db'].connect() as conn:
        a=dict(conn.execute(text('SELECT * FROM m2_assessments WHERE id=:id'),{'id':mid}).mappings().one())
        rows=[dict(r) for r in conn.execute(text('SELECT r.id,r.assessment_revision,i.item_key,r.answer_state,r.value_json '
            'FROM m2_answer_revisions r JOIN m2_item_versions i ON r.item_version_id=i.id '
            'WHERE r.assessment_id=:id ORDER BY r.assessment_revision'),{'id':mid}).mappings()]
        snapshots=[dict(r) for r in conn.execute(text('SELECT id,assessment_revision,snapshot_digest,snapshot_json '
            'FROM m2_confirmation_snapshots WHERE assessment_id=:id ORDER BY assessment_revision'),{'id':mid}).mappings()]
        evaluations=list(conn.execute(text('SELECT assessment_revision FROM m2_bdj_evaluations '
            'WHERE assessment_id=:id ORDER BY assessment_revision'),{'id':mid}).scalars())
    assert a['revision']==21 and a['confirmed_revision']==21
    assert len(rows)==21 and len({r['item_key'] for r in rows})==20
    assert evaluations==[20,21] and [s['assessment_revision'] for s in snapshots]==[20,21]
    assert not {'M2-11','M2-20','M2-21'} & {r['item_key'] for r in rows}
    assert next(r for r in rows if r['item_key']=='M2-15')['value_json'] is None
    from sitewise.services.business_context_v1 import source_hash
    assert all(s['snapshot_digest']==source_hash(s['snapshot_json']) for s in snapshots)
    (out/'hellop_browser_sql_readback.json').write_text(json.dumps({'scope':'TEST_ONLY / NOT_ADOPTED',
        'production_authority':'M2_INSTRUMENT_AUTHORITY_UNVERIFIED','database':'project1_m2_bcb_test',
        'backend_url':lab['base'],
        'assessment':a,'answer_revisions':rows,'evaluation_revisions':evaluations,'confirmations':snapshots,
        'source_condition_full_conformance':'NOT_ESTABLISHED_SEE_EXPLICIT_SOURCE_GAPS',
        'primary_group_separately_persisted':False,'other_text_tested':False},indent=2,ensure_ascii=False,default=str),encoding='utf-8')
