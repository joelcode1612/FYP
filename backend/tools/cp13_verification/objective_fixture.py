"""In-memory repository port for the real ConfirmationService, TEST ONLY.

No research engine is called. Existing legacy-named context reader is reused
inside ConfirmationService; it is a DB reader, not a retired stage dispatch.
"""
from copy import deepcopy
from uuid import UUID,uuid5,NAMESPACE_URL
from harness import fixture
from sitewise.services.confirmation_service import ConfirmationService

class ObjectiveRepository:
    def __init__(self,case):
        self.f=fixture(case);self.rows={};self.sources={};self.links=[];self.commits=0;self.rollbacks=0
        snap=self.f['confirmation']['snapshot_json']
        snap.update(instrument_version='M2V1-20261114-1',inactive_answer_keys=[],derived_selections=[])
        snap['answer_revisions']=[dict(item_key=k,answer_state='ANSWERED',value=v) for k,v in
            [('M2V1-09',['CONCEPT_INTEREST']),('M2V1-10','CONCEPT_INTEREST'),('M2V1-11','EXPLORE')]]
        self.limitations={}
    def get_confirmation(self,id,actor):
        return deepcopy(self.f['confirmation']) if str(id)==self.f['confirmation']['id'] and str(actor)==self.f['assessment']['owner_user_id'] else None
    def get_assessment_for_update(self,id,actor):
        return deepcopy(self.f['assessment']) if str(actor)==self.f['assessment']['owner_user_id'] else None
    def create_uncertainty(self,confirmation_id,actor,text):
        id=str(uuid5(NAMESPACE_URL,'CP13/objective/'+str(len(self.rows))+'/'+text))
        row=dict(id=id,confirmation_id=str(confirmation_id),actor_user_id=str(actor),exact_text=text)
        self.rows[id]=row;return deepcopy(row)
    def save_objective_source(self,id,source):self.sources[str(id)]=deepcopy(source)
    def read_current_objective(self,id,actor,revision):
        row=self.rows.get(str(id))
        if row and str(actor)==self.f['assessment']['owner_user_id'] and revision==self.f['assessment']['revision']:
            return {**deepcopy(row),'provenance':deepcopy(self.sources[str(id)])}
    def objective_limitation(self,id):return deepcopy(self.limitations.get(str(id)))
    def link_objective_revision(self,parent,child,action):
        self.links.append(dict(parent_id=str(parent),child_id=str(child),action=action))
        self.limitations[str(parent)]['child_id']=str(child)
    def commit(self):self.commits+=1
    def rollback(self):self.rollbacks+=1

def objective_actions(case,spec):
    repo=ObjectiveRepository(case);service=ConfirmationService(repo)
    actor=UUID(repo.f['assessment']['owner_user_id']);confirmation=UUID(repo.f['confirmation']['id'])
    revision=repo.f['assessment']['revision']
    parent=service.confirm_objective(confirmation,actor,revision,spec.get('objective',repo.f['bindings']['uncertainty']['exact_text']),'ENTREPRENEUR',None)
    output=dict(mode='MOCKED',parent=parent,operation='CONFIRM',repository='in-memory test port; no PostgreSQL persistence claimed')
    if case=='clarify-objective':
        repo.limitations[parent['id']]=dict(child_id=None,limitation='Synthetic missing reference period.',broader_objective=None)
        child=service.revise_objective(UUID(parent['id']),actor,revision,'CLARIFY',spec['clarification'])
        assert child['exact_text']==parent['exact_text']
        assert child['source']['clarification']==spec['clarification']
        assert child['source']['parent_objective_id']==parent['id']
        output.update(operation='CLARIFY',child=child,links=repo.links)
    if case=='separate-concern':
        child=service.confirm_objective(confirmation,actor,revision,spec['separate_objective'],'ENTREPRENEUR',None)
        assert child['id']!=parent['id'] and child['exact_text']!=parent['exact_text']
        assert 'parent_objective_id' not in child['source'] and repo.links==[]
        output.update(operation='SEPARATE_CONCERN',separate_objective=child)
    output['status']='PASS'
    return output
