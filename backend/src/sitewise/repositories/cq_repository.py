"""PostgreSQL CQ adapter; existing Dss engine/identity/M2 ownership reused."""
from contextlib import contextmanager
from uuid import uuid4

from sqlalchemy import and_,select,update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from sitewise.db.models import cq_runtime_schema as db
from sitewise.db.models.m2_schema import assessments
from sitewise.domain.cq_runtime import CqRefused
from sitewise.domain.customer_questionnaire import digest
from sitewise.repositories.m2_repository import SqlModelM2Repository


class UnverifiedCqAuthority:
    def authorize(self,unit,release,actor_id,operation):
        raise CqRefused('PRODUCTION_FIELDING_HOLD',503)


class CqUnit:
    def __init__(self,session):
        self.session=session;self.m2=SqlModelM2Repository(session)
    def one(self,table,conditions,lock=False):
        query=select(table).where(*conditions)
        if lock: query=query.with_for_update()
        row=self.session.execute(query).mappings().first()
        return dict(row) if row else None
    def release(self,rid): return self.one(db.releases,[db.releases.c.id==rid])
    def bank(self,version): return self.one(db.banks,[db.banks.c.version==version])
    def assignments(self,rid):
        return [dict(r) for r in self.session.execute(select(db.assignments).where(db.assignments.c.release_id==rid)).mappings()]
    def campaign(self,cid): return self.one(db.campaigns,[db.campaigns.c.id==cid])
    def campaign_for_assessment(self,aid): return self.one(db.campaigns,[db.campaigns.c.assessment_id==aid])
    def create_campaign(self,aid,owner,rid):
        row={'id':uuid4(),'assessment_id':aid,'owner_user_id':owner,'release_id':rid}
        result=self.session.execute(insert(db.campaigns).values(**row).on_conflict_do_nothing(
            index_elements=[db.campaigns.c.assessment_id]).returning(db.campaigns)).mappings().first()
        return dict(result) if result else self.campaign_for_assessment(aid)
    def add_participant(self,cid,respondent):
        self.session.execute(insert(db.participants).values(campaign_id=cid,respondent_user_id=respondent).on_conflict_do_nothing())
    def participant(self,cid,actor):
        return self.one(db.participants,[db.participants.c.campaign_id==cid,db.participants.c.respondent_user_id==actor])
    def invitations(self,actor):
        query=(select(db.campaigns,db.sessions.c.id.label('session_id')).join(db.participants,
            db.participants.c.campaign_id==db.campaigns.c.id).outerjoin(db.sessions,and_(
                db.sessions.c.campaign_id==db.campaigns.c.id,db.sessions.c.respondent_user_id==actor))
            .where(db.participants.c.respondent_user_id==actor))
        return [dict(r) for r in self.session.execute(query).mappings()]
    def create_session(self,campaign,actor,locale):
        row={'id':uuid4(),'campaign_id':campaign['id'],'release_id':campaign['release_id'],
             'respondent_user_id':actor,'locale':locale,'revision':0,'state':'ACTIVE','consented':False,'consent_version':None}
        result=self.session.execute(insert(db.sessions).values(**row).on_conflict_do_nothing(
            index_elements=[db.sessions.c.campaign_id,db.sessions.c.respondent_user_id]).returning(db.sessions)).mappings().first()
        return dict(result) if result else self.one(db.sessions,[db.sessions.c.campaign_id==campaign['id'],db.sessions.c.respondent_user_id==actor])
    def owned_session(self,sid,actor,lock=False):
        return self.one(db.sessions,[db.sessions.c.id==sid,db.sessions.c.respondent_user_id==actor],lock)
    def update_session(self,sid,revision,**values):
        result=self.session.execute(update(db.sessions).where(db.sessions.c.id==sid,
            db.sessions.c.revision==revision).values(revision=revision+1,**values))
        if result.rowcount!=1: raise CqRefused('CQ_STALE_REVISION')
    def latest(self,sid):
        rows=self.session.execute(select(db.answers).where(db.answers.c.session_id==sid).order_by(db.answers.c.revision)).mappings()
        return {r['slot_id']:dict(r) for r in rows}
    def history(self,sid):
        return [dict(r) for r in self.session.execute(select(db.answers).where(db.answers.c.session_id==sid).order_by(db.answers.c.revision)).mappings()]
    def exposure_map(self,sid):
        return {r['kind']:r['stimulus_hash'] for r in self.session.execute(select(db.exposures).where(db.exposures.c.session_id==sid).order_by(db.exposures.c.revision)).mappings()}
    def consent_retry(self,sid,rid): return self.one(db.consents,[db.consents.c.session_id==sid,db.consents.c.request_id==rid])
    def answer_retry(self,sid,rid): return self.one(db.answers,[db.answers.c.session_id==sid,db.answers.c.request_id==rid])
    def insert_consent(self,**row): self.session.execute(insert(db.consents).values(**row))
    def insert_exposure(self,**row): self.session.execute(insert(db.exposures).values(**row))
    def decision(self,sid,revision,rows):
        identity=uuid4();value=digest(rows)
        self.session.execute(insert(db.decisions).values(id=identity,session_id=sid,revision=revision,
            decision_json=rows,decision_hash=value).on_conflict_do_nothing(index_elements=[db.decisions.c.session_id,db.decisions.c.revision]))
        row=self.one(db.decisions,[db.decisions.c.session_id==sid,db.decisions.c.revision==revision])
        if row['decision_hash']!=value: raise CqRefused('CQ_ROUTING_SNAPSHOT_CHANGED')
        return row
    def presentation(self,sid,revision,slot,context,decision_id):
        row={'id':uuid4(),'session_id':sid,'revision':revision,'slot_id':slot,'context_digest':context,'decision_id':decision_id}
        self.session.execute(insert(db.displays).values(**row).on_conflict_do_nothing())
        return self.one(db.displays,[db.displays.c.session_id==sid,db.displays.c.revision==revision,
            db.displays.c.slot_id==slot,db.displays.c.context_digest==context])
    def display(self,pid): return self.one(db.displays,[db.displays.c.id==pid])
    def insert_answer(self,**row): self.session.execute(insert(db.answers).values(**row))
    def canonical(self,sid,revision,rows):
        for row in rows:
            value={'session_id':sid,'slot_id':row['slot_id'],'answer_event_id':row['event_id'],
                'state':row['state'],'context_digest':row['context_digest'],'revision':revision}
            if value['answer_event_id'] is not None:
                from uuid import UUID
                value['answer_event_id']=UUID(value['answer_event_id'])
            self.session.execute(insert(db.effective).values(**value).on_conflict_do_update(
                index_elements=[db.effective.c.session_id,db.effective.c.slot_id],set_=value))
    def receipt(self,sid): return self.one(db.receipts,[db.receipts.c.session_id==sid])
    def withdraw_effective(self,sid,revision):
        self.session.execute(update(db.effective).where(db.effective.c.session_id==sid).values(
            answer_event_id=None,state='NOT_SHOWN',revision=revision))
    def insert_receipt(self,**row): self.session.execute(insert(db.receipts).values(**row))
    def paused(self,sid):
        action=self.session.execute(select(db.lifecycle.c.action).where(db.lifecycle.c.session_id==sid)
            .order_by(db.lifecycle.c.revision.desc()).limit(1)).scalar_one_or_none()
        return action=='PAUSE'
    def lifecycle_retry(self,sid,rid): return self.one(db.lifecycle,[db.lifecycle.c.session_id==sid,db.lifecycle.c.request_id==rid])
    def insert_lifecycle(self,**row): self.session.execute(insert(db.lifecycle).values(**row))
    def rendered(self,sid,pid): return self.one(db.renders,[db.renders.c.session_id==sid,db.renders.c.display_id==pid])
    def render(self,**row): self.session.execute(insert(db.renders).values(**row).on_conflict_do_nothing())
    def rejected_retry(self,sid,rid): return self.one(db.rejected,[db.rejected.c.session_id==sid,db.rejected.c.request_id==rid])
    def reject_answer(self,**row): self.session.execute(insert(db.rejected).values(**row))
    def insert_control(self,**row): self.session.execute(insert(db.controls).values(**row).on_conflict_do_nothing())
    def control(self,sid): return self.one(db.controls,[db.controls.c.session_id==sid])
    def commit(self): self.session.commit()


class PostgresCqStore:
    def __init__(self,engine): self.engine=engine
    @contextmanager
    def open(self):
        try:
            with Session(self.engine,autoflush=False) as session:
                try: yield CqUnit(session)
                finally: session.rollback()
        except SQLAlchemyError as exc:
            raise CqRefused('CQ_STORAGE_UNAVAILABLE',503) from exc
