"""PostgreSQL UoW for persisted BCB; independent of the auth read transaction."""
from contextlib import contextmanager

from sqlalchemy import and_, func, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from sitewise.db.models.business_context_schema import builds, contexts
from sitewise.db.models.m2_schema import assessments
from sitewise.repositories.m2_context_bindings import (
    M2ContextBindings, bind_restricted_principal,
)
from sitewise.repositories.m2_repository import SqlModelM2Repository
from sitewise.services.business_context_v1 import ContextRefused
from sitewise.services.ports.business_context_store_port import (
    ContextStoreUnavailable,
)


class SqlBusinessContextUnit:
    def __init__(self, session, resolver):
        self.session, self.resolver = session, resolver
        self.m2 = SqlModelM2Repository(session)
    def resolve_inputs(self, selection, actor): return self.resolver.resolve(selection, actor)
    def commit(self): self.session.commit()
    def rollback(self): self.session.rollback()
    def ensure_build(self, confirmation_id, owner_id, assessment_id, revision):
        """Create the build row for a confirmation, idempotently.

        Nothing else in the codebase inserts into this table: `read_build`
        selects it and `record_build` only updates it, so first construction
        failed for every environment. The insert carries only the identities the
        caller has already authorised (assessment ownership + revision checks in
        `_select`); it never fabricates confirmation evidence.
        """
        self.session.execute(insert(builds).values(
            confirmation_id=confirmation_id, assessment_id=assessment_id,
            owner_user_id=owner_id, assessment_revision=revision,
            status='PENDING', attempt_count=0).on_conflict_do_nothing(
            index_elements=[builds.c.confirmation_id]))

    def read_build(self, confirmation_id, owner_id):
        row = self.session.execute(select(builds).join(assessments,
            builds.c.assessment_id == assessments.c.id).where(and_(
                builds.c.confirmation_id == confirmation_id,
                builds.c.owner_user_id == owner_id,
                assessments.c.owner_user_id == owner_id))).mappings().first()
        return dict(row) if row else None
    def read_context(self, context_id, owner_id):
        row = self.session.execute(select(contexts).join(assessments,
            contexts.c.assessment_id == assessments.c.id).where(and_(
                contexts.c.context_id == context_id,
                contexts.c.owner_user_id == owner_id,
                assessments.c.owner_user_id == owner_id))).mappings().first()
        return dict(row) if row else None
    def latest_context_id(self, assessment_id, owner_id):
        """Newest persisted context for one owner-scoped M2 assessment.

        Read-only projection used by the report, which must show the *current*
        confirmed description rather than a caller-supplied id it could be
        tricked into naming. Ordering is by the assessment revision the packet
        was built against, then by creation time, so a rebuild of the same
        revision does not outrank a later confirmed revision. ``created_at`` is
        nullable on historical rows, hence ``nullslast``: an undated row must
        never displace a dated one of the same revision.
        """
        return self.session.execute(select(contexts.c.context_id).join(assessments,
            contexts.c.assessment_id == assessments.c.id).where(and_(
                contexts.c.assessment_id == assessment_id,
                contexts.c.owner_user_id == owner_id,
                assessments.c.owner_user_id == owner_id,
                contexts.c.lifecycle_status == 'PERSISTED',
            )).order_by(
                contexts.c.assessment_revision.desc(),
                contexts.c.created_at.desc().nullslast(),
            ).limit(1)).scalar_one_or_none()
    def put_context(self, row):
        saved = self.session.execute(insert(contexts).values(**row)
            .on_conflict_do_nothing(index_elements=[contexts.c.context_id])
            .returning(contexts)).mappings().first()
        if saved: return dict(saved), True
        saved = self.read_context(row['context_id'], row['owner_user_id'])
        if saved is None or any(saved[k] != row[k] for k in (
                'assessment_id','confirmation_id','assessment_revision','packet_hash','canonical_body')):
            raise ContextStoreUnavailable('BCB_STORED_SCOPE_INVALID')
        return saved, False
    def record_build(self, confirmation_id, owner_id, status, code, context_id=None):
        changed = self.session.execute(update(builds).where(and_(
            builds.c.confirmation_id == confirmation_id, builds.c.owner_user_id == owner_id))
            .values(status=status,last_code=code,context_id=context_id,
                    attempt_count=builds.c.attempt_count+1,updated_at=func.now()))
        if changed.rowcount != 1: raise ContextStoreUnavailable('BCB_BUILD_STATUS_UNAVAILABLE')


class SqlBusinessContextStore:
    def __init__(self, engine, resolver_factory=M2ContextBindings):
        if engine.dialect.name != 'postgresql':
            raise ContextStoreUnavailable('BCB_POSTGRESQL_REQUIRED')
        self.engine, self.resolver_factory = engine, resolver_factory
    @contextmanager
    def open(self, actor_id):
        """Open the BCB transaction as the restricted M2 principal.

        The principal and ``project1.actor_id`` are bound before the resolver or
        any store read executes, so an owner-scoped row is never queried as the
        ordinary application login. A principal that cannot be established (or
        that is a superuser / BYPASSRLS role) is refused rather than silently
        bypassing RLS.
        """
        try:
            with self.engine.connect().execution_options(isolation_level='REPEATABLE READ') as connection:
                with Session(connection, autoflush=False) as session:
                    try:
                        try:
                            bind_restricted_principal(session, actor_id)
                        except ContextRefused as exc:
                            raise ContextStoreUnavailable(exc.code) from exc
                        yield SqlBusinessContextUnit(session, self.resolver_factory(session))
                    finally:
                        session.rollback()
        except SQLAlchemyError as exc:
            raise ContextStoreUnavailable('BCB_POSTGRESQL_UNAVAILABLE',
                retryable=getattr(getattr(exc,'orig',None),'pgcode',None) in {'40001','40P01'}) from exc
