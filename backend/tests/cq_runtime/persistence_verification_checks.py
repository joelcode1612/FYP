"""Fresh-schema verification only. Does not alter candidate questionnaire policy."""
from contextlib import contextmanager
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
from uuid import UUID, uuid4

from sqlalchemy import create_engine,text
from sqlalchemy.engine import make_url
from test_postgres_api import TestOnlyAuthority,session,post,row
from sitewise.services.ports.cq_store_port import CqGrant
from sitewise.services.ee01_service import Ee01Service


@contextmanager
def fixture_authority(lab, eligibility):
    from sitewise.api.v1 import customer_questionnaire as api
    class Authority(TestOnlyAuthority):
        def authorize(self,unit,release,actor_id,operation):
            super().authorize(unit,release,actor_id,operation)
            return CqGrant('ISOLATED_TEST','EXISTING-PRIVATE-FIXTURE-ONLY',False,{
                'source_class':'SYNTHETIC_FIXTURE','research_mode':'CUSTOMER_DEMAND_SURVEY',
                'eligibility':eligibility,'qualification_version':'SYNTHETIC-INDEPENDENT-QUALIFICATION-1',
                'receipt':'OWNER-AUTHORIZED-ISOLATED-ENGINEERING-TEST-NOT-SCIENCE'})
    prior=lab['app'].dependency_overrides.get(api.get_cq_authority)
    lab['app'].dependency_overrides[api.get_cq_authority]=lambda:Authority()
    try:yield
    finally:
        if prior:lab['app'].dependency_overrides[api.get_cq_authority]=prior
        else:lab['app'].dependency_overrides.pop(api.get_cq_authority,None)


def answer_shown(lab,s,value,edit=None):
    p=post(lab,s,'presentations',{'edit_slot_id':edit})
    p=post(lab,p,'rendered',{'display_id':p['presentation']['display_id']})
    return post(lab,p,'answers',{'request_id':str(uuid4()),'display_id':p['presentation']['display_id'],
                                'slot_id':p['presentation']['slot_id'],'value':value})


def finish_applicable(lab,s):
    for _ in range(40):
        while s['next_stimulus_kind']:s=post(lab,s,'stimuli',{'kind':s['next_stimulus_kind']})
        if s['can_submit']:return s
        q=s['next_slot_id'].split(':')[0]
        item=next(qi for qi in s['manifest']['questions'] if qi['id']==q)
        value='ONE' if q=='Q04' else 'NONE' if q=='Q02' else item['validation']['substantive_codes'][0]
        if item['type'].startswith('multi_select'):value=[value]
        s=answer_shown(lab,s,value)
    raise AssertionError('Existing server did not resolve its applicable obligations.')


def read_rows(lab,s):
    with lab['db'].connect() as c:
        campaign=dict(c.execute(text('SELECT * FROM cq_campaigns WHERE id=:id'),{'id':s['campaign_id']}).mappings().one())
        effective=[dict(r) for r in c.execute(text('SELECT e.slot_id,e.state,e.answer_event_id,e.context_digest,a.revision,a.value_json '
            'FROM cq_effective_answers e LEFT JOIN cq_answer_revisions a ON a.id=e.answer_event_id '
            'WHERE e.session_id=:id ORDER BY e.slot_id'),{'id':s['session_id']}).mappings()]
        history=[dict(r) for r in c.execute(text('SELECT * FROM cq_answer_revisions WHERE session_id=:id ORDER BY revision'),{'id':s['session_id']}).mappings()]
        control=dict(c.execute(text('SELECT * FROM cq_session_controls WHERE session_id=:id'),{'id':s['session_id']}).mappings().one())
    return campaign,effective,history,control


