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
                     evaluation_id: str = '',
                     objective_id: str = '') -> str:
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

    ``objective_id`` is the approved additional research objective this run
    drafts for (CP-FINAL-04). It is included **only when supplied**, so every
    historical identity — and every row already in ``project1_ai.runs`` —
    remains exactly as it was. Two objectives over the same facts and policy
    otherwise collide into one run, which is why one objective's progress was
    displayed under another's heading.
    """
    payload = {
        'stage': 'QG',
        'assessment_id': str(assessment_id),
        'source_fingerprint': source_fingerprint,
        'policy_fingerprint': policy_fingerprint,
        'evaluation_id': evaluation_id,
    }
    if objective_id:
        payload['objective_id'] = str(objective_id)
    return hashlib.sha256(canonical(payload).encode('utf-8')).hexdigest()


def ensure_qg_run(engine, actor_id: UUID, assessment_id,
                  source_fingerprint: str,
                  evaluation_id: str = '',
                  prompt_key: str = 'QG_PROPOSAL',
                  objective_id: str | None = None) -> UUID:
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
    run_id = uuid4()
    try:
        with Session(engine) as session:
            restricted_scope(session, actor_id)
            # The objective dimension is written only where the schema has it
            # (proposed migration 20261126_03). Including it in the identity
            # changes the run for a given objective, so it must not be included
            # before the column exists: that would orphan every historical run
            # and hand each objective a fresh attempt budget.
            record_objective = (objective_id is not None
                                and has_run_objective_column(session))
            work_identity = qg_work_identity(
                assessment_uuid, source_fingerprint, policy, evaluation_id,
                str(objective_id) if record_objective else '')
            extra_cols = ', objective_id' if record_objective else ''
            extra_vals = ', :objective' if record_objective else ''
            params = {'id': run_id, 'actor': actor_id,
                      'assessment': assessment_uuid, 'revision': 0,
                      'source': source_fingerprint, 'policy': policy,
                      'work': work_identity}
            if record_objective:
                params['objective'] = str(objective_id)
            session.execute(text(
                'INSERT INTO project1_ai.runs (id, owner_user_id, assessment_id,'
                ' assessment_revision, source_fingerprint, policy_fingerprint,'
                ' work_identity' + extra_cols + ') VALUES (:id, :actor,'
                ' :assessment, :revision, :source, :policy, :work' + extra_vals +
                ') ON CONFLICT (owner_user_id, work_identity) DO NOTHING'), params)
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


def objective_identity(assessment_id, revision: int, source_fingerprint: str,
                       context_packet_hash: str, *,
                       prompt_key: str = 'BDJ_OBJECTIVE',
                       provider: str | None = None) -> tuple[str, str]:
    """``(policy_fingerprint, work_identity)`` for one objective pass.

    Shared by :func:`ensure_objective_run`, which *writes* the run row, and
    :func:`objective_generation_state`, which *looks for* it. One calculation
    means the row that is created and the row that is searched for cannot drift
    apart, which would otherwise make the interface offer a pass the route then
    refuses (or hide one it would perform).
    """
    policy = objective_policy_fingerprint(prompt_key, provider=provider)
    return policy, objective_work_identity(
        assessment_id, revision, source_fingerprint, context_packet_hash, policy)


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

    policy, work_identity = objective_identity(
        assessment_id, revision, source_fingerprint, context_packet_hash,
        prompt_key=prompt_key, provider=provider)
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


#: The closed set of reasons a governed objective pass may or may not be offered.
#:
#: There is no "maybe": the caller renders one of these or nothing at all.
OBJECTIVE_GENERATION_REASONS = (
    'NOT_STARTED',    # no attempt recorded for this exact work identity
    'IN_PROGRESS',    # an attempt is reserved and its receipt has not arrived
    'ATTEMPT_SPENT',  # the attempt exists; the route reuses it, never redispatches
    'UNAVAILABLE',    # the ledger could not be read
)


def objective_generation_state(engine, actor_id: UUID, assessment_id, *,
                               revision: int, source_fingerprint: str,
                               now=None) -> dict:
    """Whether a governed objective pass can still be performed for this context.

    The predicate is "no objective attempt has ever been recorded against this
    exact source revision". Three things follow from stating it that way, and all
    three are deliberate:

    **It ignores the policy term.** ``work_identity`` folds the policy
    fingerprint, which folds the prompt version. A predicate built on
    ``work_identity`` would therefore report "never started" the moment a prompt
    revision shipped, re-authorising a review context that had already been
    completed. Revising the prompt must not spend a second attempt, so the
    identity that decides *availability* is the source, not the policy. The
    prefix match on ``prompt_version`` is family-wide for the same reason: it
    must still recognise an attempt recorded under an older revision.

    **It is not the proposal count.** A pass that ran and stored nothing leaves
    no proposal rows, so counting proposals would offer the control again after a
    completed review (and after every rejection).

    **It cannot be satisfied by client state.** Nothing here reads a run id, a
    flag or a count the browser holds.

    Read-only by construction: asking the question never provisions a run, so it
    cannot consume the attempt it is asking about.
    """
    contract = 'bdj-objective-generation/1'
    try:
        with Session(engine) as session:
            restricted_scope(session, actor_id)
            row = session.execute(text("""
                SELECT count(*) AS attempts,
                       max(a.reserved_at) AS last_reserved
                  FROM project1_ai.attempts a
                  JOIN project1_ai.runs r
                    ON r.id = a.run_id AND r.owner_user_id = a.owner_user_id
                 WHERE a.owner_user_id = :actor
                   AND r.assessment_id = :assessment
                   AND r.assessment_revision = :revision
                   AND r.source_fingerprint = :source
                   AND a.stage = 'BDJ'
                   AND a.prompt_version LIKE 'BDJ-OBJECTIVE-%'
            """), {'actor': actor_id, 'assessment': assessment_id,
                   'revision': revision,
                   'source': source_fingerprint}).mappings().one()
            session.rollback()
    except WorkflowHeld:
        raise
    except SQLAlchemyError:
        # Fail closed. An unreadable ledger is not evidence that a pass is
        # available, and offering one would risk a second dispatch.
        return {'contract': contract, 'eligible': False,
                'reason': 'UNAVAILABLE', 'attempts': 0, 'run_recorded': None}

    attempts = int(row['attempts'] or 0)
    if attempts == 0:
        return {'contract': contract, 'eligible': True, 'reason': 'NOT_STARTED',
                'attempts': 0, 'run_recorded': False}

    # An attempt exists, so the control is withheld whatever its outcome. Whether
    # it is still in flight only changes the wording: "in progress" tells the
    # reader to wait, "spent" tells them it is over. Neither re-offers dispatch.
    state = _objective_attempt_state(engine, actor_id, assessment_id,
                                     revision=revision,
                                     source_fingerprint=source_fingerprint,
                                     now=now)
    return {
        'contract': contract,
        'eligible': False,
        'reason': ('IN_PROGRESS'
                   if state in ('PROCESSING', 'RETURNED', 'VALIDATING')
                   else 'ATTEMPT_SPENT'),
        'attempts': attempts,
        'run_recorded': True,
        'execution_state': state,
    }


def _objective_attempt_state(engine, actor_id: UUID, assessment_id, *,
                             revision: int, source_fingerprint: str,
                             now=None) -> str | None:
    """The ledger state of the newest objective attempt for this source.

    Scoped by the same source identity as :func:`objective_generation_state`, and
    not by ``stage`` alone: a BDJ *source evaluation* also reserves under
    ``stage='BDJ'``, so a stage-wide read would report the wrong execution.
    """
    from datetime import datetime, timedelta, timezone
    moment = now or datetime.now(timezone.utc)
    try:
        with Session(engine) as session:
            restricted_scope(session, actor_id)
            row = session.execute(text("""
                SELECT a.reserved_at, rec.outcome AS receipt_outcome
                  FROM project1_ai.attempts a
                  JOIN project1_ai.runs r
                    ON r.id = a.run_id AND r.owner_user_id = a.owner_user_id
                  LEFT JOIN project1_ai.attempt_receipts rec
                    ON rec.run_id = a.run_id
                   AND rec.attempt_no = a.attempt_no
                   AND rec.owner_user_id = a.owner_user_id
                 WHERE a.owner_user_id = :actor
                   AND r.assessment_id = :assessment
                   AND r.assessment_revision = :revision
                   AND r.source_fingerprint = :source
                   AND a.stage = 'BDJ'
                   AND a.prompt_version LIKE 'BDJ-OBJECTIVE-%'
                 ORDER BY a.reserved_at DESC
                 LIMIT 1
            """), {'actor': actor_id, 'assessment': assessment_id,
                   'revision': revision,
                   'source': source_fingerprint}).mappings().one_or_none()
            session.rollback()
    except WorkflowHeld:
        raise
    except SQLAlchemyError:
        return None
    if row is None:
        return None
    if row['receipt_outcome'] is None:
        reserved_at = row['reserved_at']
        if reserved_at is not None and reserved_at.tzinfo is None:
            reserved_at = reserved_at.replace(tzinfo=timezone.utc)
        waited = (moment - reserved_at) if reserved_at is not None else timedelta(0)
        return 'PROCESSING' if waited <= in_flight_grace() else 'UNKNOWN_OUTCOME'
    if row['receipt_outcome'] == 'returned':
        return 'RETURNED'
    if row['receipt_outcome'] == 'unknown_outcome':
        return 'UNKNOWN_OUTCOME'
    return 'FAILED'


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

#: The milestones the interface may draw. Deliberately **four**, not five.
#:
#: ``DISPATCHED`` is absent because nothing durable records it. ``attempts`` has
#: no dispatch timestamp (verified against ``information_schema``: 9 columns,
#: ``reserved_at`` and no other time), and ``provider.last_execution['dispatched']``
#: is an in-process flag set only once the response headers arrive -- it dies
#: with the request and is never written to the ledger. A "Dispatched" tick
#: would assert a fact the system cannot prove, so the milestone is omitted
#: rather than faked (CP-PROG-03). Do not add it back without durable evidence.
MILESTONES = ('RESERVED', 'RETURNED', 'VALIDATED', 'PERSISTED')

#: How far each authoritative state has carried the rail, as
#: ``(completed_count, active_index)``. ``active_index`` is ``None`` when no
#: milestone is in progress; ``completed_count`` counts from the start of
#: :data:`MILESTONES`.
#:
#: These are projections of :data:`EXECUTION_STATES`, not a second state
#: machine: every entry is total over the states above, so an unknown state
#: falls back to "nothing proved" rather than to a guess.
_STATE_MILESTONES = {
    'BLOCKED': (0, None),
    'PROCESSING': (1, 1),        # Reserved proved; Returned is what we await
    'RETURNED': (2, 2),
    'VALIDATING': (2, 2),
    'PERSISTED': (4, None),
    'FAILED': (1, 1),
    'UNKNOWN_OUTCOME': (1, 1),
}


def milestones(state: str) -> list[dict]:
    """Per-milestone presentation status derived from one authoritative state.

    Statuses are ``COMPLETED`` / ``ACTIVE`` / ``PENDING`` / ``FAILED`` /
    ``UNKNOWN``. ``ACTIVE`` means "this is the step whose evidence has not
    arrived" -- it is never rendered as done, and never as a percentage.
    """
    completed, active = _STATE_MILESTONES.get(state, (0, None))
    out = []
    for index, name in enumerate(MILESTONES):
        if index < completed:
            status = 'COMPLETED'
        elif index == active:
            status = ('FAILED' if state == 'FAILED' else
                      'UNKNOWN' if state == 'UNKNOWN_OUTCOME' else 'ACTIVE')
        else:
            status = 'PENDING'
        out.append({'milestone': name, 'status': status})
    return out


#: How long a reservation may stand with no receipt before "in flight" becomes
#: "we do not know what happened". Derived from the configured provider timeout
#: plus a margin, so it tracks the deployment rather than a guess.
def in_flight_grace() -> 'timedelta':
    from datetime import timedelta
    return timedelta(seconds=int(settings.tokenharbor_timeout_seconds) + 30)


def provider_timeout_seconds() -> int:
    """The configured provider budget the grace period is derived from.

    Exposed so the status contract can *report* the number the deployment
    actually enforces instead of letting the client hardcode its own copy
    (the panel used to hardcode 90 s against a value clamped to 180 s).
    """
    return int(settings.tokenharbor_timeout_seconds)


#: Whether ``project1_ai.runs`` carries the objective dimension yet. The proposed
#: migration adds it; until it is applied the per-objective read must say it
#: cannot identify an execution rather than fall back to "the newest QG attempt",
#: which is what makes two objectives show each other's progress.
_RUN_OBJECTIVE_COLUMN: bool | None = None


def has_run_objective_column(session) -> bool:
    """Feature-detect the objective dimension, once per process.

    A missing column is not an error: it means the migration has not been
    applied. Callers use this to decide whether an objective-scoped read is
    *possible*, so the answer can be "not identifiable" instead of a guess.
    """
    global _RUN_OBJECTIVE_COLUMN
    if _RUN_OBJECTIVE_COLUMN is None:
        present = session.execute(text(
            "SELECT 1 FROM information_schema.columns"
            " WHERE table_schema='project1_ai' AND table_name='runs'"
            "   AND column_name='objective_id'")).first()
        _RUN_OBJECTIVE_COLUMN = present is not None
    return _RUN_OBJECTIVE_COLUMN


def is_stale(recorded_revision, current_revision, *,
             revision_bound: bool = True) -> bool:
    """Whether an execution belongs to a superseded confirmation.

    ``revision_bound`` is false for stages whose run records the QG sentinel
    ``0`` instead of a revision. Comparing that sentinel with a real revision
    would report a *current* execution as historical, so those stages are never
    called stale here; their currency is a source-fingerprint comparison made
    elsewhere.
    """
    if not revision_bound:
        return False
    if current_revision is None or recorded_revision is None:
        return False
    return int(recorded_revision) != int(current_revision)


def execution_status(engine, actor_id: UUID, assessment_id: UUID, *,
                     stage: str, now=None, current_revision: int | None = None,
                     revision_bound: bool = True,
                     objective_id: str | None = None) -> dict:
    """The newest attempt for one stage, as the ledger records it.

    ``state`` is ledger-only: it cannot tell whether a returned result was
    written to its domain table, because that table is not the ledger. The
    caller upgrades ``RETURNED`` to ``VALIDATING`` or ``PERSISTED`` once it has
    looked, which keeps the two facts separable instead of guessing here.

    ``current_revision`` turns the read into an *identity* check. Without it the
    newest attempt for the stage is returned whatever revision produced it, so a
    run made before the owner re-confirmed M2 could be presented as the current
    execution (CP-PROG-01). When supplied and different from the attempt's own
    ``assessment_revision``, the reading is marked ``stale`` -- but the state is
    still returned unchanged, because a superseded execution really did happen
    and erasing it would destroy evidence rather than protect the owner.

    ``revision_bound`` says whether revision is the binding assertion for this
    stage. It is **not** for QG: ``ensure_qg_run`` writes ``assessment_revision``
    as ``0`` on purpose, because QG facts bind to the confirmed-facts
    fingerprint rather than to an M2 revision. Comparing that sentinel with a
    real revision marked every QG execution stale, which is a false statement
    about a current execution. QG therefore reports
    ``currency_basis='SOURCE_FINGERPRINT'`` and is never called stale by this
    function; its currency is a fingerprint comparison, not a revision one.

    ``objective_id`` scopes the read to one approved additional research
    objective. It requires the objective dimension on ``runs`` (see the proposed
    migration). Without that column the read returns
    ``OBJECTIVE_IDENTITY_NOT_RECORDED`` rather than the newest QG attempt, since
    "newest" is exactly how one objective ends up displaying another's progress.
    """
    from datetime import datetime, timedelta, timezone

    moment = now or datetime.now(timezone.utc)
    try:
        with Session(engine) as session:
            restricted_scope(session, actor_id)
            params = {'actor': actor_id, 'assessment': assessment_id,
                      'stage': stage}
            objective_clause = ''
            if objective_id is not None:
                if not has_run_objective_column(session):
                    session.rollback()
                    # Not an error and not "nothing ran": the ledger simply has
                    # no objective dimension yet, so an objective-scoped answer
                    # cannot be given without borrowing another objective's run.
                    return {'stage': stage, 'state': 'BLOCKED',
                            'reason': 'OBJECTIVE_IDENTITY_NOT_RECORDED',
                            'run_id': None, 'attempt_no': None,
                            'attempts_reserved': 0, 'reserved_at': None,
                            'receipt_outcome': None, 'receipt_at': None,
                            'assessment_revision': None, 'stale': False,
                            'revision_bound': revision_bound,
                            'currency_basis': 'SOURCE_FINGERPRINT',
                            'objective_id': objective_id,
                            'identity_basis': 'UNAVAILABLE',
                            'milestones': milestones('BLOCKED')}
                objective_clause = ' AND r.objective_id = :objective'
                params['objective'] = objective_id
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
            """ + objective_clause + """
                 ORDER BY a.reserved_at DESC
                 LIMIT 1
            """), params).mappings().one_or_none()
            session.rollback()
    except WorkflowHeld:
        raise
    except SQLAlchemyError:
        raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE') from None

    if row is None:
        return {'stage': stage, 'state': 'BLOCKED', 'reason': 'NO_ATTEMPT_RESERVED',
                'run_id': None, 'attempt_no': None, 'attempts_reserved': 0,
                'reserved_at': None, 'receipt_outcome': None,
                'receipt_at': None, 'assessment_revision': None,
                'stale': False, 'revision_bound': revision_bound,
                'currency_basis': ('ASSESSMENT_REVISION' if revision_bound
                                   else 'SOURCE_FINGERPRINT'),
                'objective_id': objective_id,
                'identity_basis': ('OBJECTIVE' if objective_id is not None
                                   else 'STAGE'),
                'milestones': milestones('BLOCKED')}

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

    # Identity check (CP-PROG-01). A run recorded at a different revision than
    # the one the owner is now looking at belongs to a superseded confirmation;
    # its result may still be true of the old facts, so the state is preserved
    # and only qualified. `stale` is a qualifier, not a state, precisely so that
    # marking an execution "not current" does not erase the evidence it carries.
    #
    # Only where revision is the binding assertion. QG writes the sentinel 0, so
    # applying this there compared 0 with the real revision and called a current
    # execution stale on every read -- a false statement, not a conservative one.
    recorded_revision = row['assessment_revision']
    stale = is_stale(recorded_revision, current_revision,
                     revision_bound=revision_bound)

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
        'assessment_revision': recorded_revision,
        'stale': stale,
        'revision_bound': revision_bound,
        'currency_basis': ('ASSESSMENT_REVISION' if revision_bound
                           else 'SOURCE_FINGERPRINT'),
        'objective_id': objective_id,
        'identity_basis': ('OBJECTIVE' if objective_id is not None else 'STAGE'),
        'milestones': milestones(state),
    }


