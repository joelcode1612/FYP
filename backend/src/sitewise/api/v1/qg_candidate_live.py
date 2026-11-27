"""Authenticated Direct-QG generation over the governed candidate adapter.

What this route is, and is not
------------------------------
It is the HTTP surface for the *same* attempt the operator script makes: the
governed ``QgCandidateAdapter``, the ``QgLiveRunner``, the append-only attempt
ledger, the single-use authorization row and ``m2_qg_candidates``. It is not a
second AI path — there is no prompt here, no provider call here and no direct
table write here. Every one of those is the existing component.

Why it exists
-------------
Generation was previously reachable only from a script. Stage 4 reads
``m2_qg_candidates`` over HTTP, so a candidate could be reviewed but never
produced through the application. That is the gap this closes.

What it refuses
---------------
* No provider configured, or no authorization row → a named hold, not a
  simulated candidate.
* A business context the workflow no longer calls current → refused before the
  adapter runs, by the same shared gate the script uses.
* Scientific acceptance, fielding and publication stay false. A candidate is a
  candidate.
"""
from __future__ import annotations

import logging

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, ConfigDict, Field

from sitewise.core.config import (
    MAX_TOKENHARBOR_COST_CEILING_USD, provider_cost_ceiling_usd,
    provider_timeout_seconds, settings,
)
from sitewise.dependencies import AuthenticatedUser, require_entrepreneur
from sitewise.project1 import qg_authorization, source_currentness
from sitewise.project1 import measurement_library as ml
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.objective_admission import admission_state
from sitewise.project1.qg_binding import resolve_authorized
from sitewise.project1.qg_generation_eligibility import (
    derive_objective_authority,
)
from sitewise.project1.qg_generation_eligibility import (
    evaluate as evaluate_eligibility,
)
from sitewise.project1.qg_candidate_adapter import (
    LIVE_PROVIDER, LIVE_SCOPE, QgCandidateAdapter,
)
from sitewise.project1.qg_live import QgLiveRunner
from sitewise.project1.qg_live_candidate import live_fixed_option_generator
from sitewise.project1.provider import ENDPOINT as PROVIDER_ENDPOINT
from sitewise.project1.provider import MODEL as PROVIDER_MODEL
from sitewise.services.ports.business_context_store_port import ContextActor
from sitewise.domain import rbac
from sitewise.api.v1.project1_objective_proposals import (
    AuthorizedLedgerEngine, AuthorizedProposalStorageEngine,
    get_objective_context_service,
)

router = APIRouter()

Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]
ContextService = Annotated[object, Depends(get_objective_context_service)]

#: Codes that mean "the caller must change something" rather than "the server
#: failed". Everything else surfaces as a 503 hold, which is the honest answer
#: for a governance refusal.
_CONFLICT_CODES = {
    'QG_BINDING_ADMISSION_NOT_FOUND': 404,
    'QG_BINDING_CONTEXT_NOT_FOUND': 404,
    # Contract 2.1: the objective is derived from the owner's approval, so a
    # missing or stale approval is a state the owner must change.
    'QG_OBJECTIVE_PROPOSAL_NOT_FOUND': 404,
    'QG_OBJECTIVE_NOT_APPROVED': 409,
    'QG_OBJECTIVE_DECISION_NOT_APPROVED': 409,
    'QG_OBJECTIVE_DECIDED_BY_OTHER': 403,
    'QG_OBJECTIVE_ASSESSMENT_MISMATCH': 409,
    'QG_OBJECTIVE_DECISION_BINDING_DRIFT': 409,
    'QG_OBJECTIVE_NOT_CONFIRMED': 409,
    'QG_OBJECTIVE_REVISION_STALE': 409,
    'QG_OBJECTIVE_CONTEXT_NOT_FOUND': 404,
    'QG_OBJECTIVE_CONTEXT_NOT_CURRENT': 409,
    'QG_OBJECTIVE_ID_MISMATCH': 409,
    'QG_PROPOSED_MEASUREMENT_FORMAT_REQUIRED': 409,
    'QG_POPULATION_NOT_DECLARED': 409,
    # DD-054: one controlled recovery is permitted, and only one. These are
    # states the caller must resolve, not server failures, so they are 409 rather
    # than the default 503 — an operator should not be told to retry.
    'QG_RECOVERY_PRIOR_NOT_FOUND': 404,
    'QG_RECOVERY_PRIOR_NOT_SPENT': 409,
    'QG_RECOVERY_BINDING_MISMATCH': 409,
    'QG_RECOVERY_CHAIN_REFUSED': 409,
    'QG_AUTHORITY_DECISION_REQUIRED': 409,
    'QG_AUTHORITY_KIND_REQUIRED': 409,
    # The provider answered, but not in a form the contract can accept. These
    # are split because the fixes are different: content that is not JSON is a
    # transport/provider contract break, while JSON that fails validation is a
    # prompt or schema problem. Both are 503: the caller's request was fine.
    'PROVIDER_NON_JSON_CONTENT': 503,
    'PROVIDER_SCHEMA_MISMATCH': 503,
    'QG_AUTHORIZATION_NOT_FOUND': 404,
    'QG_BINDING_ADMISSION_NOT_ADMITTED': 409,
    'QG_BINDING_CONTEXT_NOT_ADMITTED': 409,
    'QG_BINDING_ADMISSION_ASSESSMENT_MISMATCH': 409,
    'QG_AUTHORIZATION_BINDING_MISMATCH': 409,
    'QG_AUTHORIZATION_CONSUMED': 409,
    'QG_AUTHORIZATION_EXPIRED': 409,
    # The owner's consent grant authorises exactly one attempt. A second
    # dispatch against the same grant is a state the caller must resolve by
    # granting again, not a server failure (DD-044).
    'QG_CONSENT_ALREADY_CONSUMED': 409,
    'QG_CONSENT_NOT_FOUND': 404,
    'QG_CONSENT_OWNER_MISMATCH': 403,
    'PROVIDER_PROMPT_NOT_REGISTERED': 409,
    # DD-034: the attempt is refused because the *authority* does not cover it,
    # which is a state the caller must change (grant the QG permission, or issue
    # a correctly bound authorization), not a server failure.
    'QG_AUTHORIZATION_PURPOSE_MISMATCH': 409,
    'QG_AUTHORIZATION_SCOPE_MISMATCH': 409,
    'QG_AUTHORIZATION_CONSENT_MISMATCH': 409,
    'QG_AUTHORIZATION_CONSENT_NOT_RECORDED': 409,
    'QG_AUTHORIZATION_CONSENT_PAIR_REQUIRED': 409,
    'AI_PROCESSING_QG_CONSENT_ABSENT': 409,
    'AI_PROCESSING_QG_CONSENT_REQUIRED': 409,
    'AI_PROCESSING_QG_CONSENT_VERSION_UNSUPPORTED': 409,
    'AI_PROCESSING_QG_CONSENT_PURPOSE_MISMATCH': 409,
    'AI_PROCESSING_QG_CONSENT_MODEL_MISMATCH': 409,
    'AI_PROCESSING_QG_CONSENT_ENDPOINT_MISMATCH': 409,
    'AI_PROCESSING_QG_CONSENT_TAMPERED': 409,
    'AI_PROCESSING_QG_CONSENT_OWNER_MISMATCH': 409,
    'QG_LIVE_PURPOSE_NOT_AUTHORIZED': 409,
    # Contract 2.1 persistence is additive and lives in migration
    # ``20261124_05_objective_authority``. Until that migration is applied to
    # the deployment's database, a decision-backed authorization cannot be
    # written, so issuance answers this instead of a raw UndefinedColumn.
    'QG_AUTHORITY_SCHEMA_NOT_ADOPTED': 503,
    'QG_AUTHORIZATION_AUTHORITY_REQUIRED': 409,
    'QG_AUTHORIZATION_OBJECTIVE_KIND_REQUIRED': 409,
    'QG_AUTHORIZATION_MEASUREMENT_BASIS_REQUIRED': 409,
    'QG_AUTHORIZATION_MEASUREMENT_BASIS_INCONSISTENT': 409,
    'QG_AUTHORIZATION_DECISION_NOT_FOUND': 403,
    'QG_AUTHORIZATION_DECISION_NOT_APPROVED': 409,
    'QG_AUTHORIZATION_DECISION_STALE': 409,
}


class GenerationRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')

    confirmation_id: UUID
    context_id: UUID
    # Contract 2.1 identity is ``proposal:<uuid>`` — 45 characters — so the old
    # 40-character ceiling refused every additional objective before the request
    # reached the authority check. The column has always been varchar(64).
    objective_id: str = Field(min_length=1, max_length=64)
    proposal_id: UUID
    authorization_id: UUID
    prompt_key: str = 'QG_FIXED_OPTION'
    stimulus: dict | None = None
    # Only used when no approved measurement exists, where there is no format to
    # inherit. Validated against the five supported formats by the adapter.
    response_format: str | None = None


def _held(exc: WorkflowHeld) -> HTTPException:
    code = str(exc)
    status = _CONFLICT_CODES.get(code, 503)
    return HTTPException(status, detail={'code': code,
                                         'message': 'The Direct-QG attempt was refused.'})


def _as_text(value):
    """Render an identifier for a JSON refusal body, or ``None``."""
    return None if value is None else str(value)


#: Refusals that mean "this act has already used its one attempt". They are the
#: only refusals for which a recovery is the correct next step, so they are the
#: only ones that carry recovery facts.
_RECOVERY_REFUSALS = frozenset({
    'QG_AUTHORIZATION_ALREADY_SPENT',
    'QG_AUTHORIZATION_CONSUMED',
    'QG_CONSENT_ALREADY_CONSUMED',
})


def _recovery_facts(engine, *, actor, assessment_id, confirmation_id,
                    authority, ceiling: float) -> dict:
    """What a separate recovery of this act would require, read and not granted.

    A spent attempt refuses with a code that says "you may not" and nothing
    about what is permitted instead. The owner's recovery policy is explicit —
    a new attempt is allowed only as a *separately authorised* act — so the
    facts needed to authorise it are attached to the refusal rather than left to
    be inferred from a status code. Nothing here creates consent or issues an
    authorization; it is a read.
    """
    decision = (authority or {}).get('decision') or {}
    decision_id = decision.get('decision_id')
    revision = (authority or {}).get('confirmation_revision')
    if decision_id is None or revision is None:
        # Without the approval identity the read cannot be scoped, and a
        # recovery reported without a scope would be a claim this route cannot
        # stand behind.
        return {'available': False, 'reason': 'QG_RECOVERY_AUTHORITY_UNKNOWN'}
    try:
        state = qg_authorization.recovery_state(
            engine, actor_id=actor, assessment_id=assessment_id,
            confirmation_id=confirmation_id,
            assessment_revision=int(revision),
            objective_decision_id=decision_id)
    except WorkflowHeld as exc:
        # Reporting the refusal must never replace it with a different one.
        return {'available': False, 'reason': str(exc)}
    return {
        'available': bool(state['recovery_available']),
        'prior_authorization_id': state['prior_authorization_id'],
        'already_requested': state['recovery_already_issued'],
        'consent_grant_available': state['consent_grant_available'],
        # ``None`` when no recovery can be requested right now; otherwise the
        # exact request field and value, so the caller does not have to derive
        # an identifier the server already knows.
        'blocked_by': state['blocked_by'],
        'request': ({'recovery_of': state['prior_authorization_id']}
                    if state['can_request'] else None),
        'cost_ceiling_usd': ceiling,
    }


