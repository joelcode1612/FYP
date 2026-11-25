"""PostgreSQL CQ adapter.

Two decisions determine whether this module is safe, and both are made here
explicitly rather than inherited from ambient configuration:

* **which principal** the statements execute as, and
* **which actor** the row-level policies see.

``p1_m2_runtime`` cannot be used for CQ. ``m2/20261117_06`` grants it four
SELECTs and raises at migration time if any write privilege ever appears on it,
so the respondent write path is refused by the database when it runs as that
login. The CQ write grants belong to ``p1_ee01_runtime`` (``cq/20261116_04``,
``cq/20261124_01``, ``cq/20261124_02``), which is the principal established
below. (DD-CQ-11)

Every transaction also binds the authenticated actor. Without it the policies
read ``current_setting('project1.actor_id', true)`` as ``''`` and deny
everything, so an unbound transaction fails closed — but a *silently* failing
closed transaction is indistinguishable from an empty result set, which is how
a missing binding turns into a wrong answer instead of an error. (DD-CQ-14)
"""
import logging
from contextlib import contextmanager
from functools import lru_cache
from uuid import UUID, uuid4

from sqlalchemy import and_, create_engine, event, select, text, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.engine import make_url
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session
from sqlalchemy.pool import NullPool

from sitewise.core.config import settings
from sitewise.db.models import cq_runtime_schema as db
from sitewise.domain.cq_runtime import CqRefused
from sitewise.domain.customer_questionnaire import digest

logger = logging.getLogger('sitewise.cq.storage')

#: The restricted principal that owns the CQ write grants. NOSUPERUSER and
#: NOBYPASSRLS, so the policies on the CQ tables actually apply to it.
CQ_WRITE_ROLE = 'p1_ee01_runtime'

#: The publication principal (``cq/20261125_02``). It holds SELECT+INSERT on
#: ``cq_bank_versions`` / ``cq_manifest_releases`` / ``cq_question_assignments``
#: / ``cq_campaigns`` and nothing on any respondent-scoped relation, so
#: "publish an instrument" and "answer an instrument" are different
#: capabilities held by different roles. (DD-096)
PUBLICATION_ROLE = 'p1_cq_publisher'

#: Server-side refusals a retry cannot fix. Classified for the internal log
#: only: the client-facing code stays ``CQ_STORAGE_UNAVAILABLE`` for every
#: storage failure, so no table name, policy name or SQL text reaches a
#: respondent, and an operator can still tell a misconfiguration from an outage.
_DETERMINISTIC = {
    '42501': 'PRIVILEGE_DENIED',
    '42P01': 'RELATION_MISSING',
    '42703': 'COLUMN_MISSING',
    '42883': 'FUNCTION_MISSING',
    '55000': 'IMMUTABLE_ROW_REFUSED',
    '23503': 'FOREIGN_KEY_VIOLATED',
    '23514': 'CHECK_VIOLATED',
}

#: Failures that a retry, or a moment's patience, can resolve.
_TRANSIENT = {
    '40001': 'SERIALIZATION_FAILURE',
    '40P01': 'DEADLOCK_DETECTED',
    '53300': 'TOO_MANY_CONNECTIONS',
    '57P01': 'SERVER_SHUTDOWN',
}


def _storage_refusal(exc):
    """Classify a storage failure for the log and return the client-facing refusal."""
    pgcode = getattr(getattr(exc, 'orig', None), 'pgcode', None)
    if pgcode in _DETERMINISTIC:
        logger.error('CQ storage refused: deterministic %s (sqlstate=%s)',
                     _DETERMINISTIC[pgcode], pgcode,
                     extra={'cq_failure_class': 'DETERMINISTIC',
                            'cq_failure_kind': _DETERMINISTIC[pgcode],
                            'cq_sqlstate': pgcode})
    elif pgcode in _TRANSIENT:
        logger.warning('CQ storage unavailable: transient %s (sqlstate=%s)',
                       _TRANSIENT[pgcode], pgcode,
                       extra={'cq_failure_class': 'TRANSIENT',
                              'cq_failure_kind': _TRANSIENT[pgcode],
                              'cq_sqlstate': pgcode})
    else:
        logger.error('CQ storage unavailable: unclassified %s (sqlstate=%s)',
                     type(exc).__name__, pgcode,
                     extra={'cq_failure_class': 'UNCLASSIFIED', 'cq_sqlstate': pgcode})
    return CqRefused('CQ_STORAGE_UNAVAILABLE', 503)


