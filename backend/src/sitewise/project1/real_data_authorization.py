"""Real-data BDJ authorisation lookup (production counterpart of the trial authority).

A row in ``project1_ai.bdj_real_data_authorizations`` is the only thing that lets
a non-synthetic worksheet through ``validate_synthetic``. The row is bound to one
source fingerprint, one ruleset hash and one prompt hash, so it cannot be reused
for a different worksheet, a different ruleset or a re-worded prompt.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass
from uuid import UUID

from sqlalchemy import text

REAL_DATA_CLASS = 'ENTREPRENEUR_DECLARED'


@dataclass(frozen=True)
class RealDataAuthorization:
    """A matched, unexpired, unconsumed authorisation for this exact run."""
    id: UUID
    assessment_id: UUID
    assessment_revision: int
    source_fingerprint: str
    ruleset_version: str
    rules_sha256: str
    prompt_sha256: str
    authorized_by: UUID
    receipt: str


def prompt_sha256(prompt_text: str) -> str:
    return hashlib.sha256(prompt_text.encode('utf-8')).hexdigest()


def _bind_owner(conn, actor_id: UUID) -> None:
    """Establish the restricted principal and the owner GUC on this transaction.

    This table's ``owner_scope`` policy is granted to ``p1_m2_runtime``, not to
    ``p1ai_runtime``. Reading it as ``p1ai_runtime`` therefore failed twice over:
    that role holds no table privilege, and it has no policy, so RLS would have
    denied every row even after a grant. The QG path already reads its
    authorisation rows as ``p1_m2_runtime``; this makes the BDJ lookup agree with
    it instead of adding a second, parallel read path.

    No privilege is widened: the row must still satisfy the existing
    ``owner_scope`` predicate *and* the exact binding match below.
    """
    from sitewise.repositories.m2_context_bindings import bind_restricted_principal
    from sitewise.services.business_context_v1 import ContextRefused
    from sitewise.project1.contracts import WorkflowHeld
    try:
        bind_restricted_principal(conn, actor_id)
    except ContextRefused as exc:
        raise WorkflowHeld(exc.code) from None


def load(*, engine, actor_id: UUID, assessment_id: UUID, revision: int,
         source_fingerprint: str,
         ruleset_version: str, rules_sha256: str, prompt_digest: str,
         data_class: str | None = None) -> RealDataAuthorization | None:
    """Return the matching live authorisation, or None. Never raises on absence."""
    # The disclosure guard has already established that data_class is NOT
    # SYNTHETIC_NONHUMAN. The security boundary is the row match below (exact
    # fingerprint + ruleset hash + prompt hash + unexpired + unconsumed), not the
    # spelling of the class label, so the label is recorded but not gated here.
    with engine.begin() as conn:
        _bind_owner(conn, actor_id)
        row = conn.execute(text(
            'SELECT auth.id, auth.assessment_id, auth.assessment_revision,'
            '       auth.source_fingerprint, auth.ruleset_version, auth.rules_sha256,'
            '       auth.prompt_sha256, auth.authorized_by, auth.receipt'
            '  FROM project1_ai.bdj_real_data_authorizations auth'
            ' WHERE auth.assessment_id=:a AND auth.assessment_revision=:r'
            '   AND auth.source_fingerprint=:f AND auth.ruleset_version=:v'
            '   AND auth.rules_sha256=:rh AND auth.prompt_sha256=:ph'
            # clock_timestamp(), not now(): now() is the transaction start time,
            # so a long-running transaction would treat an already-expired row
            # as live. The guard trigger re-checks this atomically anyway; this
            # keeps the two clocks consistent.
            '   AND auth.consumed_at IS NULL AND auth.expires_at > clock_timestamp()'
            # Mechanism B (DD-005): a spend is recorded as an append-only event,
            # never by writing ``consumed_at``. A row that has a consumption
            # event is spent and must not be returned as live, even though its
            # legacy ``consumed_at`` column is still NULL.
            '   AND NOT EXISTS ('
            '        SELECT 1 FROM project1_ai.bdj_authorization_consumptions c'
            '         WHERE c.authorization_id = auth.id)'),
            {'a': assessment_id, 'r': revision, 'f': source_fingerprint,
             'v': ruleset_version, 'rh': rules_sha256, 'ph': prompt_digest}).mappings().first()
    if row is None:
        return None
    return RealDataAuthorization(**dict(row))


# ---------------------------------------------------------------------------
# DD-005 mechanism B: spending an authorization is an append-only EVENT.
#
# ``bdj_real_data_authorizations`` is immutable by trigger, so "single use"
# cannot be recorded by mutating ``consumed_at``. Instead one row is inserted
# into ``bdj_authorization_consumptions`` whose PRIMARY KEY is the
# authorization id: the second insert for the same authorization cannot commit.
#
# ``record_spend`` deliberately takes the CALLER'S session rather than opening
# its own. The attempt ledger commits the reservation before any dispatch
# (``PostgresAttemptLedger.reserve``), so the spend must join that exact
# transaction. If it did not, a crash between the two commits could leave a
# reserved attempt with an unspent authorization, or the reverse.
# ---------------------------------------------------------------------------

ALREADY_CONSUMED = 'BDJ_AUTHORIZATION_ALREADY_CONSUMED'
SPEND_DENIED = 'BDJ_AUTHORIZATION_SPEND_DENIED'
SPEND_REFUSED = 'BDJ_AUTHORIZATION_SPEND_REFUSED'


def record_spend(session, *, authorization_id: UUID, run_id: UUID,
                 owner_user_id: UUID, attempt_no: int, receipt: str) -> None:
    """Record the spend inside the caller's open transaction.

    Raises ``WorkflowHeld`` when the spend cannot be recorded. Because the
    caller has not committed yet, raising is what makes the attempt reservation
    and the spend atomic: the transaction is rolled back and no attempt exists.
    """
    from sqlalchemy.exc import IntegrityError

    from sitewise.project1.contracts import WorkflowHeld
    if not isinstance(receipt, str) or not receipt.strip():
        # The receipt is the audit link back to the operator decision. An event
        # without one is not evidence, so it is refused rather than stored blank.
        raise WorkflowHeld(SPEND_REFUSED)
    try:
        row = session.execute(text(
            'INSERT INTO project1_ai.bdj_authorization_consumptions'
            ' (authorization_id, run_id, owner_user_id, attempt_no, receipt)'
            ' VALUES (:auth, :run, :actor, :n, :receipt)'
            # The primary key is the single-use guarantee. DO NOTHING turns the
            # second insert into "no row returned" instead of a driver error, so
            # the refusal is explicit and testable.
            ' ON CONFLICT (authorization_id) DO NOTHING'
            ' RETURNING authorization_id'),
            {'auth': authorization_id, 'run': run_id, 'actor': owner_user_id,
             'n': attempt_no, 'receipt': receipt}).first()
    except IntegrityError as exc:
        # 23505 duplicate / 23503 missing authorization / 42501 RLS refusal
        # (wrong or unbound actor). Each is a distinct refusal, not a crash.
        code = getattr(getattr(exc, 'orig', None), 'pgcode', None)
        if code == '23505':
            raise WorkflowHeld(ALREADY_CONSUMED) from None
        raise WorkflowHeld(SPEND_DENIED) from None
    if row is None:
        raise WorkflowHeld(ALREADY_CONSUMED)