def refine_with_domain(status: dict, *, persisted: int,
                       pending_validation: int,
                       attributable: bool = True) -> dict:
    """Upgrade a ledger ``RETURNED`` once the domain table has been consulted.

    The ledger records that the provider answered. Whether the governed write
    landed is a different fact, held by a different table. Keeping the upgrade
    here — rather than inside :func:`execution_status` — is what lets the
    interface say "returned but not persisted" instead of claiming a persistence
    that never happened.

    ``attributable`` is the identity gate (CP-PROG-01). It is true only when the
    domain rows can be joined to *this* attempt. ``m2_qg_candidates`` carries
    ``run_id`` and ``attempt_no``, so a QG count can be attempt-bound.
    ``m2_bdj_objective_proposals`` carries neither — its ``evaluation_id`` is a
    fresh ``uuid4()`` per evaluation (verified: 0 rows join to
    ``project1_ai.runs.id``), so an assessment-wide proposal count cannot prove
    that the current attempt wrote anything.

    When ``attributable`` is false the count is still reported (it is a true
    statement about the assessment) but it can no longer complete the
    ``PERSISTED`` milestone: the state stays ``RETURNED`` with the explicit
    reason ``PERSISTENCE_UNATTRIBUTABLE``. This fails closed, which is the point
    — a historical proposal must never mark a new attempt as persisted.
    """
    domain = {'persisted': persisted, 'pending_validation': pending_validation,
              'attributable': attributable}
    if status.get('state') != 'RETURNED':
        return {**status, 'domain': domain}
    if not attributable:
        return {**status, 'state': 'RETURNED',
                'reason': 'PERSISTENCE_UNATTRIBUTABLE',
                'domain': domain,
                'milestones': milestones('RETURNED')}
    if persisted <= 0:
        return {**status, 'state': 'RETURNED', 'reason': 'RETURNED_NOT_PERSISTED',
                'domain': domain, 'milestones': milestones('RETURNED')}
    if pending_validation > 0:
        return {**status, 'state': 'VALIDATING', 'reason': 'PERSISTED_PENDING_VALIDATION',
                'domain': domain, 'milestones': milestones('VALIDATING')}
    return {**status, 'state': 'PERSISTED', 'reason': 'PERSISTED_AND_VALIDATED',
            'domain': domain, 'milestones': milestones('PERSISTED')}