@lru_cache(maxsize=4)
def _cq_engine(url):
    # NullPool: the principal is switched with SET LOCAL ROLE and the actor is a
    # transaction-local GUC. Both reset at commit, but a pooled connection would
    # still carry the previous request's session state, so each request gets a
    # connection that is discarded on close.
    return create_engine(url, pool_pre_ping=True, echo=False, hide_parameters=True,
                         poolclass=NullPool)


def get_cq_engine():
    """Engine for the CQ write principal.

    Prefers ``EE01_DATABASE_URL``, which is the ``p1_ee01_runtime`` login and
    the DSN the API already validates for that role. Falls back to the M2 DSN
    when EE-01 is unset; ``bind_cq_principal`` then has to assume the role with
    ``SET LOCAL ROLE``, which succeeds only for a login that may assume it.
    Either way the effective principal is verified per transaction, so a
    fallback that cannot assume the role fails closed rather than writing as
    the wrong role.

    The declared database is checked against both ``EE01_EXPECTED_DATABASE`` and
    ``M2_EXPECTED_DATABASE``: either is an operator declaration of the target,
    and requiring one of them to match stops a mis-pointed DSN early.
    """
    raw = settings.ee01_database_url.get_secret_value()
    if raw:
        try:
            url = make_url(raw)
            valid = (url.drivername == 'postgresql+psycopg2' and bool(url.database)
                     and url.database in {settings.ee01_expected_database,
                                          settings.m2_expected_database})
        except (ValueError, TypeError):
            valid = False
        if not valid:
            raise CqRefused('CQ_DATABASE_TARGET_UNVERIFIED', 503)
        return _cq_engine(raw)
    from sitewise.db.m2_session import get_m2_engine
    return get_m2_engine()


def get_publication_engine():
    """Engine for the publication principal, and only for it.

    Stricter than ``get_cq_engine`` on purpose: there is no fallback. A
    publication that silently ran as the M2 runtime, the EE-01 runtime or the
    application login would defeat the separation the principal exists to
    provide, and the failure would be invisible -- the write would succeed and
    only the privilege audit would notice. So the DSN must name
    ``p1_cq_publisher`` **and** the declared database, or this refuses.

    Refusals are 503 rather than 500: an unconfigured publication path is a
    deployment state, not a bug in the request.
    """
    raw = settings.cq_publication_database_url.get_secret_value()
    if not raw:
        raise CqRefused('CQ_PUBLICATION_TARGET_UNVERIFIED', 503)
    try:
        url = make_url(raw)
    except (ValueError, TypeError):
        raise CqRefused('CQ_PUBLICATION_TARGET_UNVERIFIED', 503) from None
    expected = settings.cq_publication_expected_database
    if (url.drivername != 'postgresql+psycopg2'
            or not url.database
            or url.username != PUBLICATION_ROLE
            or not expected
            or url.database != expected):
        raise CqRefused('CQ_PUBLICATION_TARGET_UNVERIFIED', 503)
    return _cq_engine(raw)


def bind_cq_principal(connection, actor_id):
    """Establish the CQ write principal and the authenticated actor on this transaction.

    Mirrors ``m2_context_bindings.bind_restricted_principal``. Two paths reach
    the same state:

    * a direct ``p1_ee01_runtime`` login (production ``EE01_DATABASE_URL``), or
    * ``SET LOCAL ROLE p1_ee01_runtime`` from a login that may assume it.

    Anything else — including an effective principal that is a superuser or
    holds BYPASSRLS — is refused. RLS is the only thing separating two
    respondents' evidence, so a bypassing role would make every policy
    decorative while still returning plausible rows.
    """
    _bind_principal(connection, actor_id, CQ_WRITE_ROLE)


def bind_publication_principal(connection, actor_id):
    """Establish the **publication** principal and the authenticated actor.

    Publication is not a respondent operation. ``cq/20261125_02`` creates
    ``p1_cq_publisher`` with SELECT+INSERT on the four release tables and no
    privilege at all on any session, answer or receipt table, so a publication
    transaction physically cannot touch respondent evidence. This function
    establishes that principal and refuses anything else, including a login
    that happens to be ``p1_ee01_runtime`` -- publishing as the respondent
    runtime is exactly the conflation DD-096 is about.

    The same three invariants as the respondent path hold: the effective
    principal is verified per transaction, a superuser or BYPASSRLS effective
    principal is refused, and the actor is bound from the authenticated
    identity rather than from ambient state.
    """
    _bind_principal(connection, actor_id, PUBLICATION_ROLE)