#: Content-free provider metadata. Never add prompt text, message content,
#: response bodies, headers or credentials here: the purpose is to explain what
#: happened without widening disclosure.
_PROVIDER_PROVENANCE_KEYS = (
    'model_requested', 'model_returned', 'max_tokens', 'http_status',
    'usage', 'finish_reason', 'identity_verified', 'schema_validation',
    'request_sha256', 'response_sha256', 'provider_reported_cost',
    'cost_currency', 'failure_code', 'failure_detail', 'run_id',
    'attempt_no', 'prompt_key', 'prompt_version', 'prompt_sha256',
)


def _provider_provenance(runner, *, ceiling: float) -> dict:
    """The effective provider settings and outcome of exactly this attempt."""
    execution = getattr(runner, 'last_execution', None) or {}
    return {
        'cost_ceiling_usd': ceiling,
        **{key: execution.get(key) for key in _PROVIDER_PROVENANCE_KEYS},
    }


def _dispatch_evidence(execution: dict) -> bool:
    """True when this attempt actually left the process and may have been billed.

    ``dispatched`` is set at the edge immediately before the socket is used and
    ``http_status`` once a response arrives. Either one is evidence that the
    peer was reached; ``dispatch_attempted`` alone means the request never left,
    which is a different and equally reportable fact.

    This is a question about the *attempt*, not about which layer refused it.
    Gating the provider block on the refusal code's prefix conflated the two:
    when the model answered HTTP 200 and the adapter then refused the answer,
    the refusal body said nothing at all about the call that had just been paid
    for, so three genuine dispatches could not be reconstructed afterwards
    (DD-057).
    """
    # ``last_execution`` is created when an attempt starts and is never created
    # for a refusal that happens before dispatch, so a non-empty record is
    # itself the evidence. The individual keys only say how far it got.
    return bool(execution)


def _record_refusal(exc, *, assessment_id, authorization_id, runner) -> None:
    """Leave one durable line naming what refused, and whether money was spent.

    The refusal body answers the caller and then disappears with the request.
    The receipt records the transport outcome but not which adapter gate
    refused a schema-valid answer, so a 409 was previously a dead end: the
    status alone cannot discriminate between the gates that follow a
    successful dispatch. One line, content-free, makes the next attempt
    diagnosable from the log without widening what is stored.
    """
    execution = getattr(runner, 'last_execution', None) or {}
    logging.getLogger('sitewise').warning(
        'direct-qg refused code=%s assessment=%s authorization=%s '
        'dispatched=%s http_status=%s model_returned=%s finish_reason=%s',
        exc, assessment_id, authorization_id,
        execution.get('dispatched'), execution.get('http_status'),
        execution.get('model_returned'), execution.get('finish_reason'))


#: The three columns contract 2.1 adds to the two QG tables. Their presence is
#: the *only* reliable statement that the deployment has adopted the
#: objective-authority relationship; a code path cannot infer it from a feature
#: flag, because the column is what the INSERT needs.
_DECISION_AUTHORITY_COLUMNS = ('objective_decision_id', 'objective_kind',
                               'measurement_basis')


def _decision_authority_adopted(engine) -> bool:
    """True when the 2.1 authority columns exist on both QG tables."""
    from sqlalchemy import text
    with engine.connect() as conn:
        rows = conn.execute(text(
            "SELECT table_name, column_name"
            "  FROM information_schema.columns"
            " WHERE table_schema = 'public'"
            "   AND table_name IN ('m2_qg_authorizations', 'm2_qg_candidates')"
            "   AND column_name = ANY(:cols)"
        ), {'cols': list(_DECISION_AUTHORITY_COLUMNS)}).all()
    present = {(r[0], r[1]) for r in rows}
    return all(('m2_qg_authorizations', col) in present
               and ('m2_qg_candidates', col) in present
               for col in _DECISION_AUTHORITY_COLUMNS)


@router.get('/assessments/{assessment_id}/qg-candidates/recovery')
def read_recovery_state(assessment_id: UUID, user: Owner, response: Response,
                        proposal_id: UUID, context_id: UUID,
                        m2_engine: AuthorizedProposalStorageEngine):
    """Whether a separately authorised recovery of this objective is possible.

    A spent attempt refuses with ``QG_AUTHORIZATION_ALREADY_SPENT``, which says
    "you may not" and nothing about what *is* permitted. The owner's recovery
    policy allows one further attempt, but only as an act the owner explicitly
    authorises — so the interface has to be able to show what that act would be
    before it is requested.

    Read-only by construction: it issues no authorization, reserves no attempt,
    creates no consent and opens no socket. ``recovery_state`` performs the only
    write-capable step, and it performs none.

    The binding is derived from the owner's own approval, not from query
    parameters, so this cannot be used to read another assessment's or another
    objective's attempts.
    """
    from sitewise.project1.qg_generation_eligibility import (
        derive_objective_authority,
    )

    response.headers['Cache-Control'] = 'no-store'
    authority = derive_objective_authority(
        m2_engine, actor_id=user.user_id, assessment_id=assessment_id,
        proposal_id=proposal_id, context_id=context_id)
    decision = authority.get('decision') or {}
    state = qg_authorization.recovery_state(
        m2_engine, actor_id=user.user_id, assessment_id=assessment_id,
        confirmation_id=authority['confirmation_id'],
        assessment_revision=int(authority['confirmation_revision']),
        objective_decision_id=decision.get('decision_id'))
    return {
        'assessment_id': str(assessment_id),
        'objective_id': str(authority['objective_id']),
        'recovery_available': state['recovery_available'],
        'prior_authorization_id': state['prior_authorization_id'],
        'already_requested': state['recovery_already_issued'],
        'consent_grant_available': state['consent_grant_available'],
        'blocked_by': state['blocked_by'],
        # The exact body to send to the generate route. Absent when no recovery
        # can be requested, so a caller cannot present an action that the next
        # step would refuse.
        'request': ({'recovery_of': state['prior_authorization_id']}
                    if state['can_request'] else None),
        'cost_ceiling_usd': provider_cost_ceiling_usd(),
    }


