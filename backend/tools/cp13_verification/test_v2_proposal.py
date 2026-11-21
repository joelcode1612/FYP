"""New proposed observations conform to D02; nothing here adopts a ruleset."""
from copy import deepcopy
import pytest
import bootstrap
from sitewise.project1.contracts import digest,WorkflowHeld,BDJOutput
from sitewise.project1.bdj import RULE_MODULES,load_rules,validate_candidates
from v2 import bdj_m2v1_information_gap_proposal as proposal

def packet(values):
    p=dict(schema_version='project1-m2-projection/1-candidate',assessment_id='TEST-ONLY',assessment_revision=11,
        instrument_version='M2V1-20261114-1',confirmed=True,
        declarations=[dict(item_key=k,answer_state='ANSWERED',value=v,item_version_id=k+'-version',
            answer_revision_id=k+'-answer',answer_revision=11) for k,v in values.items()])
    return {**p,'source_fingerprint':digest(p)}

@pytest.mark.parametrize('values',[
 {'M2V1-02':'DELIVERY','M2V1-07':'STUDY_WORK'},
 {'M2V1-02':'TAKEAWAY','M2V1-07':'STUDY_WORK'},
 {'M2V1-02':'DELIVERY','M2V1-07':'SOCIAL'},
 {'M2V1-03':['UNDECIDED'],'M2V1-06':'QUALITY'},
 {'M2V1-04':['UNDECIDED'],'M2V1-09':['SEGMENT_INTEREST']},
])
def test_no_retired_contradiction_is_resurrected(values):
    p=packet(values);result=proposal.propose(p)
    assert all(x['kind']=='INFORMATION_GAP' for x in result['issues'])
    assert all(len(x['source_refs'])==1 for x in result['issues'])
    assert all(x['rule_id'] in {r['rule_id'] for r in proposal.RULE_CATALOGUE} for x in result['issues'])

def test_unknown_observations_are_exact_source_bound_and_not_fact_changes():
    p=packet({'M2V1-02':'UNDECIDED','M2V1-08':['UNKNOWN'],'M2V1-11':'UNSURE'})
    before=deepcopy(p);result=proposal.propose(p)
    assert len(result['issues'])==3 and p==before
    assert BDJOutput.model_validate(result)
    validate_candidates(result,p,{r['rule_id'] for r in proposal.RULE_CATALOGUE})
    adapter=proposal.evaluate_candidate_issues({d['item_key']:{'id':d['answer_revision_id'],
        'answer_state':d['answer_state'],'value_json':d['value']} for d in p['declarations']})
    assert len(adapter)==3 and all(x['issue_type']=='INFORMATION_GAP' for x in adapter)

def test_none_optional_absence_and_planning_choices_are_not_defects():
    assert proposal.propose(packet({'M2V1-08':['NONE'],'M2V1-09':['NONE'],'M2V1-07':'UNDECIDED'}))['issues']==[]

def test_no_registration_adoption_or_retired_activation():
    assert proposal.ADOPTED is False and proposal.STATUS=='PROPOSED_NOT_ADOPTED'
    for version in (proposal.RULE_VERSION,'BDJ-M2V1-0.1-CAND','BDJ-RULESET-0.3-M2V1-CAND'):
        assert version not in RULE_MODULES
        with pytest.raises(WorkflowHeld,match='BDJ_RULE_ADOPTION_REQUIRED'):load_rules(version,'0'*64,'NOT-AN-APPROVAL')

def test_unconfirmed_or_tampered_sources_are_refused():
    p=packet({'M2V1-02':'UNDECIDED'});p['confirmed']=False;p['source_fingerprint']=digest({k:v for k,v in p.items() if k!='source_fingerprint'})
    with pytest.raises(WorkflowHeld,match='BDJ_CONFIRMED_DECLARATIONS_REQUIRED'):proposal.propose(p)
    p=packet({'M2V1-02':'UNDECIDED'});p['declarations'][0]['value']='DINE_IN'
    with pytest.raises(Exception,match='fingerprint'):proposal.propose(p)
