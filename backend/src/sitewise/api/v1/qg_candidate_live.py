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
from sitewise.project1.disclosure import QG_PURPOSE
from sitewise.project1.objective_admission import admission_state
from sitewise.project1.qg_binding import resolve as resolve_binding
from sitewise.project1.qg_candidate_adapter import LIVE_SCOPE, QgCandidateAdapter
from sitewise.project1.qg_live import QgLiveRunner
from sitewise.project1.qg_live_candidate import live_fixed_option_generator
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
    'QG_AUTHORIZATION_NOT_FOUND': 404,
    'QG_BINDING_ADMISSION_NOT_ADMITTED': 409,
    'QG_BINDING_CONTEXT_NOT_ADMITTED': 409,
    'QG_BINDING_ADMISSION_ASSESSMENT_MISMATCH': 409,
    'QG_AUTHORIZATION_BINDING_MISMATCH': 409,
    'QG_AUTHORIZATION_CONSUMED': 409,
    'QG_AUTHORIZATION_EXPIRED': 409,
    'PROVIDER_PROMPT_NOT_REGISTERED': 409,
}


class GenerationRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')

    confirmation_id: UUID
    context_id: UUID
    objective_id: str = Field(min_length=1, max_length=40)
    proposal_id: UUID
    authorization_id: UUID
    prompt_key: str = 'QG_FIXED_OPTION'
    stimulus: dict | None = None


def _held(exc: WorkflowHeld) -> HTTPException:
    code = str(exc)
    status = _CONFLICT_CODES.get(code, 503)
    return HTTPException(status, detail={'code': code,
                                         'message': 'The Direct-QG attempt was refused.'})


def _as_text(value):
    """Render an identifier for a JSON refusal body, or ``None``."""
    return None if value is None else str(value)


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
        binding = resolve_binding(
            m2_engine, actor, assessment_id=assessment_id,
            objective_id=payload.objective_id, proposal_id=payload.proposal_id,
            context_id=payload.context_id, prompt_key=payload.prompt_key,
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
        authorization = qg_authorization.read(
            m2_engine, actor_id=actor,
            authorization_id=payload.authorization_id)
        if authorization is None:
            raise WorkflowHeld('QG_AUTHORIZATION_NOT_FOUND')

        # The runner's artifact, built from the row rather than a file: one
        # authority for the attempt, and an evaluation identity derived from the
        # authorization so one authorization can never reuse another's run.
        runner_authorization = {
            'purpose': QG_PURPOSE,
            # The QG packet carries the *confirmed-facts* fingerprint, and the
            # runner compares the packet against this value before it provisions
            # a run. The authorization row's ``source_fingerprint`` is the
            # proposal's source — a different identifier, used by the admission
            # and by ``qg_authorization.verify``. Passing the row's value here
            # refused every dispatch with DISCLOSURE_SOURCE_MISMATCH before a
            # socket was opened.
            'source_fingerprint': binding['facts'].fingerprint,
            'assessment_id': str(authorization['assessment_id']),
            'actor_id': str(actor),
            'max_attempts': 1,
            'operator_receipt': f"QG-AUTHORIZATION-{authorization['authorization_id']}",
            'evaluation_id': str(authorization['authorization_id']),
            'prompt_version': authorization['prompt_version'],
            'prompt_sha256': authorization['prompt_sha256'],
            # Carried into the attempt so the receipt can be read against the
            # budget it was authorised under, rather than against a later value.
            'cost_ceiling_usd': ceiling,
            'timeout_seconds': provider_timeout_seconds(),
        }
        runner = QgLiveRunner(engine=ledger_engine,
                              authorization=runner_authorization)
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
            population=binding['measurement']['population'])
    except WorkflowHeld as exc:
        refusal = _held(exc)
        # A provider failure is the one refusal an operator cannot diagnose from
        # the code alone: "outcome unknown" says nothing about whether the peer
        # was ever reached. The runner's execution record is content-free
        # (model ids, status, failure class, token counts), so it is attached
        # rather than left in the process that is about to forget it.
        execution = getattr(runner, 'last_execution', None) or {}
        if str(exc).startswith(('E_PROVIDER', 'PROVIDER_')) and execution:
            # ``null`` is kept rather than dropped: "no HTTP status was received"
            # is the fact that separates a connection failure from a rejection,
            # and an absent key would read as "not recorded".
            refusal.detail['provider'] = _provider_provenance(
                runner, ceiling=ceiling)
        raise refusal from None
    # The adapter's envelope carries the governed outcome; this block carries
    # the provider-side facts needed to verify the single real call (output cap,
    # completion tokens, stop reason and identities) without exposing content.
    envelope['provider_execution'] = _provider_provenance(
        runner, ceiling=ceiling)
    return envelope
