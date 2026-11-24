"""One authoritative answer to "is the source this candidate cites still current?"

Why this is not a local query
-----------------------------
An admission lookup resolves ``ADMITTED`` when a row exists. That says the owner
once decided something about a proposal; it says nothing about whether the
business context that decision was made against is still the context the workflow
is using. On 2026-11-23 the two diverged: the admission cited packet
``26f243be``, the workflow's current packet was ``d61118e8``, and the application
refused the old one with ``BCB_CONTEXT_SOURCE_CHANGED``. Direct-QG would still
have dispatched against it, because nothing on that path asked.

So the verdict comes from the persisted business-context service — the same
component the application uses — rather than from a bespoke SQL predicate that
could agree with itself while disagreeing with the workflow.

Two independent facts must hold
-------------------------------
1. The service must still call the snapshot current and reproducible
   (``source_is_current`` and ``context_compatible``).
2. The snapshot the caller's authorization names must be the one the service
   names. A current snapshot is no help if the candidate is bound to a different
   one.

Failure is a hold, never a warning: a candidate persisted against a superseded
source would be indistinguishable, in the table, from one persisted against the
source that was actually approved.
"""
from __future__ import annotations

from sqlalchemy import text

#: Stable codes. Each names a different operator action, so they are not merged
#: into a single "source problem".
SOURCE_NOT_CURRENT = 'BCB_SOURCE_NOT_CURRENT'
SOURCE_NOT_REPRODUCIBLE = 'BCB_CONTEXT_NOT_REPRODUCIBLE'
SOURCE_SUPERSEDED = 'BCB_CONTEXT_SUPERSEDED'
SOURCE_NOT_PERSISTED = 'BCB_CONTEXT_NOT_PERSISTED'
SOURCE_UNKNOWN = 'BCB_SOURCE_VERDICT_UNAVAILABLE'


def refusal(verdict: dict | None, *, authorized_context_packet_hash: str) -> str | None:
    """Why this source may not be used, or ``None`` when it may.

    Pure: the verdict is an argument, so the policy is testable without a
    database and cannot drift between callers.
    """
    if not verdict:
        return SOURCE_UNKNOWN
    if verdict.get('refusal'):
        return str(verdict['refusal'])
    if verdict.get('source_is_current') is not True:
        return SOURCE_NOT_CURRENT
    if verdict.get('context_compatible') is False:
        return SOURCE_NOT_REPRODUCIBLE
    if str(verdict.get('status') or '') != 'PERSISTED':
        return SOURCE_NOT_PERSISTED
    current_hash = verdict.get('packet_hash')
    if not current_hash:
        # The service named a context but its packet hash could not be read, so
        # "is this the same snapshot?" is unanswerable. Refuse rather than guess.
        return SOURCE_UNKNOWN
    if str(current_hash) != str(authorized_context_packet_hash):
        return SOURCE_SUPERSEDED
    return None


def current_source(engine, *, service, assessment_id, confirmation_id,
                   actor) -> dict:
    """Compose the verdict: the service's judgement plus the packet it names.

    ``service`` is the persisted business-context service. ``engine`` is the M2
    engine, used only to read the packet hash of the context the service names —
    the hash is an identifier, not a judgement, so reading it directly cannot
    contradict the service.

    The owner-scoped policy on ``m2_business_contexts`` reads
    ``project1_actor()``, so the principal must be bound before the read. Without
    it the query returns **no row rather than an error**, the hash comes back
    ``None``, and this gate refuses every attempt as
    ``BCB_SOURCE_VERDICT_UNAVAILABLE`` — fail-closed, but for the wrong reason and
    indistinguishable from a genuinely missing snapshot.
    """
    from sitewise.repositories.m2_context_bindings import bind_restricted_principal
    from sitewise.services.persisted_business_context_service import (
        ContextOperationHeld,
    )
    try:
        status = service.status(assessment_id, confirmation_id, actor)
    except ContextOperationHeld as exc:
        return {'refusal': f'BCB_STATUS_UNAVAILABLE_{exc.code}',
                'status': None, 'source_is_current': None,
                'context_compatible': None, 'context_id': None,
                'packet_hash': None}
    context_id = status.get('context_id')
    packet_hash = None
    if context_id is not None:
        with engine.connect() as conn:
            bind_restricted_principal(conn, actor.user_id)
            packet_hash = conn.execute(text("""
                SELECT packet_hash FROM public.m2_business_contexts
                 WHERE context_id = :cid
            """), {'cid': str(context_id)}).scalar()
    return {**status, 'context_id': str(context_id) if context_id else None,
            'packet_hash': packet_hash}


def check(engine, *, service, assessment_id, confirmation_id, actor,
          context_packet_hash) -> dict:
    """The verdict plus the refusal code for one authorized snapshot."""
    verdict = current_source(engine, service=service, assessment_id=assessment_id,
                             confirmation_id=confirmation_id, actor=actor)
    return {**verdict,
            'refusal_code': refusal(
                verdict, authorized_context_packet_hash=context_packet_hash)}


__all__ = ['SOURCE_NOT_CURRENT', 'SOURCE_NOT_PERSISTED', 'SOURCE_NOT_REPRODUCIBLE',
           'SOURCE_SUPERSEDED', 'SOURCE_UNKNOWN', 'check', 'current_source',
           'refusal']
