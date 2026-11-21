"""Targeted actual HTTP/JWT + private PostgreSQL BCB checks. No cloud/QJ.

Invoke ONLY via the existing run_isolated.py --suite cp13-bcb. The imported
fixture verifies its private data directory and database identity before writes.
"""
import os
import json
import sys
from pathlib import Path
import pytest

if not os.environ.get('M2_BCB_PRIVATE_CLUSTER'):
    pytest.skip('Use tests/m2_bcb/run_isolated.py --suite cp13-bcb',allow_module_level=True)

BACKEND=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(BACKEND/'tests/m2_bcb'))
from test_postgres_api import lab,confirmed,build
from production_binding_checks import production_resolver,rows
from sitewise.services.business_context_v1 import source_hash

def test_actual_bcb_persistence_provenance_and_readback(lab):
    mid,cid,uid=confirmed(lab,'SYNTHETIC CP13: A takeaway-only cafe offering a 12 oz iced latte at RM13.')
    with production_resolver(lab):
        response=build(lab,mid,cid);packet=response.json()['packet']
        replay=build(lab,mid,cid,expected=200).json()
    sql='SELECT context_id::text,assessment_id::text,confirmation_id::text,assessment_revision,packet_hash,snapshot_digest,builder_version,packet_json FROM public.m2_business_contexts WHERE assessment_id=:mid'
    persisted=rows(lab,sql,{'mid':mid})
    assert len(persisted)==1
    row=persisted[0]
    assert row['assessment_id']==mid and row['confirmation_id']==cid and row['assessment_revision']==3
    assert row['packet_hash']==packet['packet_hash']==source_hash({k:v for k,v in packet.items() if k!='packet_hash'})
    assert row['packet_json']==packet and replay['context_id']==row['context_id'] and replay['replayed']
    assert packet['confirmed_uncertainty']['id']==uid
    assert packet['geography'] is None and all(v is False for v in packet['permissions'].values())
    assert packet['confirmation']['status']=='CURRENT_CONFIRMED'
    answer_sql='SELECT id::text,assessment_id::text,item_version_id::text,assessment_revision,answer_state,value_json FROM public.m2_answer_revisions WHERE assessment_id=:mid ORDER BY assessment_revision'
    answers=rows(lab,answer_sql,{'mid':mid})
    assert {x['answer_revision_id'] for x in packet['m2_answers']}=={x['id'] for x in answers}
    # Existing endpoint validates signatures and profiles; cross-owner reads remain denied.
    denied=build(lab,mid,cid,expected=404,uid=lab['other'])
    evidence=dict(status='PASS',mode='LIVE_LOCAL_POSTGRES',cloud_calls=0,
        authority='Synthetic instrument, accounts, JWKS and 90-day validity basis are TEST fixtures; production resolver/builder/store are actual.',
        database='project1_m2_bcb_test',port=55441,assessment_id=mid,confirmation_id=cid,objective_id=uid,
        http_create_status=response.status_code,idempotent_status=200,cross_owner_status=denied.status_code,
        input_revision=3,sql=[dict(query=sql,parameters={'mid':mid},rows=persisted),
                            dict(query=answer_sql,parameters={'mid':mid},rows=answers)],
        bcb=packet,cloud_acceptance='NOT_ESTABLISHED')
    Path(os.environ['M2_BCB_EVIDENCE'],'cp13_bcb_persistence.json').write_text(json.dumps(evidence,indent=2,default=str)+'\n',encoding='utf-8')

# Existing targeted negative checks, with the same actual restricted role and DB.
from production_binding_checks import (
    test_PG46_production_stale_revision_is_refused,
    test_PG48_production_repeated_builds_are_idempotent,
    test_PG50_restricted_principal_other_owner_sees_zero_rows,
    test_PG53_absent_validity_basis_fails_closed,
    test_PG55_confirmation_not_current_is_still_refused,
)