@router.post('/assessments/{assessment_id}/qg-candidates')
def generate_candidate(assessment_id: UUID, payload: GenerationRequest,
                       user: Owner, response: Response,
                       m2_engine: AuthorizedProposalStorageEngine,
                       ledger_engine: AuthorizedLedgerEngine,
                       context_service: ContextService):
    """One governed attempt. Exactly one candidate, or a named refusal."""
    response.headers['Cache-Control'] = 'no-store'
    if not settings.tokenharbor_enabled:
        # The application ships with the provider off. Enabling it is a
        # deployment decision, never a request parameter.
        raise HTTPException(503, detail={
            'code': 'PROVIDER_NOT_CONFIGURED',
            'message': 'TokenHarbour is not enabled for this deployment.'})

    # A ceiling nothing reads is a comment. This refuses an attempt whose
    # configured budget the deployment has not adopted, before any work is done.
    ceiling = provider_cost_ceiling_usd()
    if ceiling is None:
        raise HTTPException(503, detail={
            'code': 'PROVIDER_COST_CEILING_NOT_ADOPTED',
            'message': 'The per-attempt cost ceiling is unset or above the '
                       f'adopted maximum of USD {MAX_TOKENHARBOR_COST_CEILING_USD:.2f}.'})

    actor = user.user_id
    runner = None
    try:
        # The authority is derived from the owner's approval, not from a manual
        # admission. This is the contract 2.1 entry point: a proposal the owner
        # approved is sufficient, and no separate admission step is offered.
        authority = derive_objective_authority(
            m2_engine, actor_id=actor, assessment_id=assessment_id,
            proposal_id=payload.proposal_id, context_id=payload.context_id)
        if str(authority['objective_id']) != str(payload.objective_id):
            # The caller must not be able to name one objective while the
            # approval authorises another.
            raise WorkflowHeld('QG_OBJECTIVE_ID_MISMATCH')
        binding = resolve_authorized(
            m2_engine, actor, assessment_id=assessment_id,
            proposal_id=payload.proposal_id, context_id=payload.context_id,
            authority=authority, prompt_key=payload.prompt_key,
            stimulus=payload.stimulus)

        context_actor = ContextActor(user.user_id,
                                     rbac.canonical_role(user.role))
        verdict = source_currentness.current_source(
            m2_engine, service=context_service, assessment_id=assessment_id,
            confirmation_id=payload.confirmation_id, actor=context_actor)
        refusal = source_currentness.refusal(
            verdict, authorized_context_packet_hash=binding['context_packet_hash'])
        if refusal is not None:
            raise HTTPException(409, detail={
                'code': refusal,
                'message': 'The business context this objective was admitted '
                           'against is not the current source.',
                # Coerced deliberately: a refusal that fails to serialise is
                # returned as a 500, which hides the governance reason behind a
                # server error and reads to the caller like a bug.
                'current_context_id': _as_text(verdict.get('context_id')),
                'authorized_context_id': _as_text(binding['context_id'])})

        # The authorization row is a ``public.m2_*`` row with owner-scope RLS, so
        # it is read through the M2 principal — the same engine the adapter's
        # ``verify`` and ``consume`` use. Reading it through the project1_ai
        # ledger engine fails closed with RESTRICTED_PRINCIPAL_REQUIRED, because
        # that login may not assume ``p1_m2_runtime``.
        # An early existence check, so a missing row answers 404 before the
        # consent lookup can answer 409. The authority itself is re-read at
        # dispatch by ``runner_authority`` below; this read is not the authority.
        authorization = qg_authorization.read(
            m2_engine, actor_id=actor,
            authorization_id=payload.authorization_id)
        if authorization is None:
            raise WorkflowHeld('QG_AUTHORIZATION_NOT_FOUND')

        # The runner's authority is now *derived*, not assembled here. It reads
        # the persisted authorization row, the persisted QG consent block and
        # the prompt binding, and refuses if any of them disagrees. Before this
        # change the route wrote ``purpose: QG_PURPOSE`` into a local dict and
        # the runner compared it to itself, so the check could never fail
        # (DD-034).
        consent = qg_authorization.consent_block(
            m2_engine, actor_id=actor, assessment_id=assessment_id,
            confirmation_id=payload.confirmation_id,
            revision=binding['assessment_revision'],
            # The grant is bound to the objective the owner approved, so a
            # permission recorded for a different objective is not read here.
            objective_decision_id=authorization['objective_decision_id'])
        if consent is None:
            raise WorkflowHeld('AI_PROCESSING_QG_CONSENT_ABSENT')

        def authority() -> dict:
            derived = qg_authorization.runner_authority(
                m2_engine, actor_id=actor,
                authorization_id=payload.authorization_id,
                consent_lookup=lambda: consent,
                provider=LIVE_PROVIDER, model=PROVIDER_MODEL,
                endpoint=PROVIDER_ENDPOINT,
                packet_source_fingerprint=binding['facts'].fingerprint,
                max_attempts=1,
                # The adapter reserves this attempt before dispatch
                # (``qg_attempt.reserve``), so by the time this verifier runs
                # the row is spent by the attempt in flight. Without this the
                # ordering fix would make every dispatch refuse itself.
                attempt_reserved=True)
            # Budget and transport limits are deployment settings, not grants, so
            # they are added after the derived authority and can never override
            # its purpose, scope or attempt budget.
            return {**derived,
                    'cost_ceiling_usd': ceiling,
                    'timeout_seconds': provider_timeout_seconds()}

        runner = QgLiveRunner(engine=ledger_engine, authorization_verifier=authority)
        generate = live_fixed_option_generator(
            runner, policy_version=binding['policy_version'],
            prompt_key=payload.prompt_key)
        adapter = QgCandidateAdapter(
            engine=m2_engine, actor_id=actor,
            store=ml.PostgresMeasurementStore(m2_engine, actor),
            admission_lookup=lambda pid, fp: admission_state(
                m2_engine, pid, source_fingerprint=fp, actor_id=actor),
            generate=generate, scope=LIVE_SCOPE,
            source_check=lambda: verdict)

        envelope = adapter.prepare(
            assessment_id=binding['assessment_id'],
            confirmation_id=binding['confirmation_id'],
            assessment_revision=binding['assessment_revision'],
            source_fingerprint=binding['source_fingerprint'],
            context_id=binding['context_id'],
            context_packet_hash=binding['context_packet_hash'],
            objective_id=binding['objective_id'],
            objective_text=binding['objective_text'],
            proposal_id=binding['proposal_id'], packet=binding['packet'],
            stimulus=dict(payload.stimulus or {}),
            authorization_id=str(payload.authorization_id),
            prompt_version=binding['prompt'].version,
            prompt_sha256=binding['prompt'].fingerprint,
            population=binding['measurement'].get('population'),
            authority=authority,
            response_format=payload.response_format)
    except WorkflowHeld as exc:
        refusal = _held(exc)
        # A provider failure is the one refusal an operator cannot diagnose from
        # the code alone: "outcome unknown" says nothing about whether the peer
        # was ever reached. The runner's execution record is content-free
        # (model ids, status, failure class, token counts), so it is attached
        # rather than left in the process that is about to forget it.
        #
        # The test is "did this attempt reach the provider", not "does the code
        # look like a provider code". An adapter refusal after a 200 is exactly
        # the case that needs the evidence: the call happened, it was billed,
        # and the answer was rejected here.
        execution = getattr(runner, 'last_execution', None) or {}
        if _dispatch_evidence(execution):
            # ``null`` is kept rather than dropped: "no HTTP status was received"
            # is the fact that separates a connection failure from a rejection,
            # and an absent key would read as "not recorded".
            refusal.detail['provider'] = _provider_provenance(
                runner, ceiling=ceiling)
        # ``binding`` is resolved inside the try, so it may not exist yet when a
        # refusal comes from the authority or the binding itself. The path
        # parameter is the same assessment id and is always bound.
        _record_refusal(exc, assessment_id=assessment_id,
                        authorization_id=payload.authorization_id, runner=runner)
        raise refusal from None
    # The adapter's envelope carries the governed outcome; this block carries
    # the provider-side facts needed to verify the single real call (output cap,
    # completion tokens, stop reason and identities) without exposing content.
    envelope['provider_execution'] = _provider_provenance(
        runner, ceiling=ceiling)
    return envelope


