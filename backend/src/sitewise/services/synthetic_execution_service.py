"""Exact-case delegation to the existing CQ engine, never participant authority.

The HTTP principal is always the real developer. The domain subject is an
operator-created suspended nonhuman fixture; both are recorded separately.
"""
from contextlib import contextmanager
import json
from uuid import uuid4
from sqlalchemy import text,select
from sqlalchemy.orm import Session
from sitewise.domain.cq_runtime import CqRefused
from sitewise.domain.customer_questionnaire import digest
from sitewise.repositories.cq_repository import CqUnit
from sitewise.services.ports.cq_store_port import CqGrant
from sitewise.services.customer_questionnaire_service import CustomerQuestionnaireService
from sitewise.services.synthetic_dss_import import normalized
from sitewise.db.models import cq_runtime_schema as db


def lifecycle(unit,case):
    root=unit.one(db.sessions,[db.sessions.c.id==case['session_id']])
    if root['state']=='WITHDRAWN':return 'WITHDRAWN'
    if case['scenario']=='HYPOTHETICAL_SCREENOUT' and 'Q01' in unit.latest(root['id']):return 'SCREENED_OUT'
    if case['scenario']=='UNRESOLVED':return 'UNRESOLVED'
    if root['state']=='SUBMITTED' and unit.receipt(root['id']):return 'COMPLETED'
    if unit.paused(root['id']):return 'PAUSED'
    return 'IN_PROGRESS'


class ExecutionUnit(CqUnit):
    def __init__(self,session,case,actor,operation,request_hash):
        super().__init__(session)
        self.case,self.actor,self.operation,self.request_hash=case,actor,operation,request_hash

    def commit(self):
        root=self.one(db.sessions,[db.sessions.c.id==self.case['session_id']])
        effective=[dict(r) for r in self.session.execute(select(db.effective).where(
            db.effective.c.session_id==root['id']).order_by(db.effective.c.slot_id)).mappings()]
        image=normalized({'session':root,'effective_answers':effective})
        self.session.execute(text('INSERT INTO cq_synthetic_execution_events(id,run_id,session_id,developer_user_id,operation,request_hash,revision,lifecycle_status,snapshot_json,snapshot_sha256) '
            'VALUES(:id,:run,:sid,:actor,:operation,:hash,:revision,:status,CAST(:image AS jsonb),:sha)'),
            {'id':uuid4(),'run':self.case['run_id'],'sid':root['id'],'actor':self.actor,'operation':self.operation,
             'hash':self.request_hash,'revision':root['revision'],'status':lifecycle(self,self.case),
             'image':json.dumps(image),'sha':digest(image)})
        super().commit()


class ExecutionStore:
    def __init__(self,engine,actor,run_id,sid,operation,body):
        self.engine,self.actor,self.run,self.sid,self.operation,self.body=engine,actor,run_id,sid,operation,body

    @contextmanager
    def open(self):
        with Session(self.engine,autoflush=False) as s:
            try:
                s.execute(text('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ'))
                role=s.execute(text('SELECT current_user,rolsuper,rolbypassrls FROM pg_roles WHERE rolname=current_user')).one()
                if role!=('p1_ee01_runtime',False,False):raise CqRefused('SYNTHETIC_RESTRICTED_ROLE_REQUIRED',503)
                s.execute(text("SELECT set_config('project1.actor_id',:actor,true),set_config('project1.synthetic_run_id',:run,true),set_config('project1.synthetic_session_id',:sid,true)"),
                    {'actor':str(self.actor),'run':str(self.run),'sid':str(self.sid)})
                case=s.execute(text('SELECT x.*,r.release_id,r.respondent_user_id,r.campaign_id FROM cq_synthetic_cases x JOIN cq_sessions r ON r.id=x.session_id '
                    'JOIN cq_synthetic_execution_grants g ON g.run_id=x.run_id WHERE x.session_id=:sid AND x.run_id=:run AND g.developer_user_id=:actor'),
                    {'sid':self.sid,'run':self.run,'actor':self.actor}).mappings().first()
                if not case or not s.scalar(text('SELECT cq_synthetic_can_execute(:sid)'),{'sid':self.sid}):raise CqRefused('SYNTHETIC_SESSION_NOT_FOUND',404)
                case=dict(case)
                if digest(case['source_json'])!=case['source_sha256']:raise CqRefused('SYNTHETIC_CASE_INTEGRITY_INVALID',503)
                unit=ExecutionUnit(s,case,self.actor,self.operation,digest(normalized(self.body)))
                current=lifecycle(unit,case)
                if current in ('SCREENED_OUT','UNRESOLVED') and self.operation not in ('read','history','withdraw'):
                    raise CqRefused('SYNTHETIC_SESSION_TERMINATED',409)
                yield unit
            finally:s.rollback()


