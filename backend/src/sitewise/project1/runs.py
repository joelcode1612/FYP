"""Idempotent run provisioning for the cloud-BDJ path.

``PostgresAttemptLedger.reserve()`` requires a ``project1_ai.runs`` row and no
production code created one, so the first live dispatch would fail before it
reached the provider. This module creates or reuses that row.

The identity is ``sha256(canonical({assessment_id, revision, policy_fingerprint}))``.
The policy fingerprint is derived from the *effective* policy (rules version +
prompt version + model), not a constant, so changing the model starts a new run
instead of silently reusing one computed under different terms.

``reserve()`` never compares assessment revisions. The run row is the only place
that binding exists, so the assertion after the conflict resolution is the only
thing that enforces it.
"""
from __future__ import annotations

import hashlib
import re
from uuid import UUID, uuid4

from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlmodel import Session

from sitewise.core.config import settings
from sitewise.project1.contracts import WorkflowHeld, canonical
from sitewise.project1.principal import restricted_scope
from sitewise.project1.prompts import PROMPTS
from sitewise.project1.provider import MODEL
from sitewise.project1.qg_contract import CONTRACT_VERSION


def effective_policy_fingerprint(prompt_key: str = 'BDJ',
                                 rules_version: str | None = None) -> str:
    """Hash the effective policy, so a model change is a new work identity.

    ``prompt_key`` defaults to the M2V1 source prompt so every historical run
    identity is reproduced byte-identically. An M2V2 source evaluation passes
    its own key, which is what keeps two different prompts from sharing one
    run: otherwise the ledger's UNIQUE(run_id, stage) would treat the second
    prompt as a re-execution of the first.

    ``rules_version`` must be the ruleset that actually resolved for this
    instrument. It used to be read from the legacy global pin only, which is
    empty on an M2V2-only environment, so the run identity did not name the
    ruleset at all (DD-007). That mattered for single-use: the authorization row
    matches on (assessment, revision, fingerprint, ruleset, prompt), so once the
    identity is a function of the same tuple, one row can only ever map to one
    run and the ledger's reservation refuses the second attempt.
    """
    return hashlib.sha256(canonical({
        'rules_version': (settings.project1_rules_version
                          if rules_version is None else rules_version),
        'prompt_version': PROMPTS[prompt_key].version,
        'model': MODEL,
    }).encode('utf-8')).hexdigest()


def work_identity_for(assessment_id: UUID, revision: int,
                      policy_fingerprint: str) -> str:
    return hashlib.sha256(canonical({
        'assessment_id': str(assessment_id),
        'revision': revision,
        'policy_fingerprint': policy_fingerprint,
    }).encode('utf-8')).hexdigest()


def ensure_run(engine, actor_id: UUID, assessment_id: UUID, revision: int,
               source_fingerprint: str, prompt_key: str = 'BDJ',
               rules_version: str | None = None) -> UUID:
    """Provision or reuse the run for this assessment/revision/policy.

    Raises ``WORKFLOW_RUN_REVISION_MISMATCH`` if the conflict resolved to a row
    whose ``assessment_revision`` disagrees with the packet's, and
    ``RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED`` if the connection is not the
    restricted principal.
    """
    if isinstance(revision, bool) or not isinstance(revision, int) or revision < 0:
        raise WorkflowHeld('WORKFLOW_RUN_REVISION_INVALID')
    if not isinstance(source_fingerprint, str) or \
            not re.fullmatch(r'[a-f0-9]{64}', source_fingerprint):
        raise WorkflowHeld('WORKFLOW_RUN_FINGERPRINT_INVALID')

    policy = effective_policy_fingerprint(prompt_key, rules_version)
    work_identity = work_identity_for(assessment_id, revision, policy)
    run_id = uuid4()
    try:
        with Session(engine) as session:
            restricted_scope(session, actor_id)
            session.execute(text(
                'INSERT INTO project1_ai.runs (id, owner_user_id, assessment_id,'
                ' assessment_revision, source_fingerprint, policy_fingerprint,'
                ' work_identity) VALUES (:id, :actor, :assessment, :revision,'
                ' :source, :policy, :work)'
                ' ON CONFLICT (owner_user_id, work_identity) DO NOTHING'), {
                    'id': run_id, 'actor': actor_id, 'assessment': assessment_id,
                    'revision': revision, 'source': source_fingerprint,
                    'policy': policy, 'work': work_identity})
            row = session.execute(text(
                'SELECT id, assessment_revision, source_fingerprint FROM project1_ai.runs'
                ' WHERE owner_user_id=:actor AND work_identity=:work'), {
                    'actor': actor_id, 'work': work_identity}).one_or_none()
            if row is None:
                raise WorkflowHeld('WORKFLOW_RUN_NOT_FOUND')
            if row.assessment_revision != revision:
                # reserve() does not compare revisions; this is the only
                # enforcement of the packet/run binding.
                raise WorkflowHeld('WORKFLOW_RUN_REVISION_MISMATCH')
            if row.source_fingerprint != source_fingerprint:
                # A work identity can collide when source pins change without
                # a revision change. Never attach an attempt to the old source.
                raise WorkflowHeld('WORKFLOW_RUN_SOURCE_MISMATCH')
            session.commit()
            return row.id
    except WorkflowHeld:
        raise
    except SQLAlchemyError:
        # On Dss p1ai_engine has no USAGE on project1_ai (MIG-AUTH-01). That is
        # a hold, not a 500: fail closed with a named code.
        raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE') from None