class AutomaticGenerationRequest(BaseModel):
    """One governed attempt derived entirely from an approved objective.

    The caller names the objective it approved and nothing else that decides
    authority: no admission id, no authorization id, no measurement id. Those
    are the server's conclusions, not the caller's assertions.
    """

    model_config = ConfigDict(extra='forbid')

    confirmation_id: UUID
    context_id: UUID
    proposal_id: UUID
    prompt_key: str = 'QG_FIXED_OPTION'
    stimulus: dict | None = None
    # Required only when no approved measurement exists. The adapter refuses a
    # proposed basis without a supported format rather than inventing one.
    response_format: str = 'MULTIPLE_CHOICE'
    #: The spent authorization this request recovers from (DD-054).
    #:
    #: Absent for an ordinary first attempt. Present only when the owner has
    #: been told, by name, that a specific attempt failed technically and has
    #: chosen to authorise a separate recovery of *that* attempt. The server
    #: does not derive it: a recovery the caller did not ask for is a retry, and
    #: a retry is what the single-use rules exist to prevent.
    recovery_of: UUID | None = None


#: How many objectives one batch may carry. Six is the product's own ceiling on
#: additional objectives; the extra headroom exists so a future objective class
#: does not need a contract bump, not so a caller can fan out arbitrarily.
MAX_BATCH_OBJECTIVES = 12

#: Identifies the batch envelope. A consumer expecting a single-objective
#: response reads a different contract rather than a shape that changed meaning.
BATCH_CONTRACT = 'sitewise-qg-batch-generation/1'

