"""Connection-pool policy for the restricted-principal M2 and CQ engines.

Both engines bind an authenticated actor into a **transaction-local** GUC
(``set_config('project1.actor_id', ..., true)``) on every ``after_begin``. That
is what makes a shared physical connection safe: the setting dies with the
transaction, so a connection returned to the pool carries no actor for the next
request to inherit.

This module centralises the pool construction so the two engines cannot drift
apart, and so the conservative ``NullPool`` behaviour remains one configuration
value away (``M2_POOL_MODE=null``) rather than a code revert. The default is
``QueuePool``: the isolation that justifies reuse is proved by
``tests/d6_pooling/``.

``pool_reset_on_return='rollback'`` is set explicitly. It is SQLAlchemy's
default, but relying on a default here would mean that a future global change
(``create_engine(..., pool_reset_on_return=None)``) silently returns a
connection with an open transaction -- and therefore a live actor setting -- to
the pool. Stating it makes the guarantee a property of this module.
"""
from sqlalchemy.pool import NullPool, QueuePool

from sitewise.core.config import settings

#: ``queue`` -> bounded QueuePool (default); ``null`` -> NullPool (rollback).
POOL_MODES = ('queue', 'null')


def pool_mode() -> str:
    """The configured pool mode, normalised, refusing anything unknown.

    An unrecognised value fails closed at engine construction rather than
    falling back to either mode: a typo must not silently choose the less safe
    of the two.
    """
    mode = (settings.m2_pool_mode or 'queue').strip().lower()
    if mode not in POOL_MODES:
        raise RuntimeError(
            f"M2_POOL_MODE={mode!r} is not one of {POOL_MODES}; refusing to "
            "guess a connection-pool mode for a restricted-principal engine."
        )
    return mode


def pool_kwargs() -> dict:
    """Keyword arguments for ``create_engine`` on an actor-bound engine."""
    if pool_mode() == 'null':
        # One configuration value restores the pre-pooling behaviour: a fresh
        # connection per request, discarded on close.
        return {'poolclass': NullPool}

    return {
        'poolclass': QueuePool,
        'pool_size': settings.m2_pool_size,
        'max_overflow': settings.m2_pool_max_overflow,
        # Recycle below the server's idle timeout so a stale connection is
        # never handed out after the backend has closed it.
        'pool_recycle': settings.m2_pool_recycle_seconds,
        'pool_pre_ping': True,
        # Never hand back a connection with an open transaction (and therefore
        # a live actor GUC). See the module docstring.
        'pool_reset_on_return': 'rollback',
    }
