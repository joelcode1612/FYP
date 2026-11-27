"""Explicit M2 target without retargeting the application's other modules."""
from contextlib import contextmanager
from functools import lru_cache
from uuid import UUID

from sqlalchemy import event, text
from sqlalchemy.engine import make_url
from sqlmodel import Session, create_engine

from sitewise.core.config import settings
from sitewise.core.exceptions import AssessmentError
from sitewise.db.pooling import pool_kwargs


@lru_cache(maxsize=4)
def _engine(url):
    # The requesting owner is bound as a *transaction-local* GUC
    # (`set_config(..., true)`) on every `after_begin`, so a connection returned
    # to the pool carries no actor for the next request to inherit. That is what
    # makes reuse safe, and `sitewise.db.pooling` states the pool policy once.
    # `M2_POOL_MODE=null` restores the old one-connection-per-request behaviour
    # without a code change.
    return create_engine(url, echo=False, hide_parameters=True, **pool_kwargs())


def _verified_engine(raw: str):
    try:
        url = make_url(raw)
        valid = (url.drivername == 'postgresql+psycopg2' and
                 url.database == settings.m2_expected_database and bool(url.database))
    except (ValueError, TypeError):
        valid = False
    if not valid:
        raise AssessmentError('The dedicated M2 database target has not been verified.',
            code='M2_DATABASE_TARGET_UNVERIFIED', status_code=503)
    return _engine(raw)


def get_m2_engine():
    raw = settings.m2_database_url.get_secret_value() or settings.database_url
    return _verified_engine(raw)


def get_bcb_engine():
    """BCB persistence engine: dedicated ``M2_DATABASE_URL`` only.

    ``DATABASE_URL`` is deliberately not a fallback here. The BCB transaction
    must run as the M2 runtime login, never as the application's ordinary
    (possibly privileged) role. The restricted principal is still verified on
    the transaction itself before any source row is read.
    """
    return _verified_engine(settings.m2_database_url.get_secret_value())



def bind_m2_actor(connection, actor_id: UUID):
    """Bind one authenticated actor to an M2 transaction; never trust a UUID GUC in protected mode."""
    if settings.m2_protected_identity_enabled:
        from sitewise.db.m2_identity_assertion import mint_m2_assertion
        try:
            assertion = mint_m2_assertion(actor_id, settings.m2_identity_assertion_key.get_secret_value())
        except ValueError:
            raise AssessmentError('Protected M2 identity is not configured.',
                code='M2_PROTECTED_IDENTITY_UNAVAILABLE', status_code=503) from None
        connection.execute(text("SELECT set_config('project1.identity_assertion', :value, true)"),
                           {'value': assertion})
        verified = connection.execute(text('SELECT project1_identity.verified_actor()')).scalar_one()
        if str(verified) != str(actor_id):
            raise AssessmentError('Protected M2 identity could not be verified.',
                code='M2_PROTECTED_IDENTITY_UNAVAILABLE', status_code=503)
        return
    connection.execute(text("SELECT set_config('project1.actor_id', :actor, true)"),
                       {'actor': str(actor_id)})


@contextmanager
def m2_session_for(actor_id: UUID):
    """Owner-scoped M2 session.

    The M2 tables have RLS enabled with owner policies keyed on
    ``project1.actor_id``. Binding it here is what makes those policies
    meaningful. Rebind on every transaction: projection reads roll back, and
    writes may commit before reading the saved result. A binding made only at
    session creation is undone by a rollback and makes later owned rows vanish.
    """
    engine = get_m2_engine()
    with Session(engine) as session:
        def bind_actor(_session, _transaction, connection):
            bind_m2_actor(connection, actor_id)

        # Transaction-local scope resets on commit/rollback and is restored for
        # this same verified actor when SQLAlchemy starts the next transaction.
        event.listen(session, 'after_begin', bind_actor)
        try:
            yield session
        finally:
            event.remove(session, 'after_begin', bind_actor)


def get_m2_db():
    """Unscoped session for schema probes only; routes use ``m2_session_for``."""
    with Session(get_m2_engine()) as session:
        yield session