#: Refusal codes that mean "this objective's one attempt has been taken".
#:
#: Repeated in Python on purpose: the Dart transport has its own copy for the
#: single-objective route, and a shared constant across the wire does not exist.
#: Kept as an explicit set so a new refusal code cannot silently start reading as
#: a retryable failure.
_SPENT_CODES = frozenset({
    'QG_AUTHORIZATION_ALREADY_SPENT',
    'QG_AUTHORIZATION_CONSUMED',
    'QG_CONSENT_ALREADY_CONSUMED',
})


class BatchGenerationRequest(BaseModel):
    """Generate for several approved objectives from one owner action.

    The caller sends identities it already owns — the objectives it selected and
    the confirmation it is looking at. It never sends an admission id, an
    authorization id, a measurement id or an owner answer: those are the server's
    conclusions, and accepting them from the client would let a caller supply
    "confirmed" facts that were never confirmed.
    """

    model_config = ConfigDict(extra='forbid')

    confirmation_id: UUID
    context_id: UUID
    proposal_ids: list[UUID] = Field(min_length=1, max_length=MAX_BATCH_OBJECTIVES)
    prompt_key: str = 'QG_FIXED_OPTION'
    response_format: str = 'MULTIPLE_CHOICE'


def _attempt_one_objective(*, assessment_id: UUID,
                           payload: AutomaticGenerationRequest, user,
                           m2_engine, ledger_engine, context_service,
                           ceiling: float) -> dict:
    """One governed objective attempt, shared by the single and batch routes.

    This is the body the single-objective route has always run: derive the
    authority, evaluate eligibility, issue exactly one single-use
    authorization, then hand the work to the existing adapter. Extracting it
    is what lets a batch reuse the *same* governance per objective instead of
    growing a second path that could drift from this one.

    It raises ``HTTPException`` on refusal exactly as the route used to, so the
    single route's behaviour is unchanged; the batch route is the caller that
    catches it and continues.
    """
    actor = user.user_id
    runner = None
    # Bound before the try so the refusal path can tell "no approval was ever
    # derived" from "the approval is known and the attempt was spent".
    authority: dict | None = None
    # Bound before the try for the same reason: a refusal that happens before
    # issuance (eligibility, binding, consent) has no authorization to name, and
    # the refusal logger must not fail on that absence.
    authorization_id: str | None = None
    try:
        # 1-2. Authority and eligibility. ``authorization_present=None`` is
        # deliberate: G-06 is the step this route is about to perform, so asking
        # it beforehand would make the gate impossible to pass.
        eligibility = evaluate_eligibility(
            m2_engine, actor_id=actor, assessment_id=assessment_id,
            proposal_id=payload.proposal_id, context_id=payload.context_id)
        blocking = [c for c in eligibility['generation_checks']
                    if c['check_id'] != 'G-06' and c['status'] != 'PASS']
        if blocking:
            first = blocking[0]
            raise HTTPException(409, detail={
                'code': first['reason_code'] or 'QG_GENERATION_CHECK_FAILED',
                'message': f"{first['check_id']}: {first['title']}",
                'check_id': first['check_id'],
                'generation_status': eligibility['generation_status'],
                'scientific_status': eligibility['scientific_status']})

        # 3. Schema adoption. A decision-backed authorization cannot be written
        # without these columns, and an INSERT that fails on UndefinedColumn
        # would read to the caller as a server bug instead of a governance gap.
        if not _decision_authority_adopted(m2_engine):
            raise WorkflowHeld('QG_AUTHORITY_SCHEMA_NOT_ADOPTED')

        authority = derive_objective_authority(
            m2_engine, actor_id=actor, assessment_id=assessment_id,
            proposal_id=payload.proposal_id, context_id=payload.context_id)
        binding = resolve_authorized(
            m2_engine, actor, assessment_id=assessment_id,
            proposal_id=payload.proposal_id, context_id=payload.context_id,
            authority=authority, prompt_key=payload.prompt_key,
            stimulus=payload.stimulus)

        # 4. Consent is read, never assumed. A missing block is a refusal even
        # though the provider and the schema are both ready.
        consent = qg_authorization.consent_block(
            m2_engine, actor_id=actor, assessment_id=assessment_id,
            confirmation_id=payload.confirmation_id,
            revision=binding['assessment_revision'],
            objective_decision_id=authority['decision']['decision_id'])
        if consent is None:
            raise WorkflowHeld('AI_PROCESSING_QG_CONSENT_ABSENT')
        consent_version = consent.get('contract_version')
        consent_digest = consent.get('consent_digest')
        if not isinstance(consent_version, str) or not isinstance(consent_digest, str):
            # A block without both halves cannot be verified against the terms it
            # claims to cover, so it is not treated as a grant.
            raise WorkflowHeld('AI_PROCESSING_QG_CONSENT_ABSENT')

        # 5. One single-use authorization for this attempt. The measurement basis
        # follows the resolved measurement, not a request field: a proposed
        # basis carries no measurement id, which the CHECK also enforces.
        decision = authority.get('decision') or {}
        measurement_outcome = (binding.get('measurement') or {}).get('outcome')
        reusable = str(measurement_outcome) in (ml.REUSE, ml.REUSE_SYNTHETIC)
        issued = qg_authorization.issue(
            m2_engine, actor_id=actor, assessment_id=assessment_id,
            confirmation_id=payload.confirmation_id,
            assessment_revision=binding['assessment_revision'],
            source_fingerprint=binding['source_fingerprint'],
            context_id=binding['context_id'],
            context_packet_hash=binding['context_packet_hash'],
            objective_id=binding['objective_id'],
            objective_decision_id=decision.get('decision_id'),
            objective_kind=authority['objective_kind'],
            measurement_basis=(qg_authorization.BASIS_APPROVED if reusable
                               else qg_authorization.BASIS_PROPOSED),
            measurement_id=(binding.get('measurement') or {}).get('measurement_id'),
            measurement_version=(binding.get('measurement') or {}).get('measurement_version'),
            prompt_version=binding['prompt'].version,
            prompt_sha256=binding['prompt'].fingerprint,
            consent_version=consent_version, consent_digest=consent_digest,
            # A recovery is a second, separately authorised attempt against the
            # same act. ``issue`` refuses it unless the prior row is spent and
            # every binding column still matches, so naming a prior attempt
            # cannot widen what may be generated (DD-054).
            recovery_of=payload.recovery_of)

        authorization_id = issued['authorization_id']

        def authority_callable() -> dict:
            derived = qg_authorization.runner_authority(
                m2_engine, actor_id=actor,
                authorization_id=authorization_id,
                consent_lookup=lambda: consent,
                provider=LIVE_PROVIDER, model=PROVIDER_MODEL,
                endpoint=PROVIDER_ENDPOINT,
                packet_source_fingerprint=binding['facts'].fingerprint,
                max_attempts=1,
                # The adapter reserves this attempt before dispatch
                # (``qg_attempt.reserve``), so by the time this verifier runs
                # the row is spent by the attempt in flight. Without this the
                # ordering fix would make every dispatch refuse itself.
                attempt_reserved=True)
            return {**derived,
                    'cost_ceiling_usd': ceiling,
                    'timeout_seconds': provider_timeout_seconds()}

        runner = QgLiveRunner(engine=ledger_engine,
                              authorization_verifier=authority_callable)
        generate = live_fixed_option_generator(
            runner, policy_version=binding['policy_version'],
            prompt_key=payload.prompt_key)
        adapter = QgCandidateAdapter(
            engine=m2_engine, actor_id=actor,
            store=ml.PostgresMeasurementStore(m2_engine, actor),
            admission_lookup=lambda pid, fp: admission_state(
                m2_engine, pid, source_fingerprint=fp, actor_id=actor),
            generate=generate, scope=LIVE_SCOPE,
            source_check=lambda: current_verdict)

        current_verdict = source_currentness.current_source(
            m2_engine, service=context_service, assessment_id=assessment_id,
            confirmation_id=payload.confirmation_id,
            actor=ContextActor(user.user_id, rbac.canonical_role(user.role)))
        refusal = source_currentness.refusal(
            current_verdict,
            authorized_context_packet_hash=binding['context_packet_hash'])
        if refusal is not None:
            raise HTTPException(409, detail={
                'code': refusal,
                'message': 'The business context this objective was approved '
                           'against is not the current source.'})

        # 6. The existing adapter. No new prompt, no new provider path.
        envelope = adapter.prepare(
            assessment_id=binding['assessment_id'],
            confirmation_id=binding['confirmation_id'],
            assessment_revision=binding['assessment_revision'],
            source_fingerprint=binding['source_fingerprint'],
            context_id=binding['context_id'],
            context_packet_hash=binding['context_packet_hash'],
            objective_id=binding['objective_id'],
            objective_text=binding['objective_text'],
            proposal_id=binding['proposal_id'], packet=binding['packet'],
            stimulus=dict(payload.stimulus or {}),
            authorization_id=authorization_id,
            prompt_version=binding['prompt'].version,
            prompt_sha256=binding['prompt'].fingerprint,
            population=binding['measurement'].get('population'),
            # The *derived objective* relationship from
            # ``derive_objective_authority``, which is what ``prepare`` reads:
            # it names the authority reference (``decision:<uuid>``) and records
            # the basis. The runner authority is a different shape and belongs
            # only to the dispatch verifier below.
            authority=authority,
            response_format=payload.response_format)
    except WorkflowHeld as exc:
        refusal = _held(exc)
        execution = getattr(runner, 'last_execution', None) or {}
        if _dispatch_evidence(execution):
            refusal.detail['provider'] = _provider_provenance(
                runner, ceiling=ceiling)
        if str(exc) in _RECOVERY_REFUSALS:
            # The attempt is spent. Say what a separate recovery would need
            # rather than leaving the caller to infer it (DD-054).
            refusal.detail['recovery'] = _recovery_facts(
                m2_engine, actor=actor, assessment_id=assessment_id,
                confirmation_id=payload.confirmation_id,
                authority=authority, ceiling=ceiling)
        _record_refusal(exc, assessment_id=assessment_id,
                        authorization_id=authorization_id, runner=runner)
        raise refusal from None

    envelope['authorization_id'] = authorization_id
    envelope['eligibility'] = {
        'generation_status': eligibility['generation_status'],
        'scientific_status': eligibility['scientific_status'],
        'scientific_refusal': eligibility['scientific_refusal'],
    }
    envelope['provider_execution'] = _provider_provenance(
        runner, ceiling=ceiling)
    return envelope


