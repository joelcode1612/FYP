"""Restricted execution-principal scope, shared by the ledger and result writer.

This is the same contract as ``PostgresAttemptLedger._scope`` (ledger.py:14-40),
extracted so the run-provisioning service and the result store cannot drift
into a different role than the ledger. It is duplicated rather than imported
because the ledger is already verified and this checkpoint must not change its
behaviour.

Two permitted paths reach the required state:

* a direct restricted login (disposable test clones only), or
* the dedicated execution principal ``p1ai_engine`` (member of
  ``p1ai_runtime``) issuing ``SET LOCAL ROLE p1ai_runtime``.

A superuser, a BYPASSRLS login, or the ordinary app role that never switches
role fails closed. ``project1.actor_id`` is bound transaction-locally so every
row written afterwards is visible only to its owner under RLS.
"""
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from sitewise.project1.contracts import WorkflowHeld

RESTRICTED_ROLE = 'p1ai_runtime'


def restricted_scope(session, actor_id: UUID) -> None:
    session_user, current_user, rolsuper, rolbypassrls = session.execute(text(
        'SELECT session_user, current_user, '
        '(SELECT rolsuper FROM pg_roles WHERE rolname=session_user), '
        '(SELECT rolbypassrls FROM pg_roles WHERE rolname=session_user)')).one()
    if rolsuper or rolbypassrls:
        raise WorkflowHeld('RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED')
    if current_user != RESTRICTED_ROLE:
        try:
            session.execute(text(f'SET LOCAL ROLE {RESTRICTED_ROLE}'))
        except SQLAlchemyError:
            raise WorkflowHeld('RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED') from None
        current_user = session.execute(text('SELECT current_user')).scalar()
    if current_user != RESTRICTED_ROLE:
        raise WorkflowHeld('RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED')
    from sitewise.db.m2_session import bind_m2_actor
    bind_m2_actor(session, actor_id)
