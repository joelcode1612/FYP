"""Spend the attempt before the socket opens.

Why this module exists
----------------------
Two records authorise one QG attempt: the single-use authorization row and the
owner's consent grant. Until now only the authorization was ever spent, and it
was spent *after* the model had answered — at the point the candidate was
persisted. That ordering has three consequences, all of them wrong:

* a provider call that succeeded and then failed to persist left the
  authorization unspent, so the same authorization could be replayed;
* a provider call that never returned left no trace that the attempt had been
  made, so "unknown outcome" looked identical to "never started";
* the consent grant, which authorises exactly one attempt, was never spent at
  all. A second dispatch against the same grant was refused only by the
  authorization, so the two records could disagree about whether the attempt had
  happened.

Reserving in one transaction, before dispatch, fixes all three. The attempt is
spent when it is *made*, not when it succeeds: a failed or unknown-outcome
attempt is still an attempt, which is precisely why an unknown outcome must not
be retried automatically.

Atomicity
---------
Both writes happen inside a single ``engine.begin()``. If either fails the whole
reservation rolls back, so there is no state in which the consent is spent and
the authorization is not. Concurrency is decided by the database, not by a check
the caller performs first:

* ``m2_qg_consent_consumptions.consent_id`` is the primary key, so a second
  reservation against the same grant is a unique violation;
* the authorization UPDATE is guarded by ``consumed_at IS NULL`` and a row count,
  so a second reservation affects no row.

What this module does not do
----------------------------
It does not decide whether generation is permitted. Every gate — authority,
eligibility, consent presence, source currentness — has already passed by the
time this runs. This is only the accounting, and it is deliberately the last
thing before dispatch.
"""
from __future__ import annotations

from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from sitewise.project1.contracts import WorkflowHeld


def _bind(conn, actor_id):
    from sitewise.repositories.m2_context_bindings import bind_restricted_principal
    from sitewise.services.business_context_v1 import ContextRefused
    try:
        bind_restricted_principal(conn, actor_id)
    except ContextRefused as exc:
        raise WorkflowHeld(exc.code) from None


def _sqlstate(exc: DBAPIError) -> str:
    orig = getattr(exc, 'orig', None)
    return str(getattr(orig, 'pgcode', '') or '')


def reserve(engine, *, actor_id, authorization_id, assessment_id,
            confirmation_id, assessment_revision, objective_decision_id) -> dict:
    """Reserve the one attempt both records authorise.

    Returns ``{'reserved': True, 'authorization_id': ..., 'consent_id': ...}``.
    ``consent_id`` is ``None`` only when the grant was read from the legacy
    snapshot location, which has no row to spend; in that case the authorization
    and the ledger's attempt budget remain the duplicate barriers, and the
    result says so rather than implying a consent was reserved.

    Raises ``QG_AUTHORIZATION_CONSUMED`` when the authorization was already
    spent, and ``QG_CONSENT_ALREADY_CONSUMED`` when the grant's single attempt
    was already taken. Both roll the whole reservation back.
    """
    with engine.begin() as conn:
        _bind(conn, actor_id)

        # 1. The consent attempt. A single INSERT ... SELECT: the row is written
        #    only if a currently valid, not-yet-spent grant exists, so validity
        #    and consumption cannot disagree. The newest such grant wins, because
        #    that is the permission the owner granted most recently.
        consent_id = None
        # An admission-bound authorization predates the grant table: its consent
        # block was read from the confirmation snapshot, so there is no grant row
        # keyed on a decision for it to spend. Skipping the reservation here keeps
        # that grant spendable; refusing instead would silently make every legacy
        # authorization unusable, which nobody asked for. Consent is still
        # enforced — ``runner_authority`` refuses a grant carrying no
        # ``consent_digest`` — and the authorization row plus the ledger's attempt
        # budget remain the duplicate barriers.
        if objective_decision_id is not None:
            try:
                inserted = conn.execute(text("""
                    INSERT INTO public.m2_qg_consent_consumptions
                      (consent_id, owner_user_id, assessment_id, authorization_id)
                    SELECT g.consent_id, g.owner_user_id, g.assessment_id, :auth
                      FROM public.m2_qg_consent_grants g
                     WHERE g.assessment_id = :assessment
                       AND g.confirmation_id = :confirmation
                       AND g.assessment_revision = :revision
                       AND g.objective_decision_id = :decision
                       AND g.revoked_at IS NULL
                       AND g.expires_at > now()
                       AND NOT EXISTS (
                             SELECT 1 FROM public.m2_qg_consent_consumptions c
                              WHERE c.consent_id = g.consent_id)
                     ORDER BY g.granted_at DESC
                     LIMIT 1
                    RETURNING consent_id
                """), {
                    'auth': str(authorization_id),
                    'assessment': str(assessment_id),
                    'confirmation': str(confirmation_id),
                    'revision': int(assessment_revision),
                    'decision': str(objective_decision_id),
                }).mappings().one_or_none()
            except DBAPIError as exc:
                state = _sqlstate(exc)
                if state == '23505':
                    # This authorization already holds a reservation.
                    raise WorkflowHeld('QG_CONSENT_ALREADY_CONSUMED') from None
                raise
            if inserted is not None:
                consent_id = str(inserted['consent_id'])
            else:
                # No grant could be spent. A grant that exists but is revoked,
                # expired or already spent does not cover this attempt, and
                # proceeding would dispatch without the owner's permission.
                existing = conn.execute(text("""
                    SELECT count(*) FROM public.m2_qg_consent_grants
                     WHERE assessment_id = :assessment
                       AND confirmation_id = :confirmation
                       AND assessment_revision = :revision
                       AND objective_decision_id = :decision
                """), {
                    'assessment': str(assessment_id),
                    'confirmation': str(confirmation_id),
                    'revision': int(assessment_revision),
                    'decision': str(objective_decision_id),
                }).scalar_one()
                if existing:
                    raise WorkflowHeld('QG_CONSENT_ALREADY_CONSUMED')

        # 2. The authorization. Same transaction, so the two records cannot
        #    disagree about whether the attempt happened.
        updated = conn.execute(text("""
            UPDATE public.m2_qg_authorizations
               SET consumed_at = now()
             WHERE authorization_id = :auth AND consumed_at IS NULL
        """), {'auth': str(authorization_id)}).rowcount
        if updated != 1:
            raise WorkflowHeld('QG_AUTHORIZATION_CONSUMED')

    return {'reserved': True,
            'authorization_id': str(authorization_id),
            'consent_id': consent_id,
            'reserved_before_dispatch': True}


__all__ = ['reserve']