def execute_persistence_sql(lab,s,campaign,label):
    u=make_url(os.environ['DATABASE_URL'])
    assert (u.host,u.port,u.database)==('127.0.0.1',55443,'project1_cq_runtime_test')
    env={**os.environ,'PGHOST':u.host,'PGPORT':str(u.port),'PGDATABASE':u.database,
         'PGUSER':u.username,'PGPASSWORD':u.password,'PGOPTIONS':'-c default_transaction_read_only=on'}
    result=subprocess.run([r'C:\Program Files\PostgreSQL\18\bin\psql.exe','-X','-v','ON_ERROR_STOP=1',
        '-v','actor_id='+str(lab['owner']),'-v','assessment_id='+str(campaign['assessment_id']),
        '-v','campaign_id='+s['campaign_id'],'-v','session_id='+s['session_id'],
        '-f',str(Path(__file__).parent/'VERIFY_CQ_PERSISTENCE.sql')],env=env,capture_output=True,text=True,encoding='utf-8')
    (Path(os.environ['CQ_EVIDENCE'])/('CQ_PERSISTENCE_'+label+'.log')).write_text(result.stdout+result.stderr,encoding='utf-8')
    assert result.returncode==0,result.stderr


def test_VP01_Q01_Q13_revisions_pause_submit_to_saved_EE_context(lab):
    with fixture_authority(lab,'ELIGIBLE'):
        s=session(lab,'C1')
        post(lab,s,'submit',{'request_id':str(uuid4())},409)
        s=answer_shown(lab,s,['LIVE']);assert s['next_slot_id']=='Q02'
        s=finish_applicable(lab,s)
        campaign,effective,history,control=read_rows(lab,s)
        assert len(history)==14 and len(effective)==14
        assert {r['slot_id'].split(':')[0] for r in effective}=={'Q'+str(i).zfill(2) for i in range(1,14)}
        first_q08=row(s,'Q08')['event_id']
        s=answer_shown(lab,s,'ZERO','Q04');assert row(s,'Q08')['state']=='NOT_SHOWN'
        s=answer_shown(lab,s,'ONE','Q04');assert row(s,'Q08')['state']=='PENDING'
        s=finish_applicable(lab,s);assert row(s,'Q08')['event_id']!=first_q08
        s=answer_shown(lab,s,['WORK'],'Q01');assert s['next_slot_id']=='Q02'
        s=finish_applicable(lab,s)
        paused=post(lab,s,'pause',{'request_id':str(uuid4())})
        assert paused['status']=='PAUSED' and not paused['can_submit']
        assert lab['request']('GET','/sessions/'+s['session_id'])['status']=='PAUSED'
        post(lab,paused,'presentations',{},409)
        s=post(lab,paused,'resume',{'request_id':str(uuid4())})
        assert s['session_id']==paused['session_id'] and s['can_submit']
        s=post(lab,s,'submit',{'request_id':str(uuid4())})
        assert s['status']=='SUBMITTED' and s['receipt'] and not s['can_submit']
        campaign,effective,history,control=read_rows(lab,s)
        assert len(history)>14 and len({r['answer_event_id'] for r in effective})==14
        assert len([r for r in history if r['slot_id']=='Q01'])==2
        assert len([r for r in history if r['slot_id']=='Q04'])==4
        assert all(r['state']=='ANSWERED_SUBSTANTIVE' for r in effective)
        engine=create_engine(os.environ['EE01_DATABASE_URL'],hide_parameters=True)
        try:
            service=Ee01Service(engine)
            measurement=service.build_diagnostic(lab['owner'],campaign['assessment_id'],campaign['id'],
                'Q05',datetime.now(timezone.utc),'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC')
            assert (measurement['q'],measurement['s'],measurement['a'],measurement['v'])==(1,1,1,1)
            with lab['db'].connect() as c:
                source=dict(c.execute(text('SELECT * FROM ee01_source_units WHERE snapshot_id=:id'),{'id':measurement['id']}).mappings().one())
            assert str(source['answer_id'])==str(next(r['answer_event_id'] for r in effective if r['slot_id']=='Q05'))
            context=service.report_readback(lab['owner'],campaign['assessment_id'],campaign['id'],UUID(measurement['id']))
            assert context['status']=='REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE' and not context['findings']
            evidence={'campaign':campaign,'session':s,'control':control,'effective':effective,'all_revisions':history,
                      'measurement':measurement,'selected_source':source,'saved_context':context,
                      'ExplanationContextBuilder':'NOT_VERIFIED; saved withheld context is not a completed explanation',
                      'ReportAdmission':'NOT_IMPLEMENTED_OR_AUTHORITY_UNVERIFIED'}
            (Path(os.environ['CQ_EVIDENCE'])/'connected_persistence_lineage.json').write_text(json.dumps(evidence,indent=2,default=str),encoding='utf-8')
            execute_persistence_sql(lab,s,campaign,'Q01_Q13')
        finally:engine.dispose()