@router.post('/assessments/{assessment_id}/qg-candidates/generate')
def generate_for_approved_objective(assessment_id: UUID,
                                    payload: AutomaticGenerationRequest,
                                    user: Owner, response: Response,
                                    m2_engine: AuthorizedProposalStorageEngine,
                                    ledger_engine: AuthorizedLedgerEngine,
                                    context_service: ContextService):
    """Eligibility, issuance and generation as one governed step.

    The intended lifecycle is *approved objective → automatic eligibility
    validation → Direct-QG execution*. This route is that sentence. It performs,
    in order, and refuses at the first unmet prerequisite:

    1. derive the objective authority from the owner's approval (contract 2.1);
    2. evaluate generation eligibility and refuse on any failed check G-01..G-05;
    3. confirm the deployment has adopted the objective-authority schema;
    4. read the persisted QG consent block (consent is never assumed);
    5. issue exactly one single-use authorization for this attempt;
    6. run the existing governed adapter.

    It does not create an admission, does not require the owner to approve again,
    and does not fall back to a simulated candidate.
    """
    response.headers['Cache-Control'] = 'no-store'
    if not settings.tokenharbor_enabled:
        raise HTTPException(503, detail={
            'code': 'PROVIDER_NOT_CONFIGURED',
            'message': 'TokenHarbour is not enabled for this deployment.'})

    ceiling = provider_cost_ceiling_usd()
    if ceiling is None:
        raise HTTPException(503, detail={
            'code': 'PROVIDER_COST_CEILING_NOT_ADOPTED',
            'message': 'The per-attempt cost ceiling is unset or above the '
                       f'adopted maximum of USD {MAX_TOKENHARBOR_COST_CEILING_USD:.2f}.'})

    return _attempt_one_objective(
        assessment_id=assessment_id, payload=payload, user=user,
        m2_engine=m2_engine, ledger_engine=ledger_engine,
        context_service=context_service, ceiling=ceiling)


