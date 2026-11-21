"""Prepare NEW synthetic current-instrument source in the existing private lab.

No original Dss, cloud flags, provider budget or approval file is written.
"""
import json
import os
from pathlib import Path
import sys
from uuid import UUID
import pytest

if not os.environ.get('M2_BCB_PRIVATE_CLUSTER'):
    pytest.skip('Use run_isolated.py --suite cp13-v2-prep',allow_module_level=True)
BACKEND=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(BACKEND/'tests/m2_bcb'))
from test_postgres_api import lab
from scripts.register_m2_v1 import register
from sqlalchemy import text
from sitewise.project1.contracts import digest
from sitewise.project1.disclosure import validate_synthetic
from sitewise.project1.contracts import WorkflowHeld

VALUES={
    'M2V1-01':'UNDECIDED','M2V1-02':'DINE_IN','M2V1-03':['COFFEE'],
    'M2V1-04':['STUDENTS','RESIDENTS'],'M2V1-05':'STUDENTS',
    'M2V1-06':'CONVENIENCE','M2V1-07':'QUICK_PURCHASE','M2V1-08':['UNKNOWN'],
    'M2V1-09':['CONCEPT_INTEREST','PRODUCT_PREFERENCE'],'M2V1-10':'CONCEPT_INTEREST',
    'M2V1-11':'UNSURE'}

def test_new_confirmed_current_instrument_synthetic_source_and_authorization_proposal(lab):
    from sitewise.core.config import settings
    assert not settings.tokenharbor_enabled and not settings.project1_workflow_enabled
    assert lab['db'].url.port==55441 and lab['db'].url.database=='project1_m2_bcb_test'
    iid=register(lab['db'],apply=True,expected_database='project1_m2_bcb_test')['instrument_id']
    mid=lab['request']('POST','/assessments',201,json={'instrument_version_id':iid}).json()['id']
    assert mid not in {'b28cd847-89f6-4994-adad-f79846f77c2e','7a2f0b5c-6e75-4aa0-934b-a529681b20ac','b438c959-dbb4-4f99-8322-0f841dbba755'}
    for rev,(key,value) in enumerate(VALUES.items()):
        lab['request']('PUT',f'/assessments/{mid}/answers/{key}',json={
            'expected_revision':rev,'answer_state':'ANSWERED','value':value})
    # Existing deterministic pre-confirmation validation is retained. This is
    # NOT a cloud-BDJ execution and does not resurrect a retired rule catalogue.
    worksheet=lab['request']('POST',f'/assessments/{mid}/bdj/evaluate',json={'expected_revision':11}).json()
    assert worksheet['findings']==[]
    lab['request']('POST',f'/assessments/{mid}/review',json={'expected_revision':11})
    confirmation=lab['request']('POST',f'/assessments/{mid}/confirm',json={
        'expected_revision':11,'acknowledged_issue_ids':[]}).json()
    cid=confirmation['id']
    objective=lab['request']('POST',f'/confirmations/{cid}/research-objectives',201,json={
        'expected_revision':11,'origin':'ENTREPRENEUR',
        'objective':'SYNTHETIC TEST ONLY: Explore stated interest in the declared cafe concept.'}).json()
    endpoint=f'/assessments/{mid}/source-projection?expected_revision=11'
    packet=lab['request']('GET',endpoint).json()
    assert packet['confirmed'] is True and packet['assessment_revision']==11
    assert packet['source_fingerprint']==digest({k:v for k,v in packet.items() if k!='source_fingerprint'})
    lab['request']('GET',endpoint,404,uid=lab['other'])
    lab['request']('GET',endpoint,401,uid=None)
    lab['request']('GET',f'/assessments/{mid}/source-projection?expected_revision=10',409)
    with lab['db'].connect() as c:
        record=c.execute(text('SELECT id::text,owner_user_id::text,revision,confirmed_revision FROM public.m2_assessments WHERE id=:id'),{'id':UUID(mid)}).mappings().one()
        answers=c.execute(text('SELECT r.id::text,i.item_key,r.assessment_revision,r.answer_state,r.value_json FROM public.m2_answer_revisions r JOIN public.m2_item_versions i ON i.id=r.item_version_id WHERE r.assessment_id=:id ORDER BY r.assessment_revision'),{'id':UUID(mid)}).mappings().all()
        assert record['owner_user_id']==str(lab['actor']) and record['revision']==record['confirmed_revision']==11
        assert {x['item_key']:x['value_json'] for x in answers}==VALUES
    # Prepare a proposed disclosure carrier ONLY for this newly-created
    # nonhuman source. No existing entrepreneur record is relabeled, and no
    # adoption/operator receipt is minted or passed to a provider.
    disclosure={k:v for k,v in packet.items() if k!='source_fingerprint'}
    disclosure.update(data_class='SYNTHETIC_NONHUMAN',purpose='SYNTHETIC_BDJ_DIAGNOSTIC')
    disclosure['source_fingerprint']=digest(disclosure)
    with pytest.raises(WorkflowHeld,match='DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'):
        validate_synthetic(data_class=packet.get('data_class'),purpose='SYNTHETIC_BDJ_DIAGNOSTIC',stage='BDJ',
            endpoint='https://tokenharbor.ai/v1/chat/completions',model='mimo-v2.6-flash:free',max_attempts=1,
            operator_receipt=None,source_fingerprint=packet['source_fingerprint'],packet=packet)
    evidence=dict(status='PREPARED_NOT_CLOUD_AUTHORIZED',mode='LIVE_LOCAL_HTTP_POSTGRES',cloud_calls=0,
        data_origin='New private-cluster synthetic fixture created by this test; no ordinary entrepreneur source copied.',
        database=dict(host='127.0.0.1',port=55441,name='project1_m2_bcb_test',
            private_cluster=os.environ['M2_BCB_PRIVATE_CLUSTER']),
        actor_id=str(lab['actor']),tenant_binding='m2-owner:'+str(lab['actor']),
        assessment=dict(record),confirmation=confirmation,objective=objective,
        input_values=VALUES,sql_answer_readback=[dict(x) for x in answers],
        projection=packet,proposed_disclosure_packet=disclosure,
        pending=['Owner approval of proposed ruleset','Explicit test-only validity policy','Exact source disclosure approval',
                 'Compatible candidate-only cloud-BDJ to BCB provenance admission'],
        adoption_receipt_created=False,existing_authorization_overwritten=False,
        test_policy_note='Existing lab 90-day setting was not used to build a BCB for this case; no product policy is adopted.')
    Path(os.environ['M2_BCB_EVIDENCE'],'synthetic_source_proposal.json').write_text(json.dumps(evidence,indent=2,default=str)+'\n',encoding='utf-8')