def test_VP02_independent_eligibility_vs_area_and_termination_evidence(lab):
    evidence=[]
    cases=[('qualified','ELIGIBLE','LIVE','SHOW_ALL'),
           ('area_outside_but_qualified','ELIGIBLE','NEVER','SHOW_ALL'),
           ('independently_ineligible','INELIGIBLE','LIVE','SHOW_ALL'),
           ('qualification_unresolved','UNRESOLVED','LIVE','SHOW_ALL'),
           ('area_and_Q02_unresolved','UNRESOLVED','NOT_SURE','UNDECIDED')]
    engine=create_engine(os.environ['EE01_DATABASE_URL'],hide_parameters=True)
    try:
        for label,eligibility,q01,q02 in cases:
            with fixture_authority(lab,eligibility):
                s=answer_shown(lab,session(lab,'C0',q02=q02),[q01])
                s=finish_applicable(lab,s)
                s=post(lab,s,'submit',{'request_id':str(uuid4())})
                campaign,effective,history,control=read_rows(lab,s)
                measurement=Ee01Service(engine).build_diagnostic(lab['owner'],campaign['assessment_id'],campaign['id'],
                    'Q02',datetime.now(timezone.utc),'CUST03_CURRENT_ATTEMPT_DIAGNOSTIC')
                assert measurement['q']==(1 if eligibility=='ELIGIBLE' else 0)
                record={'case':label,'independent_eligibility':eligibility,'Q01':q01,'Q02_policy':q02,
                        'actual_API_status':s['status'],'actual_receipt_disposition':s['receipt']['disposition'],
                        'session_id':s['session_id'],'campaign':campaign,'routing':s['routing'],
                        'effective':effective,'measurement':measurement,
                        'SCREENED_OUT_API_state_observed':s['status']=='SCREENED_OUT'}
                evidence.append(record);execute_persistence_sql(lab,s,campaign,label)
        out=Path(os.environ['CQ_EVIDENCE'])
        (out/'respondent_classification.json').write_text(json.dumps(evidence,indent=2,default=str),encoding='utf-8')
        constraints=[]
        with lab['db'].connect() as c:
            constraints=[r[0] for r in c.execute(text("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='cq_sessions'::regclass AND contype='c'"))]
        (out/'classification_contract_gaps.json').write_text(json.dumps({
            'physical_session_checks':constraints,'findings':[
                {'requirement':'COMPLETED semantic/contract mapping','actual':'SUBMITTED + immutable receipt; no COMPLETED wire state',
                 'result':'REQUIREMENTS_GAP','semantic_answer_completion_verified':True},
                {'requirement':'Independent SCREENED_OUT termination','actual':'Independently INELIGIBLE fixture can submit with area disposition ELIGIBLE; EE excludes it',
                 'result':'IMPLEMENTATION_GAP','approved_screening_predicate_verified':False},
                {'requirement':'Unresolved qualification/route disposition','actual':'Source remains UNRESOLVED and excluded by EE; submission can still be SUBMITTED',
                 'result':'REQUIREMENTS_GAP'},
                {'requirement':'Actual Explanation Context Builder and ReportAdmission','actual':'Only immutable withheld context/readback exists',
                 'result':'IMPLEMENTATION_GAP_OR_AUTHORITY_UNVERIFIED'}]},indent=2),encoding='utf-8')
    finally:engine.dispose()