# -- QG work identity -------------------------------------------------------
# QG is not an M2 revision. Under contract 2.0 it is bound to the confirmed
# facts the entrepreneur actually supplied, so it needs its own work identity
# while reusing the exact same ``project1_ai.runs`` + ledger infrastructure.

#: Prompt keys a QG run may be fingerprinted with. Deliberately the same set the
#: live runner is allowed to dispatch: a run whose policy names a prompt the
#: runner cannot dispatch, or a dispatch whose run names a different prompt, are
#: the same defect seen from two sides. ``qg_live`` imports this rather than
#: keeping a second copy that could drift.
QG_POLICY_PROMPT_KEYS = frozenset({'QG_PROPOSAL', 'QG_FIXED_OPTION'})


def qg_policy_fingerprint(prompt_key: str = 'QG_PROPOSAL') -> str:
    """Hash the effective QG policy, so a prompt/model/rules change is new work.

    The contract version, the full prompt fingerprint (not just its version
    label), the model and the rules version are all part of the terms under
    which a candidate was drafted. Changing any of them must start a new run
    rather than reuse one drafted under different terms.

    ``prompt_key`` names the prompt that is actually dispatched. It defaults to
    ``QG_PROPOSAL``, which is what every historical run was fingerprinted with,
    so this change leaves those identities — and every row already in
    ``project1_ai.runs`` — exactly as they were. A fixed-option dispatch passes
    its own key, so the run records the prompt it really used instead of
    inheriting the proposal prompt's identity.
    """
    prompt = PROMPTS.get(prompt_key)
    if prompt is None or prompt_key not in QG_POLICY_PROMPT_KEYS:
        # An unregistered key has no policy to hash, and a registered non-QG
        # prompt (BDJ, QJ) would mislabel a QG run. Refusing beats silently
        # fingerprinting the default prompt for a dispatch that used another.
        raise WorkflowHeld('QG_POLICY_PROMPT_NOT_REGISTERED')
    return hashlib.sha256(canonical({
        'contract_version': CONTRACT_VERSION,
        'prompt_version': prompt.version,
        'prompt_fingerprint': prompt.fingerprint,
        'model': MODEL,
        'rules_version': settings.project1_rules_version,
    }).encode('utf-8')).hexdigest()


def qg_work_identity(assessment_id, source_fingerprint: str,
                     policy_fingerprint: str,
                     evaluation_id: str = '') -> str:
    """Deterministic QG work identity.

    Deliberately distinct from ``work_identity_for``: it carries a ``stage``
    discriminator and is keyed on the confirmed-facts ``source_fingerprint``
    instead of an M2 ``revision``. The same inputs therefore never collide with
    a BDJ run.

    ``evaluation_id`` separates successive *evaluation runs* over otherwise
    identical facts and policy — for example after an unknown-outcome provider
    timeout consumed a one-attempt run. It never changes what the model is
    asked; it only gives a new run a different identity, so the append-only
    ledger keeps both attempts attributable and ``UNIQUE(run_id, stage)`` stays
    intact.
    """
    return hashlib.sha256(canonical({
        'stage': 'QG',
        'assessment_id': str(assessment_id),
        'source_fingerprint': source_fingerprint,
        'policy_fingerprint': policy_fingerprint,
        'evaluation_id': evaluation_id,
    }).encode('utf-8')).hexdigest()