@router.post('/assessments/{assessment_id}/qg-candidates/generate-batch')
def generate_for_selected_objectives(assessment_id: UUID,
                                     payload: BatchGenerationRequest,
                                     user: Owner, response: Response,
                                     m2_engine: AuthorizedProposalStorageEngine,
                                     ledger_engine: AuthorizedLedgerEngine,
                                     context_service: ContextService):
    """One owner action, one governed attempt per selected objective.

    Why a batch route rather than a client-side loop
    -----------------------------------------------
    A loop in the browser would put the governance on the wrong side of the wire:
    a page closed halfway through would leave objectives half-generated with no
    record of what was attempted, and two open tabs could interleave the same
    objective. Here the server walks the selection once, in order, and reports
    what happened to each objective.

    It does **not** merge objectives into one prompt. Each objective keeps its own
    authority, its own context binding, its own single-use authorization and its
    own validation — the same path the single-objective route runs. The batch is
    a loop over that path, nothing more.

    Duplicate prevention is inherited, not re-implemented: the authorization and
    the consent grant are spent before dispatch by ``qg_attempt.reserve``, so a
    repeated click, a refresh or a second tab is refused with
    ``QG_AUTHORIZATION_ALREADY_SPENT`` instead of producing a second candidate.

    A refusal on one objective does not stop the others. That is the point: an
    owner who selected six objectives must not lose five because the third was
    unmeasurable.
    """
    response.headers['Cache-Control'] = 'no-store'
    if not settings.tokenharbor_enabled:
        raise HTTPException(503, detail={
            'code': 'PROVIDER_NOT_CONFIGURED',
            'message': 'TokenHarbour is not enabled for this deployment.'})

    ceiling = provider_cost_ceiling_usd()
    if ceiling is None:
        raise HTTPException(503, detail={
            'code': 'PROVIDER_COST_CEILING_NOT_ADOPTED',
            'message': 'The per-attempt cost ceiling is unset or above the '
                       f'adopted maximum of USD {MAX_TOKENHARBOR_COST_CEILING_USD:.2f}.'})

    # Order-preserving de-duplication. A caller that names the same objective
    # twice asked for it once; dispatching twice would spend two authorizations
    # on one objective and produce a second candidate nobody asked for.
    selected: list[UUID] = []
    for proposal_id in payload.proposal_ids:
        if proposal_id not in selected:
            selected.append(proposal_id)

    results: list[dict] = []
    for proposal_id in selected:
        single = AutomaticGenerationRequest(
            confirmation_id=payload.confirmation_id,
            context_id=payload.context_id,
            proposal_id=proposal_id,
            prompt_key=payload.prompt_key,
            response_format=payload.response_format)
        try:
            envelope = _attempt_one_objective(
                assessment_id=assessment_id, payload=single, user=user,
                m2_engine=m2_engine, ledger_engine=ledger_engine,
                context_service=context_service, ceiling=ceiling)
        except HTTPException as exc:
            detail = exc.detail if isinstance(exc.detail, dict) else {}
            code = detail.get('code')
            results.append({
                'proposal_id': str(proposal_id),
                'status': 'REFUSED',
                'code': code,
                'message': detail.get('message'),
                'check_id': detail.get('check_id'),
                # True when the refusal means this objective has used the one
                # attempt it was allowed. The caller must not offer a plain
                # retry for these; recovery is a separate, named act.
                'attempt_spent': code in _SPENT_CODES,
                'candidate_id': None,
                'dispatched': bool((detail.get('provider') or {}).get('dispatched')),
            })
            continue
        results.append({
            'proposal_id': str(proposal_id),
            'status': 'COMPLETED',
            'code': None,
            'message': None,
            'check_id': None,
            'attempt_spent': True,
            'candidate_id': envelope.get('candidate_id'),
            'outcome': envelope.get('outcome'),
            'dispatched': bool(envelope.get('dispatched')),
            'authorization_id': envelope.get('authorization_id'),
        })

    completed = [r for r in results if r['status'] == 'COMPLETED']
    return {
        'contract_version': BATCH_CONTRACT,
        'assessment_id': str(assessment_id),
        'results': results,
        'summary': {
            'requested': len(selected),
            'completed': len(completed),
            'refused': len(results) - len(completed),
            'persisted': len([r for r in completed if r.get('candidate_id')]),
        },
        'dispatches_model': any(r.get('dispatched') for r in results),
        'combined_prompt': False,
    }
