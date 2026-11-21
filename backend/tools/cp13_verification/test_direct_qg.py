"""Active Direct-QG contract; no QJ, bank invocation or fielding grant."""
from copy import deepcopy
import pytest
import bootstrap
from harness import fixture,run_bcb,run_qg,CASES,draft
from sitewise.project1.qg_contract import facts_from_packet,validate_candidate
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.direct_qg_service import ACTIVE_STAGES

def test_actual_composition_generates_draft_only_against_exact_bcb():
    p=run_bcb(fixture());r,calls=run_qg(p,CASES['complete'])
    assert r['status']=='VALIDATED_OUTPUT'
    assert [x['stage'] for x in calls]==['QG'] and ACTIVE_STAGES==('QG',)
    assert r['composition']['qj_executed'] is False
    assert r['source_fingerprint']==p['packet_hash']
    assert r['qg']['decision']=='DRAFT' and r['candidate_authority']=='ENTREPRENEUR_REVIEW_ONLY'
    for flag in ('fielding_authorized','publication_authorized','scientific_acceptance','report_release_authorized'):
        assert r[flag] is False

def test_disabled_generation_refuses_before_provider_dispatch():
    with pytest.raises(WorkflowHeld,match='DIRECT_QG_NOT_ENABLED') as e:
        run_qg(run_bcb(fixture()),CASES['unauthorized-qg'])
    assert e.value.cp13_calls==[]

def test_invented_price_and_unsupported_claim_cannot_become_candidates():
    p=run_bcb(fixture());f=facts_from_packet(p)
    d=draft(p);d['question']='Would you find a 12 oz takeaway iced latte at RM999 acceptable?'
    with pytest.raises(WorkflowHeld,match='QG_UNSOURCED'):validate_candidate(d,f)
    d=draft(p);d['question']='What is the optimum price?'
    with pytest.raises(WorkflowHeld,match='PROHIBITED_OPTIMUM_PRICE'):validate_candidate(d,f)

def test_missing_offer_allows_only_explicit_justified_abstention():
    p=run_bcb(fixture('typos'));f=facts_from_packet(p)
    r=validate_candidate(dict(decision='ABSTAIN_NEEDS_REVIEW',question='',
        justification='The source does not state a price.',missing_business_facts=['PRICE']),f)
    assert r.decision=='ABSTAIN_NEEDS_REVIEW'

def test_candidate_response_options_routing_and_denominator_are_validated():
    p=run_bcb(fixture());d=draft(p);d['routing']={}
    with pytest.raises(WorkflowHeld,match='QG_ROUTING_DRIFT'):validate_candidate(d,facts_from_packet(p))

def test_packet_tampering_is_blocked_before_provider():
    p=run_bcb(fixture());p['m2_answers'][0]['value']='unconfirmed edit'
    r,calls=run_qg(p,CASES['complete'])
    assert r['status']=='BLOCKED_INPUT' and calls==[]

@pytest.mark.parametrize('fault',['timeout','malformed','schema'])
def test_provider_failure_never_yields_draft_or_retries_unknown_outcome(fault):
    r,calls=run_qg(run_bcb(fixture()),dict(fault=fault))
    assert r['status'] in {'MODEL_FAILURE','BLOCKED_INPUT'} and len(calls)==1
    assert not r.get('qg')
