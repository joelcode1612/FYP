from uuid import uuid4
from sqlalchemy import text
from test_postgres_api import session,post,respond

def test_CQ23_pause_resume_same_session_idempotency_and_storage(lab):
    s=respond(lab,session(lab,'C0'),['LIVE']);sid=s['session_id'];request={'request_id':str(uuid4())}
    paused=post(lab,s,'pause',request)
    assert paused['status']=='PAUSED' and paused['next_slot_id'] is None and not paused['can_submit']
    assert post(lab,s,'pause',request)==paused
    assert lab['request']('GET','/sessions/'+sid)==paused
    with lab['db'].connect() as c:
        assert c.scalar(text('SELECT state FROM cq_sessions WHERE id=:id'),{'id':sid})=='ACTIVE'
        assert c.scalar(text('SELECT count(*) FROM cq_lifecycle_events WHERE session_id=:id'),{'id':sid})==1
        assert c.scalar(text('SELECT count(*) FROM cq_answer_revisions WHERE session_id=:id'),{'id':sid})==1
    post(lab,paused,'presentations',{},409)
    lab['request']('POST','/sessions/'+sid+'/resume',404,uid=lab['other'],json={
        'expected_revision':paused['revision'],'manifest_hash':paused['manifest_hash'],'request_id':str(uuid4())})
    resumed=post(lab,paused,'resume',{'request_id':str(uuid4())})
    assert resumed['session_id']==sid and resumed['status']=='ACTIVE' and resumed['next_slot_id']=='Q02'
    post(lab,s,'resume',{'request_id':str(uuid4())},409)
    resumed=respond(lab,resumed,'NONE');resumed=respond(lab,resumed,'ZERO')
    submitted=post(lab,resumed,'submit',{'request_id':str(uuid4())})
    post(lab,submitted,'pause',{'request_id':str(uuid4())},409)
    lab['readbacks'].append({'test':'PERSISTED-PAUSE','session_id':sid,
        'pause_revision':paused['revision'],'resume_revision':paused['revision']+1,'source_answers_retained':True})

def test_CQ24_pause_write_failure_rolls_back_and_withdraw_is_available(lab,monkeypatch):
    from sitewise.repositories.cq_repository import CqUnit
    s=session(lab,'C0');original=CqUnit.insert_lifecycle
    def failure(self,**row):original(self,**row);self.session.execute(text('SELECT 1/0'))
    monkeypatch.setattr(CqUnit,'insert_lifecycle',failure)
    post(lab,s,'pause',{'request_id':str(uuid4())},503)
    current=lab['request']('GET','/sessions/'+s['session_id'])
    assert current['revision']==s['revision'] and current['status']=='ACTIVE'
    monkeypatch.setattr(CqUnit,'insert_lifecycle',original)
    paused=post(lab,s,'pause',{'request_id':str(uuid4())})
    assert post(lab,paused,'withdraw',{'request_id':str(uuid4())})['status']=='WITHDRAWN'

def test_CQ25_render_ack_not_prepared_delivery_and_invalid_audit(lab):
    s=session(lab,'C0');p=post(lab,s,'presentations');sid=s['session_id']
    with lab['db'].connect() as c:
        assert c.scalar(text('SELECT count(*) FROM cq_render_events WHERE session_id=:id'),{'id':sid})==0
    rendered=post(lab,p,'rendered',{'display_id':p['presentation']['display_id']})
    assert rendered['presentation']['rendered'] is True
    assert post(lab,p,'rendered',{'display_id':p['presentation']['display_id']})==rendered
    body={'request_id':str(uuid4()),'display_id':p['presentation']['display_id'],'slot_id':'Q01','value':['UNKNOWN']}
    post(lab,p,'answers',body,422);post(lab,p,'answers',body,422)
    with lab['db'].connect() as c:
        assert c.scalar(text('SELECT count(*) FROM cq_rejected_answer_events WHERE session_id=:id'),{'id':sid})==1
        assert c.scalar(text('SELECT count(*) FROM cq_answer_revisions WHERE session_id=:id'),{'id':sid})==0
    assert respond(lab,p,['LIVE'])['next_slot_id']=='Q02'
