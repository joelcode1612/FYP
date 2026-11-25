"""Authenticated QG authorization: the owner's permission to spend one attempt.

Why this route exists
---------------------
``qg_authorization.issue()`` had no caller and no HTTP surface (DD-040). The
Direct-QG generation route required an ``authorization_id`` that nothing in the
application could produce, so the live path could only ever answer
``QG_AUTHORIZATION_NOT_FOUND``. This is the missing producer.

What it does *not* do
---------------------
* It does not approve a research objective. That is the entrepreneur's separate
  Approve action on a proposal, and it is the authority this route reads
  (contract 2.1). There is no admission step here, because the owner already
  said the objective is worth researching.
* It does not dispatch a model call. Issuing permission and spending it are
  different acts; spending happens in ``qg_candidate_live``.
* It does not grant fielding, publication or scientific acceptance.

Duplicate execution
-------------------
``(assessment_id, request_id)`` is unique. A retried POST returns the row that
already exists with ``idempotent: true`` rather than issuing a second
authorization, so a double-click cannot spend two attempts.
"""
from __future__ import annotations

import uuid
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, ConfigDict

from sitewise.dependencies import AuthenticatedUser, require_entrepreneur
from sitewise.project1 import qg_authorization, qg_consent_store
from sitewise.project1 import measurement_library as ml
from sitewise.project1.ai_processing_consent import (
    qg_disclosure, verify_qg_consent,
)
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.provider import ENDPOINT as PROVIDER_ENDPOINT
from sitewise.project1.provider import MODEL as PROVIDER_MODEL
from sitewise.project1.qg_binding import PROMPTS, resolve_authorized
from sitewise.project1.qg_generation_eligibility import (
    derive_objective_authority,
)
from sitewise.api.v1.project1_objective_proposals import (
    AuthorizedProposalStorageEngine,
)

router = APIRouter()

Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]

#: Codes that mean "the caller must change something". Anything else is a 503
#: hold, which is the honest answer for a governance refusal.
_CONFLICT_CODES = {
    'QG_OBJECTIVE_PROPOSAL_NOT_FOUND': 404,
    'QG_OBJECTIVE_CONTEXT_NOT_FOUND': 404,
    'QG_OBJECTIVE_NOT_APPROVED': 409,
    'QG_OBJECTIVE_DECISION_NOT_APPROVED': 409,
    'QG_OBJECTIVE_DECIDED_BY_OTHER': 403,
    'QG_OBJECTIVE_ASSESSMENT_MISMATCH': 409,
    'QG_OBJECTIVE_DECISION_BINDING_DRIFT': 409,
    'QG_OBJECTIVE_NOT_CONFIRMED': 409,
    'QG_OBJECTIVE_REVISION_STALE': 409,
    'QG_OBJECTIVE_CONTEXT_NOT_CURRENT': 409,
    'QG_BINDING_CONTEXT_NOT_FOUND': 404,
    'QG_BINDING_CONTEXT_NOT_ADMITTED': 409,
    'PROVIDER_PROMPT_NOT_REGISTERED': 409,
    'AI_PROCESSING_QG_CONSENT_ABSENT': 409,
    'AI_PROCESSING_QG_CONSENT_REQUIRED': 409,
    'AI_PROCESSING_QG_CONSENT_VERSION_UNSUPPORTED': 409,
    'AI_PROCESSING_QG_CONSENT_TAMPERED': 409,
    'AI_PROCESSING_QG_CONSENT_PROVIDER_MISMATCH': 409,
    'AI_PROCESSING_QG_CONSENT_ENDPOINT_MISMATCH': 409,
    'AI_PROCESSING_QG_CONSENT_MODEL_MISMATCH': 409,
    'AI_PROCESSING_QG_CONSENT_PURPOSE_MISMATCH': 409,
    'AI_PROCESSING_QG_CONSENT_SCOPE_MISMATCH': 409,
    'AI_PROCESSING_QG_CONSENT_ATTEMPTS_MISMATCH': 409,
    'AI_PROCESSING_QG_CONSENT_OWNER_MISMATCH': 403,
    'QG_AUTHORIZATION_MEASUREMENT_ABSTAINED': 409,
    'QG_AUTHORIZATION_DECISION_NOT_FOUND': 404,
    'QG_AUTHORIZATION_DECISION_NOT_APPROVED': 409,
    'QG_AUTHORIZATION_DECISION_STALE': 409,
    # QG consent (DD-044, migration 20261124_06).
    'QG_CONSENT_REQUEST_ID_REQUIRED': 400,
    'QG_CONSENT_CONFIRMATION_NOT_FOUND': 404,
    'QG_CONSENT_CONFIRMATION_ASSESSMENT_MISMATCH': 409,
    'QG_CONSENT_REVISION_MISMATCH': 409,
    'QG_CONSENT_OWNER_MISMATCH': 403,
    'QG_CONSENT_AUTHORITY_NOT_FOUND': 404,
    'QG_CONSENT_AUTHORITY_NOT_CURRENT': 409,
    'QG_CONSENT_AUTHORITY_NOT_APPROVED': 409,
    'QG_CONSENT_AUTHORITY_OTHER_OWNER': 403,
    'QG_CONSENT_REQUEST_DUPLICATE': 409,
    'QG_CONSENT_ALREADY_CONSUMED': 409,
    'QG_CONSENT_NOT_FOUND': 404,
    'QG_CONSENT_ALREADY_REVOKED': 409,
    'QG_CONSENT_REVOCATION_REASON_REQUIRED': 400,
}


class AuthorizationRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')

    proposal_id: UUID
    context_id: UUID
    prompt_key: str = 'QG_FIXED_OPTION'
    stimulus: dict | None = None
    #: Idempotency key. Supplied by the client so a retry cannot issue twice;
    #: generated when absent, which makes the retry a genuinely new request.
    request_id: UUID | None = None


class ConsentRequest(BaseModel):
    """The owner's echo of the QG disclosure, plus the objective it covers.

    Every disclosed term is optional in the schema and re-derived on the server:
    omitting one is a refusal, not a default. ``build_qg_consent`` compares each
    against the canonical constant, so a client cannot widen the disclosure, name
    a different provider, or claim a purpose the product does not have.
    """
    model_config = ConfigDict(extra='forbid')

    proposal_id: UUID
    context_id: UUID | None = None
    prompt_key: str = 'QG_FIXED_OPTION'
    request_id: UUID | None = None

    granted: bool = False
    disclosure_version: str | None = None
    provider: str | None = None
    purpose: str | None = None
    endpoint: str | None = None
    model: str | None = None


def _held(exc: WorkflowHeld) -> HTTPException:
    code = str(exc)
    return HTTPException(_CONFLICT_CODES.get(code, 503),
                         detail={'code': code,
                                 'message': 'The QG authorization was refused.'})


def _measurement_binding(measurement: dict) -> tuple[str, str | None, str | None]:
    """The basis and, when one exists, the approved specification identifiers.

    A ``PROPOSE`` outcome is not a failure here: contract 2.1 allows drafting
    against a proposed measurement, and the basis column records that no
    specification was approved. An ``ABSTAIN`` is different — a mandatory
    stimulus is missing — and is refused, because generating would require
    inventing it.
    """
    outcome = measurement.get('outcome')
    if outcome in (ml.REUSE, ml.REUSE_SYNTHETIC):
        return (qg_authorization.BASIS_APPROVED,
                measurement.get('measurement_id'),
                measurement.get('measurement_version'))
    if outcome == ml.PROPOSE:
        return qg_authorization.BASIS_PROPOSED, None, None
    raise WorkflowHeld('QG_AUTHORIZATION_MEASUREMENT_ABSTAINED')


@router.get('/assessments/{assessment_id}/qg-authorizations/disclosure')
def read_disclosure(assessment_id: UUID, user: Owner, response: Response):
    """The terms the interface must show before asking for the QG permission."""
    response.headers['Cache-Control'] = 'no-store'
    return {'assessment_id': str(assessment_id), 'disclosure': qg_disclosure()}