def _bind_principal(connection, actor_id, role):
    current = connection.execute(text('SELECT current_user')).scalar()
    if current != role:
        try:
            connection.execute(text('SET LOCAL ROLE ' + role))
        except SQLAlchemyError:
            raise CqRefused('CQ_RESTRICTED_PRINCIPAL_REQUIRED', 503) from None
        current = connection.execute(text('SELECT current_user')).scalar()
    if current != role:
        raise CqRefused('CQ_RESTRICTED_PRINCIPAL_REQUIRED', 503)
    if connection.execute(text(
            'SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user'
        )).scalar() is not False:
        raise CqRefused('CQ_RESTRICTED_PRINCIPAL_REQUIRED', 503)
    if settings.m2_protected_identity_enabled:
        # Protected-identity mode proves the actor through a signed assertion and
        # publishes `project1.identity_assertion`, never `project1.actor_id`.
        # Every CQ policy reads the latter, and `project1_identity` is a
        # rehearsal-only schema granted to `p1_m2_runtime` alone. Refuse instead
        # of running with an actor the policies cannot see. (DD-CQ-20)
        raise CqRefused('CQ_IDENTITY_MODE_UNSUPPORTED', 503)
    from sitewise.db.m2_session import bind_m2_actor
    bind_m2_actor(connection, actor_id)


class UnverifiedCqAuthority:
    def authorize(self,unit,release,actor_id,operation):
        raise CqRefused('PRODUCTION_FIELDING_HOLD',503)


class CqUnit:
    def __init__(self,session):
        self.session=session
    def one(self,table,conditions,lock=False):
        query=select(table).where(*conditions)
        if lock: query=query.with_for_update()
        row=self.session.execute(query).mappings().first()
        return dict(row) if row else None
    def assessment_owned(self,aid):
        """Does the authenticated actor own this M2 assessment?

        Evaluated through ``cq_assessment_owned_by_actor``, a SECURITY DEFINER
        predicate, instead of reading ``public.m2_assessments`` directly: the CQ
        principal holds no privilege on the M2 tables and must not be given one
        just to answer an existence question. The previous implementation called
        ``get_assessment_for_update``, which both required that privilege and
        took a ``FOR UPDATE`` row lock on an M2 row from inside a CQ transaction,
        blocking M2 revision writers for the duration of a campaign insert.

        The lock was never the serialization point for campaigns.
        ``UNIQUE(assessment_id)`` on ``cq_campaigns`` plus ``ON CONFLICT DO
        NOTHING`` in ``create_campaign`` is, and the ``cq_owner_insert`` policy
        re-checks assessment ownership inside the same statement. (DD-CQ-19)
        """
        return bool(self.session.execute(
            text('SELECT public.cq_assessment_owned_by_actor(:aid)'), {'aid': aid}).scalar())
    def release(self,rid): return self.one(db.releases,[db.releases.c.id==rid])
    def release_by_manifest_hash(self,value):
        # `manifest_hash` is UNIQUE on `cq_manifest_releases`, so this is the
        # idempotency key for publication: the same manifest can only ever be
        # one release, and a republish reads instead of inserting.
        return self.one(db.releases,[db.releases.c.manifest_hash==value])
    def insert_bank(self,**row): self.session.execute(insert(db.banks).values(**row))
    def insert_release(self,**row): self.session.execute(insert(db.releases).values(**row))
    def insert_assignment(self,**row): self.session.execute(insert(db.assignments).values(**row))
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
    """CQ persistence bound to the authenticated actor on every transaction.

    ``open`` takes the actor instead of reading ambient state. A binding applied
    once at session creation is not enough: the unit commits inside the block
    (``CqUnit.commit``), and a commit ends both the transaction-local role
    switch and the actor GUC, so the statements after the commit would run as
    the bare login with no actor at all. The ``after_begin`` listener re-binds
    on every transaction for exactly that reason — the same mechanism
    ``m2_session.m2_session_for`` uses.
    """

    def __init__(self, engine):
        self.engine = engine

    @contextmanager
    def open(self, actor_id, *, role=CQ_WRITE_ROLE):
        """One transaction bound to ``actor_id`` under ``role``.

        ``role`` is keyword-only and defaults to the respondent runtime, so
        every existing caller keeps its exact behaviour. Publication passes
        ``PUBLICATION_ROLE``; that is the only difference between the two
        paths at the database, and it is what makes the separation real rather
        than conventional.
        """
        if not isinstance(actor_id, UUID):
            raise CqRefused('CQ_ACTOR_REQUIRED', 401)
        try:
            with Session(self.engine, autoflush=False) as session:
                def bind(_session, _transaction, connection):
                    _bind_principal(connection, actor_id, role)

                event.listen(session, 'after_begin', bind)
                try:
                    yield CqUnit(session)
                finally:
                    event.remove(session, 'after_begin', bind)
                    session.rollback()
        except CqRefused:
            raise
        except SQLAlchemyError as exc:
            raise _storage_refusal(exc) from exc