class NonhumanExecutionAuthority:
    def authorize(self,unit,release,actor_id,operation):
        case=unit.case
        control=unit.control(case['session_id'])
        if (actor_id!=case['respondent_user_id'] or release['id']!=case['release_id']
            or release['source_class']!='SYNTHETIC_FIXTURE' or not control
            or digest(control['source_json'])!=control['source_hash']
            or case['source_json'].get('scenario')!=case['scenario']
            or case['source_json'].get('release_id')!=str(release['id'])
            or case['source_json'].get('manifest_hash')!=release['manifest_hash']
            or control['research_mode']!='DEVELOPER_PREVIEW'
            or control['source_json'].get('synthetic_run_id')!=str(case['run_id'])
            or control['source_json'].get('consent_semantics')!='SIMULATED_NONHUMAN_NOT_INFORMED_CONSENT'):
            raise CqRefused('SYNTHETIC_EXECUTION_BINDING_INVALID',403)
        return CqGrant('ISOLATED_TEST','EXPLICIT_NONHUMAN_DEVELOPER_EXECUTION',False)


class SyntheticExecutionService:
    def __init__(self,engine):self.engine=engine

    def cases(self,actor,run_id):
        from sitewise.services.ee01_service import Ee01Service,plain
        with Ee01Service(self.engine).connection(actor) as c:
            c.execute(text('SET TRANSACTION READ ONLY'))
            rows=c.execute(text('SELECT x.session_id,x.case_key,x.scenario,x.source_json FROM cq_synthetic_cases x '
                'JOIN cq_synthetic_execution_grants g ON g.run_id=x.run_id WHERE x.run_id=:run AND g.developer_user_id=:actor '
                'AND NOT EXISTS(SELECT 1 FROM cq_synthetic_import_retirements z WHERE z.run_id=x.run_id) ORDER BY x.case_key'),
                {'run':run_id,'actor':actor}).mappings().all()
        return {'contract_version':'synthetic-cases/1','origin':'SYNTHETIC_TEST','real_reportable':False,'cases':plain([dict(x) for x in rows])}

    def execute(self,actor,run_id,sid,operation,**body):
        store=ExecutionStore(self.engine,actor,run_id,sid,operation,body)
        with store.open() as unit:subject=unit.case['respondent_user_id']
        engine=CustomerQuestionnaireService(store,NonhumanExecutionAuthority())
        if operation in ('pause','resume'):
            result=engine.lifecycle(sid,subject,action=operation.upper(),**body)
        else:
            result=getattr(engine,operation)(sid,subject,**body)
        if result.get('contract_version')!='cq-session/1':return result
        with ExecutionStore(self.engine,actor,run_id,sid,'read',{}).open() as unit:
            case=unit.case;status=lifecycle(unit,case)
        result.update(synthetic_execution=True,origin='SYNTHETIC_TEST',real_reportable=False,
            synthetic_run_id=str(run_id),synthetic_case=case['case_key'],synthetic_scenario=case['scenario'],
            lifecycle_status=status,consent_semantics='SIMULATED_NONHUMAN_NOT_INFORMED_CONSENT')
        if status in ('SCREENED_OUT','UNRESOLVED'):
            result.update(can_submit=False,next_slot_id=None,next_stimulus_kind=None)
            result.pop('presentation',None)
        return result