def ensure_qg_run(engine, actor_id: UUID, assessment_id,
                  source_fingerprint: str,
                  evaluation_id: str = '',
                  prompt_key: str = 'QG_PROPOSAL') -> UUID:
    """Provision or reuse the QG run for these confirmed facts.

    ``assessment_revision`` is written explicitly as ``0``: QG facts are bound
    to the confirmed-facts fingerprint, not to an M2 revision, so there is no
    adopted measurement revision to record or compare. Revision is therefore
    *not* the binding assertion here. The binding that matters is asserted
    after the conflict-resolving insert: if an existing row carries a different
    ``source_fingerprint`` (the confirmed facts changed) or a different
    ``policy_fingerprint`` (the prompt/model/rules changed), the run cannot be
    reused and ``WORKFLOW_RUN_BINDING_MISMATCH`` is raised.

    Raises ``WORKFLOW_RUN_FINGERPRINT_INVALID`` /
    ``WORKFLOW_RUN_ASSESSMENT_INVALID`` for malformed inputs,
    ``WORKFLOW_RUN_NOT_FOUND`` if the insert conflicted away and no row exists,
    ``WORKFLOW_RUN_BINDING_MISMATCH`` if a reused row is bound to other facts or
    policy, and ``RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED`` if the connection is
    not the restricted principal.
    """
    if not isinstance(source_fingerprint, str) or \
            not re.fullmatch(r'[a-f0-9]{64}', source_fingerprint):
        raise WorkflowHeld('WORKFLOW_RUN_FINGERPRINT_INVALID')
    try:
        assessment_uuid = UUID(str(assessment_id))
    except (ValueError, TypeError, AttributeError):
        raise WorkflowHeld('WORKFLOW_RUN_ASSESSMENT_INVALID') from None

    policy = qg_policy_fingerprint(prompt_key)
    work_identity = qg_work_identity(assessment_uuid, source_fingerprint,
                                     policy, evaluation_id)
    run_id = uuid4()
    try:
        with Session(engine) as session:
            restricted_scope(session, actor_id)
            session.execute(text(
                'INSERT INTO project1_ai.runs (id, owner_user_id, assessment_id,'
                ' assessment_revision, source_fingerprint, policy_fingerprint,'
                ' work_identity) VALUES (:id, :actor, :assessment, :revision,'
                ' :source, :policy, :work)'
                ' ON CONFLICT (owner_user_id, work_identity) DO NOTHING'), {
                    'id': run_id, 'actor': actor_id,
                    'assessment': assessment_uuid, 'revision': 0,
                    'source': source_fingerprint, 'policy': policy,
                    'work': work_identity})
            row = session.execute(text(
                'SELECT id, source_fingerprint, policy_fingerprint'
                ' FROM project1_ai.runs'
                ' WHERE owner_user_id=:actor AND work_identity=:work'), {
                    'actor': actor_id, 'work': work_identity}).one_or_none()
            if row is None:
                raise WorkflowHeld('WORKFLOW_RUN_NOT_FOUND')
            if (row.source_fingerprint != source_fingerprint or
                    row.policy_fingerprint != policy):
                # The confirmed facts or the effective QG policy changed, so a
                # run created under the old binding must not be reused. Fail
                # closed rather than attach attempts to a different contract.
                raise WorkflowHeld('WORKFLOW_RUN_BINDING_MISMATCH')
            session.commit()
            return row.id
    except WorkflowHeld:
        raise
    except SQLAlchemyError:
        raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE') from None


# -- BDJ objective work identity --------------------------------------------
# The findings run (``ensure_run``) fingerprints PROMPTS['BDJ'] and carries no
# context hash. Objective proposals are a different contract, a different
# prompt and are bound to a persisted BCB packet, so they need their own work
# identity; otherwise the two would share a run and the ledger's
# UNIQUE(run_id, stage) would make the second execution impossible.

#: Version tag for the TokenHarbour-era objective policy identity. The legacy
#: payload carries no version key at all, so its hash is untouched.
OBJECTIVE_POLICY_VERSION = 'objective-policy/2'


