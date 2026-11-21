"""PostgreSQL UoW for persisted BCB; independent of the auth read transaction."""
from contextlib import contextmanager

from sqlalchemy import and_, func, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from sitewise.db.models.business_context_schema import builds, contexts
from sitewise.db.models.m2_schema import assessments
from sitewise.repositories.m2_repository import SqlModelM2Repository
from sitewise.services.ports.business_context_store_port import (
    ContextBindingUnavailable, ContextStoreUnavailable,
)


class UnverifiedContextBindings:
    """Real composition deliberately supplies no guessed tenant/purpose receipts."""
    def __init__(self, session): pass
    def resolve(self, selection, actor):
        raise ContextBindingUnavailable()


class SqlBusinessContextUnit:
    def __init__(self, session, resolver):
        self.session, self.resolver = session, resolver
        self.m2 = SqlModelM2Repository(session)
    def resolve_inputs(self, selection, actor): return self.resolver.resolve(selection, actor)
    def commit(self): self.session.commit()
    def rollback(self): self.session.rollback()
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
    def __init__(self, engine, resolver_factory=UnverifiedContextBindings):
        if engine.dialect.name != 'postgresql':
            raise ContextStoreUnavailable('BCB_POSTGRESQL_REQUIRED')
        self.engine, self.resolver_factory = engine, resolver_factory
    @contextmanager
    def open(self):
        try:
            with self.engine.connect().execution_options(isolation_level='REPEATABLE READ') as connection:
                with Session(connection, autoflush=False) as session:
                    try:
                        yield SqlBusinessContextUnit(session, self.resolver_factory(session))
                    finally:
                        session.rollback()
        except SQLAlchemyError as exc:
            raise ContextStoreUnavailable('BCB_POSTGRESQL_UNAVAILABLE',
                retryable=getattr(getattr(exc,'orig',None),'pgcode',None) in {'40001','40P01'}) from exc