@router.get('/assessments/{assessment_id}/objective-authority')
def read_objective_authority(assessment_id: UUID, proposal_id: UUID,
                             context_id: UUID, user: Owner,
                             response: Response,
                             m2_engine: AuthorizedProposalStorageEngine):
    """The authority the owner's approval already establishes, or a named hold.

    Read-only. Stage 4 needs this because the objective identity under contract
    2.1 is derived from the proposal (``proposal:<uuid>``) and is not the
    registry id the old admission carried. Recomputing that string in the client
    would put a server contract in the browser, where it can drift silently;
    asking the server keeps one definition.

    It is not an approval and does not create one: every field is read from rows
    that already exist.
    """
    response.headers['Cache-Control'] = 'no-store'
    try:
        authority = derive_objective_authority(
            m2_engine, actor_id=user.user_id, assessment_id=assessment_id,
            proposal_id=proposal_id, context_id=context_id)
    except WorkflowHeld as exc:
        raise _held(exc) from None
    return {
        'assessment_id': str(assessment_id),
        'contract_version': authority['contract_version'],
        'proposal_id': authority['proposal_id'],
        'objective_id': authority['objective_id'],
        'objective_kind': authority['objective_kind'],
        'objective_text': authority['objective_text'],
        'confirmation_id': authority['confirmation_id'],
        'confirmation_revision': authority['confirmation_revision'],
        'decision': {
            'decision_id': authority['decision']['decision_id'],
            'decision': authority['decision']['decision'],
            'decided_at': authority['decision']['decided_at'],
        },
        'policy': authority['policy'],
        'derived_admission': authority['derived_admission'],
        'scientific_approval': False,
        'fielding_authorized': False,
    }


@router.post('/assessments/{assessment_id}/qg-authorizations', status_code=201)
def issue_authorization(assessment_id: UUID, payload: AuthorizationRequest,
                        user: Owner, response: Response,
                        m2_engine: AuthorizedProposalStorageEngine):
    """Issue one exact-bound authorization for the approved objective."""
    response.headers['Cache-Control'] = 'no-store'
    actor = user.user_id
    try:
        if payload.request_id is not None:
            existing = qg_authorization.find_by_request(
                m2_engine, actor_id=actor, assessment_id=assessment_id,
                request_id=payload.request_id)
            if existing is not None:
                # The same request, already honoured. Returning it keeps the
                # response idempotent without pretending a second attempt was
                # authorised.
                return {
                    'authorization_id': str(existing['authorization_id']),
                    'idempotent': True,
                    'expires_at': existing['expires_at'],
                    'consumed': existing['consumed_at'] is not None,
                    'objective_id': existing['objective_id'],
                    'objective_decision_id': (
                        None if existing['objective_decision_id'] is None
                        else str(existing['objective_decision_id'])),
                    'objective_kind': existing['objective_kind'],
                    'measurement_basis': existing['measurement_basis'],
                    'disclosure': qg_disclosure(),
                    'fielding_authorized': False,
                    'scientific_approval': False,
                }

        authority = derive_objective_authority(
            m2_engine, actor_id=actor, assessment_id=assessment_id,
            proposal_id=payload.proposal_id, context_id=payload.context_id)
        binding = resolve_authorized(
            m2_engine, actor, assessment_id=assessment_id,
            proposal_id=payload.proposal_id, context_id=payload.context_id,
            authority=authority, prompt_key=payload.prompt_key,
            stimulus=payload.stimulus)

        block = qg_authorization.consent_block(
            m2_engine, actor_id=actor, assessment_id=assessment_id,
            confirmation_id=binding['confirmation_id'],
            revision=binding['assessment_revision'],
            objective_decision_id=authority['decision']['decision_id'])
        # The grant is verified here, not merely read: an authorization must
        # name the consent it relies on, or a later reader cannot prove one
        # existed.
        block = verify_qg_consent(block, endpoint=PROVIDER_ENDPOINT,
                                  model=PROVIDER_MODEL, owner_id=actor)

        basis, measurement_id, measurement_version = _measurement_binding(
            binding['measurement'])

        issued = qg_authorization.issue(
            m2_engine, actor_id=actor, assessment_id=assessment_id,
            confirmation_id=binding['confirmation_id'],
            assessment_revision=binding['assessment_revision'],
            source_fingerprint=binding['source_fingerprint'],
            context_id=binding['context_id'],
            context_packet_hash=binding['context_packet_hash'],
            objective_id=binding['objective_id'],
            objective_decision_id=authority['decision']['decision_id'],
            objective_kind=binding['objective_kind'],
            measurement_basis=basis,
            measurement_id=measurement_id,
            measurement_version=measurement_version,
            prompt_version=binding['prompt'].version,
            prompt_sha256=binding['prompt'].fingerprint,
            request_id=payload.request_id,
            consent_version=block['contract_version'],
            consent_digest=block['consent_digest'])
    except WorkflowHeld as exc:
        raise _held(exc) from None

    return {
        **issued,
        'assessment_id': str(assessment_id),
        'objective_id': binding['objective_id'],
        'objective_kind': binding['objective_kind'],
        'measurement': {
            'outcome': binding['measurement'].get('outcome'),
            'reason': binding['measurement'].get('reason'),
            'measurement_id': measurement_id,
            'measurement_version': measurement_version,
            'scientifically_approved': bool(
                binding['measurement'].get('scientifically_approved')),
        },
        'authority': {
            'authority_basis': qg_authorization.AUTHORITY_DECISION,
            'objective_decision_id': str(authority['decision']['decision_id']),
            'decided_at': authority['decision']['decided_at'],
            'requires_separate_owner_action': False,
        },
        'disclosure': qg_disclosure(),
        'idempotent': False,
    }