def objective_policy_fingerprint(prompt_key: str = 'BDJ_OBJECTIVE',
                                 *, provider: str | None = None) -> str:
    """Hash the effective objective policy (contract, prompt, model, rules).

    Two identities live here, and the distinction is load-bearing:

    ``provider is None`` — the **historical** identity.
        Byte-identical to the calculation that produced every pre-existing
        ``project1_ai.runs`` row: the ``model`` term is ``SIMULATOR_MODEL`` and
        no version key is added. Historical run identities therefore remain
        reproducible, so an existing run is still *found* rather than
        duplicated. Never change this payload.

    ``provider='tokenharbor'`` — the **versioned** identity for a real cloud
        execution. It adds ``policy_version``, ``model_provider`` and pins the
        adapter's actual model. A different producer is a different policy, so
        it cannot collide with a historical simulated run (requirement: no
        reuse or redispatch across a model-policy change), while prompt
        version, prompt fingerprint, contract version and rules version stay
        bound exactly as before.

    ``prompt_key`` still separates the M2 V2 family from the M2 V1 family via a
    different prompt version *and* a different ``stage`` label.
    """
    from sitewise.project1.objective_proposal import CONTRACT_VERSION
    from sitewise.project1.objective_simulation import SIMULATOR_MODEL
    prompt = PROMPTS[prompt_key]
    terms = {
        'stage': prompt_key,
        'contract_version': CONTRACT_VERSION,
        'prompt_version': prompt.version,
        'prompt_fingerprint': prompt.fingerprint,
        'model': SIMULATOR_MODEL,
        'rules_version': settings.project1_rules_version,
    }
    if provider is not None:
        from sitewise.project1.provider import MODEL
        terms['policy_version'] = OBJECTIVE_POLICY_VERSION
        terms['model_provider'] = provider
        terms['model'] = MODEL
    return hashlib.sha256(canonical(terms).encode('utf-8')).hexdigest()


def objective_work_identity(assessment_id, revision: int, source_fingerprint: str,
                            context_packet_hash: str,
                            policy_fingerprint: str) -> str:
    """Deterministic identity: source revision + context packet + policy terms."""
    return hashlib.sha256(canonical({
        'stage': 'BDJ_OBJECTIVE',
        'assessment_id': str(assessment_id),
        'revision': revision,
        'source_fingerprint': source_fingerprint,
        'context_packet_hash': context_packet_hash,
        'policy_fingerprint': policy_fingerprint,
    }).encode('utf-8')).hexdigest()


def ensure_objective_run(engine, actor_id: UUID, assessment_id,
                         revision: int, source_fingerprint: str,
                         context_packet_hash: str,
                         prompt_key: str = 'BDJ_OBJECTIVE',
                         provider: str | None = None) -> UUID:
    """Provision or reuse the objective run for this source + context + policy.

    ``assessment_revision`` records the real M2 revision (unlike the QG run,
    which is revision-free), because the proposal table is revision-bound and
    ``objective_adapter`` filters readback on it.
    """
    if isinstance(revision, bool) or not isinstance(revision, int) or revision < 0:
        raise WorkflowHeld('WORKFLOW_RUN_REVISION_INVALID')
    for value in (source_fingerprint, context_packet_hash):
        if not isinstance(value, str) or not re.fullmatch(r'[a-f0-9]{64}', value):
            raise WorkflowHeld('WORKFLOW_RUN_FINGERPRINT_INVALID')

    policy = objective_policy_fingerprint(prompt_key, provider=provider)
    work_identity = objective_work_identity(
        assessment_id, revision, source_fingerprint, context_packet_hash, policy)
    run_id = uuid4()
    try:
        with Session(engine) as session:
            restricted_scope(session, actor_id)
            session.execute(text(
                'INSERT INTO project1_ai.runs (id, owner_user_id, assessment_id,'
                ' assessment_revision, source_fingerprint, policy_fingerprint,'
                ' work_identity) VALUES (:id, :actor, :assessment, :revision,'
                ' :source, :policy, :work)'
                ' ON CONFLICT (owner_user_id, work_identity) DO NOTHING'), {
                    'id': run_id, 'actor': actor_id, 'assessment': assessment_id,
                    'revision': revision, 'source': source_fingerprint,
                    'policy': policy, 'work': work_identity})
            row = session.execute(text(
                'SELECT id, assessment_revision, source_fingerprint, policy_fingerprint'
                ' FROM project1_ai.runs'
                ' WHERE owner_user_id=:actor AND work_identity=:work'), {
                    'actor': actor_id, 'work': work_identity}).one_or_none()
            if row is None:
                raise WorkflowHeld('WORKFLOW_RUN_NOT_FOUND')
            if row.assessment_revision != revision:
                raise WorkflowHeld('WORKFLOW_RUN_REVISION_MISMATCH')
            if (row.source_fingerprint != source_fingerprint
                    or row.policy_fingerprint != policy):
                raise WorkflowHeld('WORKFLOW_RUN_BINDING_MISMATCH')
            session.commit()
            return row.id
    except WorkflowHeld:
        raise
    except SQLAlchemyError:
        raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE') from None


