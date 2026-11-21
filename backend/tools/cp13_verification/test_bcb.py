"""Actual deterministic builder with explicitly synthetic, read-only ports."""
from copy import deepcopy
import pytest
import bootstrap
from harness import fixture,run_bcb,rebind
from sitewise.services.business_context_v1 import ContextRefused,source_hash

def test_context_is_deterministic_source_bound_and_does_not_mutate_answers():
    f=fixture();before=deepcopy(f)
    a=run_bcb(f);b=run_bcb(f)
    assert a==b and f==before
    assert a['geography'] is None
    assert a['packet_hash']==source_hash({k:v for k,v in a.items() if k!='packet_hash'})
    assert {x['answer_revision_id'] for x in a['m2_answers']}=={x['id'] for x in f['answers'].values()}
    assert a['business_description']['value']==f['answers']['M2-04']['value_json']
    assert all(v is False for v in a['permissions'].values())

@pytest.mark.parametrize('case,code',[('insufficient','MANDATORY_CONTEXT_MISSING')])
def test_missing_required_information_is_not_invented(case,code):
    with pytest.raises(ContextRefused,match=code):run_bcb(fixture(case))

def test_confirmation_required_but_not_before_answering():
    f=fixture();f['assessment']['confirmed_revision']=None
    with pytest.raises(ContextRefused,match='M2_CONFIRMATION_STALE'):run_bcb(f)

def test_confirmation_tampering_and_cross_owner_access_are_refused():
    f=fixture();f['answers']['M2-04']['value_json']='changed without new confirmation'
    with pytest.raises(ContextRefused,match='M2_ANSWERS_CHANGED'):run_bcb(f)
    f=fixture();f['decision']['allowed']=False
    with pytest.raises(ContextRefused,match='ACCESS_DENIED'):run_bcb(f)

def test_no_research_uncertainty_is_inferred():
    f=fixture();f['bindings']['uncertainty']=None
    assert run_bcb(f)['confirmed_uncertainty'] is None

def test_changed_source_requires_new_confirmation_and_changes_provenance():
    f=fixture();a=run_bcb(f)
    f['answers']['M2-04']['value_json']+=' Exact fixture correction.';rebind(f)
    b=run_bcb(f)
    assert a['packet_hash']!=b['packet_hash']

@pytest.mark.parametrize('case',['confirmed-objective','clarify-objective','separate-concern'])
def test_existing_confirmation_objective_operations(case):
    from objective_fixture import objective_actions
    from harness import CASES
    assert objective_actions(case,CASES[case])['status']=='PASS'

def test_clarification_without_existing_limitation_is_refused():
    from objective_fixture import ObjectiveRepository
    from sitewise.services.confirmation_service import ConfirmationService
    from sitewise.core.exceptions import ConflictError
    from uuid import UUID
    r=ObjectiveRepository('complete');s=ConfirmationService(r)
    actor=UUID(r.f['assessment']['owner_user_id']);revision=r.f['assessment']['revision']
    parent=s.confirm_objective(UUID(r.f['confirmation']['id']),actor,revision,'Synthetic concern','ENTREPRENEUR',None)
    with pytest.raises(ConflictError,match='Current unresolved research limitation required'):
        s.revise_objective(UUID(parent['id']),actor,revision,'CLARIFY','Synthetic detail')
    assert len(r.rows)==1 and r.rollbacks==1