# ---------------------------------------------------------------------------
# QG consent — the owner's separate permission to send facts to the model
# ---------------------------------------------------------------------------
#
# DD-044: generation refused every assessment with
# AI_PROCESSING_QG_CONSENT_ABSENT because no store could hold the grant.
# Migration 20261124_06 added one, and these routes are the only way a grant can
# be created. They never create one on the owner's behalf: the payload must echo
# the disclosure the interface showed, and the database refuses a grant whose
# objective was not approved by this owner on this revision.
#
# What granting does *not* do: it does not touch the confirmation snapshot, so it
# cannot create an M2 revision or invalidate an approved BDJ objective. That is
# the whole reason the store is separate.


def _consent_view(data: dict) -> dict:
    """The grant as the interface may see it: terms and evidence, no internals."""
    if data is None:
        return None
    return {
        'consent_id': data['consent_id'],
        'state': data['state'],
        'assessment_revision': data['assessment_revision'],
        'confirmation_id': data['confirmation_id'],
        'objective_decision_id': data['objective_decision_id'],
        'objective_kind': data['objective_kind'],
        'objective_id': data['objective_id'],
        'purpose': data['purpose'],
        'scope': data['scope'],
        'provider': data['provider'],
        'model': data['model'],
        'endpoint': data['endpoint'],
        'prompt_version': data['prompt_version'],
        'contract_version': data['contract_version'],
        'data_shared': data['disclosure_scope'],
        'max_attempts': data['max_attempts'],
        'granted_at': data['granted_at'],
        'expires_at': data['expires_at'],
        'revoked_at': data['revoked_at'],
        'revoked_reason': data['revoked_reason'],
        'consumed_at': data.get('consumed_at'),
        'consent_digest': data['consent_digest'],
    }


@router.get('/assessments/{assessment_id}/qg-consents/current')
def read_current_consent(assessment_id: UUID, proposal_id: UUID, user: Owner,
                         response: Response,
                         m2_engine: AuthorizedProposalStorageEngine,
                         context_id: UUID | None = None):
    """Whether the owner has granted QG processing for this objective.

    Reports five distinct states rather than a boolean, because the interface has
    to say something different for each: ``ABSENT`` means the owner has not been
    asked, ``EXPIRED`` and ``REVOKED`` mean the permission lapsed or was
    withdrawn, and ``CONSUMED`` means the single authorised attempt is spent.
    """
    response.headers['Cache-Control'] = 'no-store'
    try:
        authority = derive_objective_authority(
            m2_engine, actor_id=user.user_id, assessment_id=assessment_id,
            proposal_id=proposal_id, context_id=context_id)
        found = qg_consent_store.status(
            m2_engine, actor_id=user.user_id, assessment_id=assessment_id,
            confirmation_id=authority['confirmation_id'],
            revision=authority['confirmation_revision'],
            objective_decision_id=authority['decision']['decision_id'])
    except WorkflowHeld as exc:
        raise _held(exc) from None

    return {
        'assessment_id': str(assessment_id),
        'proposal_id': str(proposal_id),
        'objective_id': authority['objective_id'],
        'confirmation_id': authority['confirmation_id'],
        'confirmation_revision': authority['confirmation_revision'],
        'state': found['state'],
        'grant': _consent_view(found['grant']),
        'disclosure': qg_disclosure(),
        'scientific_approval': False,
        'fielding_authorized': False,
    }