def attempt_count(engine, actor_id: UUID, run_id: UUID) -> int:
    """How many attempts this run has, read under the restricted principal."""
    try:
        with Session(engine) as session:
            restricted_scope(session, actor_id)
            count = session.execute(text(
                'SELECT count(*) FROM project1_ai.attempts'
                ' WHERE run_id=:run AND owner_user_id=:actor'), {
                    'run': run_id, 'actor': actor_id}).scalar()
            session.rollback()
            return int(count or 0)
    except WorkflowHeld:
        raise
    except SQLAlchemyError:
        raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE') from None


def latest_receipt(engine, actor_id: UUID, run_id: UUID):
    """Return ``(attempt_no, outcome, output_digest)`` for the newest attempt."""
    try:
        with Session(engine) as session:
            restricted_scope(session, actor_id)
            row = session.execute(text(
                'SELECT attempt_no, outcome, output_digest'
                ' FROM project1_ai.attempt_receipts'
                ' WHERE run_id=:run AND owner_user_id=:actor'
                ' ORDER BY attempt_no DESC LIMIT 1'), {
                    'run': run_id, 'actor': actor_id}).one_or_none()
            session.rollback()
            return None if row is None else (row.attempt_no, row.outcome,
                                             row.output_digest)
    except WorkflowHeld:
        raise
    except SQLAlchemyError:
        raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE') from None


# ---------------------------------------------------------------------------
# Execution progress, read from the ledger that already exists
# ---------------------------------------------------------------------------
#
# The owner asked for a real execution indicator for BDJ and QG, built on the
# existing AI ledger, with no second ledger, no progress table and no invented
# percentages. Everything below is read from ``project1_ai.runs``,
# ``project1_ai.attempts`` and ``project1_ai.attempt_receipts`` — the same three
# tables the dispatcher already writes. Nothing here can observe a model call
# that the ledger did not record, which is exactly the property that makes it
# trustworthy: an empty ledger means "no attempt", not "probably nothing".

#: The states the interface may render. Each one is derived from a fact, never
#: interpolated between facts.
EXECUTION_STATES = (
    'BLOCKED',          # no attempt has been reserved for this stage
    'PROCESSING',       # reserved, no receipt, still within the dispatch window
    'RETURNED',         # the provider answered; no domain row has landed
    'VALIDATING',       # a domain row landed but has not finished validation
    'PERSISTED',        # a domain row landed and is validated
    'FAILED',           # the receipt records a refusal
    'UNKNOWN_OUTCOME',  # reserved, no receipt, past the dispatch window
)

#: How long a reservation may stand with no receipt before "in flight" becomes
#: "we do not know what happened". Derived from the configured provider timeout
#: plus a margin, so it tracks the deployment rather than a guess.
def in_flight_grace() -> 'timedelta':
    from datetime import timedelta
    return timedelta(seconds=int(settings.tokenharbor_timeout_seconds) + 30)