@router.post('/assessments/{assessment_id}/qg-consents', status_code=201)
def grant_consent(assessment_id: UUID, payload: ConsentRequest, user: Owner,
                  response: Response,
                  m2_engine: AuthorizedProposalStorageEngine):
    """Record the owner's explicit QG processing permission for one objective.

    The authority is derived, not supplied: the objective must already have been
    approved by this owner on the current confirmed revision. There is no
    admission step and no second approval — the owner's existing Approve action
    is the authority, and this records the *separate* permission to process.
    """
    response.headers['Cache-Control'] = 'no-store'
    actor = user.user_id
    try:
        if payload.request_id is not None:
            existing = qg_consent_store.find_by_request(
                m2_engine, actor_id=actor, assessment_id=assessment_id,
                request_id=payload.request_id)
            if existing is not None:
                # The same request, already honoured. Returning it keeps the
                # response idempotent without recording a second permission.
                return {
                    'granted': True,
                    'idempotent': True,
                    'consent': _consent_view(existing),
                    'scientific_approval': False,
                    'fielding_authorized': False,
                }

        authority = derive_objective_authority(
            m2_engine, actor_id=actor, assessment_id=assessment_id,
            proposal_id=payload.proposal_id, context_id=payload.context_id)

        prompt = PROMPTS.get(payload.prompt_key)
        if prompt is None:
            raise WorkflowHeld('PROVIDER_PROMPT_NOT_REGISTERED')

        stored = qg_consent_store.grant(
            m2_engine, actor_id=actor, assessment_id=assessment_id,
            confirmation_id=authority['confirmation_id'],
            revision=authority['confirmation_revision'],
            objective_decision_id=authority['decision']['decision_id'],
            objective_kind=authority['objective_kind'],
            objective_id=authority['objective_id'],
            request=payload,
            request_id=str(payload.request_id or uuid.uuid4()),
            endpoint=PROVIDER_ENDPOINT,
            model=PROVIDER_MODEL,
            prompt_version=prompt.version,
            prompt_sha256=prompt.fingerprint)
    except WorkflowHeld as exc:
        raise _held(exc) from None

    if not stored.get('granted'):
        # A decline is a decision, not a failure. Nothing was written, and the
        # response says so rather than implying a permission exists.
        response.status_code = 200
        return {
            'granted': False,
            'reason': stored.get('reason'),
            'consent': None,
            'disclosure': qg_disclosure(),
            'scientific_approval': False,
            'fielding_authorized': False,
        }

    # An identical live permission already existed, so nothing new was written.
    # 200 rather than 201 says so: the owner granted once, and the record still
    # shows one grant rather than accumulating one per click.
    reused = bool(stored.get('reused'))
    if reused:
        response.status_code = 200

    return {
        'granted': True,
        'idempotent': reused,
        'consent': _consent_view(stored),
        'objective_id': stored['objective_id'],
        'objective_decision_id': stored['objective_decision_id'],
        'disclosure': qg_disclosure(),
        'scientific_approval': False,
        'fielding_authorized': False,
    }


@router.post('/assessments/{assessment_id}/qg-consents/{consent_id}/revoke')
def revoke_consent(assessment_id: UUID, consent_id: UUID, user: Owner,
                   response: Response,
                   m2_engine: AuthorizedProposalStorageEngine,
                   reason: str = 'owner withdrew the permission'):
    """Withdraw a grant. The record survives; the permission stops applying."""
    response.headers['Cache-Control'] = 'no-store'
    try:
        revoked = qg_consent_store.revoke(
            m2_engine, actor_id=user.user_id, consent_id=consent_id,
            reason=reason)
    except WorkflowHeld as exc:
        raise _held(exc) from None
    return {'assessment_id': str(assessment_id), **revoked,
            'scientific_approval': False, 'fielding_authorized': False}