def execution_status(engine, actor_id: UUID, assessment_id: UUID, *,
                     stage: str, now=None) -> dict:
    """The newest attempt for one stage, as the ledger records it.

    ``state`` is ledger-only: it cannot tell whether a returned result was
    written to its domain table, because that table is not the ledger. The
    caller upgrades ``RETURNED`` to ``VALIDATING`` or ``PERSISTED`` once it has
    looked, which keeps the two facts separable instead of guessing here.
    """
    from datetime import datetime, timedelta, timezone

    moment = now or datetime.now(timezone.utc)
    try:
        with Session(engine) as session:
            restricted_scope(session, actor_id)
            row = session.execute(text("""
                SELECT r.id AS run_id, r.assessment_revision,
                       a.attempt_no, a.reserved_at,
                       rec.outcome AS receipt_outcome,
                       rec.created_at AS receipt_at,
                       (SELECT count(*) FROM project1_ai.attempts a2
                         WHERE a2.run_id = r.id
                           AND a2.owner_user_id = r.owner_user_id
                           AND a2.stage = a.stage) AS attempts_reserved
                  FROM project1_ai.runs r
                  JOIN project1_ai.attempts a
                    ON a.run_id = r.id AND a.owner_user_id = r.owner_user_id
                  LEFT JOIN project1_ai.attempt_receipts rec
                    ON rec.run_id = a.run_id
                   AND rec.attempt_no = a.attempt_no
                   AND rec.owner_user_id = a.owner_user_id
                 WHERE r.owner_user_id = :actor
                   AND r.assessment_id = :assessment
                   AND a.stage = :stage
                 ORDER BY a.reserved_at DESC
                 LIMIT 1
            """), {'actor': actor_id, 'assessment': assessment_id,
                   'stage': stage}).mappings().one_or_none()
            session.rollback()
    except WorkflowHeld:
        raise
    except SQLAlchemyError:
        raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE') from None

    if row is None:
        return {'stage': stage, 'state': 'BLOCKED', 'reason': 'NO_ATTEMPT_RESERVED',
                'run_id': None, 'attempt_no': None, 'attempts_reserved': 0,
                'reserved_at': None, 'receipt_outcome': None,
                'receipt_at': None, 'assessment_revision': None}

    reserved_at = row['reserved_at']
    if reserved_at is not None and reserved_at.tzinfo is None:
        reserved_at = reserved_at.replace(tzinfo=timezone.utc)
    receipt_at = row['receipt_at']
    if receipt_at is not None and receipt_at.tzinfo is None:
        receipt_at = receipt_at.replace(tzinfo=timezone.utc)

    outcome = row['receipt_outcome']
    if outcome is None:
        waited = (moment - reserved_at) if reserved_at is not None else timedelta(0)
        if waited <= in_flight_grace():
            state, reason = 'PROCESSING', 'RESERVED_AWAITING_RECEIPT'
        else:
            # The reservation outlived the dispatch window with no receipt. That
            # is not a failure and not a success: the peer may or may not have
            # been reached, and the attempt is spent either way.
            state, reason = 'UNKNOWN_OUTCOME', 'RESERVED_PAST_DISPATCH_WINDOW'
    elif outcome == 'returned':
        state, reason = 'RETURNED', 'RECEIPT_RETURNED'
    elif outcome == 'unknown_outcome':
        state, reason = 'UNKNOWN_OUTCOME', 'RECEIPT_UNKNOWN_OUTCOME'
    else:
        state, reason = 'FAILED', f'RECEIPT_{str(outcome).upper()}'

    return {
        'stage': stage,
        'state': state,
        'reason': reason,
        'run_id': str(row['run_id']),
        'attempt_no': int(row['attempt_no']),
        'attempts_reserved': int(row['attempts_reserved'] or 0),
        'reserved_at': reserved_at.isoformat() if reserved_at else None,
        'receipt_outcome': outcome,
        'receipt_at': receipt_at.isoformat() if receipt_at else None,
        'assessment_revision': row['assessment_revision'],
    }


def refine_with_domain(status: dict, *, persisted: int,
                       pending_validation: int) -> dict:
    """Upgrade a ledger ``RETURNED`` once the domain table has been consulted.

    The ledger records that the provider answered. Whether the governed write
    landed is a different fact, held by a different table. Keeping the upgrade
    here — rather than inside :func:`execution_status` — is what lets the
    interface say "returned but not persisted" instead of claiming a persistence
    that never happened.
    """
    if status.get('state') != 'RETURNED':
        return {**status, 'domain': {'persisted': persisted,
                                     'pending_validation': pending_validation}}
    if persisted <= 0:
        return {**status, 'state': 'RETURNED', 'reason': 'RETURNED_NOT_PERSISTED',
                'domain': {'persisted': 0, 'pending_validation': 0}}
    if pending_validation > 0:
        return {**status, 'state': 'VALIDATING', 'reason': 'PERSISTED_PENDING_VALIDATION',
                'domain': {'persisted': persisted,
                           'pending_validation': pending_validation}}
    return {**status, 'state': 'PERSISTED', 'reason': 'PERSISTED_AND_VALIDATED',
            'domain': {'persisted': persisted, 'pending_validation': 0}}
