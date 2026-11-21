"""Authenticated QG candidate surface: prepare, read, history and revise.

Mounted only with the M2 upstream router (``settings.m2_upstream_enabled``), so
this route set cannot be reached by flipping an unrelated flag. It adds no
review endpoint: the owner decision (``APPROVE_FOR_REVIEW`` / ``REJECT`` /
``REQUEST_REVISION``) remains the single ``POST /research-questions/{version}
/owner-review`` route in ``m2.py``.

Status mapping, stated once so the routes cannot drift apart:

* ``VALIDATED_OUTPUT`` / ``VALID_ABSTENTION`` -> 200. An abstention is a valid
  answer naming the missing confirmed facts, not a failure.
* stale / mismatch / conflict -> 409.
* ``MODEL_ATTEMPT_BUDGET_EXHAUSTED`` -> 429.
* provider unavailable or timeout -> 503.
* authority, contract or composition misconfiguration -> 503.
* a model that never produced a valid candidate -> 503 with ``MODEL_FAILURE``.

Every read is ``Cache-Control: no-store``: a candidate is review material, not
a cacheable resource, and its status changes when a reviewer decides.
"""
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, ConfigDict, Field

from sitewise.api.v1.m2_route import M2SourceRoute
from sitewise.core.exceptions import ConflictError, NotFoundError
from sitewise.dependencies import AuthenticatedUser, get_qg_candidate_service, require_entrepreneur
from sitewise.domain import rbac
from sitewise.project1.contracts import WorkflowHeld
from sitewise.services.persisted_business_context_service import ContextOperationHeld
from sitewise.services.qg_candidate_service import (
    ANSWER_STATUSES, CONTEXT_CONFLICT_CODES, QgCandidateService,
)

router = APIRouter(route_class=M2SourceRoute)
Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]
Service = Annotated[QgCandidateService, Depends(get_qg_candidate_service)]

NO_STORE = {'Cache-Control': 'no-store'}

#: BLOCKED_INPUT codes that mean "the records you are pointing at disagree".
#: The engine's own context codes come from the service so the two cannot drift.
CONFLICT_CODES = CONTEXT_CONFLICT_CODES | frozenset({
    'BCB_CONFIRMATION_REQUIRED', 'UNCERTAINTY_NOT_CONFIRMED',
    'BCB_PACKET_FINGERPRINT_INVALID', 'BCB_RESTRICTED_ITEM_MEMBERSHIP',
    'F01_CONFIRMATION_NOT_CURRENT', 'F01_UNCERTAINTY_IDENTITY_INCOMPLETE',
    'F01_UNCERTAINTY_CONFIRMATION_MISMATCH', 'F01_UNCERTAINTY_TEXT_MISSING',
    'F01_CONTEXT_CHANGED_SINCE_ADMISSION', 'F02_GEO_NOT_EXCLUDED',
    'QG_CONFIRMED_FACTS_INCOMPLETE', 'QG_CONFIRMED_UNCERTAINTY_TEXT_MISSING',
    'MODEL_STAGE_ALREADY_RESERVED',
})


def failure(status_code: int, code: str, message: str) -> HTTPException:
    return HTTPException(status_code=status_code,
                         detail={'code': code, 'message': message},
                         headers=NO_STORE)


def status_code_for(result: dict) -> int:
    """Map one engine result to HTTP without guessing a missing code."""
    status, code = result.get('status'), result.get('code')
    if status in ANSWER_STATUSES:
        return 200
    if code == 'MODEL_ATTEMPT_BUDGET_EXHAUSTED':
        return 429
    if status == 'BLOCKED_INPUT' and code in CONFLICT_CODES:
        return 409
    # MODEL_FAILURE, an unlisted governance hold, and a provider or authority
    # refusal are all "the service could not produce a candidate right now".
    return 503


def outcome(result: dict, response: Response) -> dict:
    """Return the answer, or raise the mapped failure with its own code."""
    status_code = status_code_for(result)
    response.headers['Cache-Control'] = 'no-store'
    if status_code == 200:
        return result
    raise failure(status_code, result.get('code') or 'QG_CANDIDATE_UNAVAILABLE',
                  'No candidate question was produced. Nothing was stored.')


def owned(operation):
    """Translate service refusals into this route's documented statuses."""
    try:
        return operation()
    except ConflictError as exc:
        raise failure(409, str(exc),
                      'The request conflicts with the current research state; '
                      'reload before continuing.') from exc
    except NotFoundError as exc:
        raise failure(404, 'QG_CANDIDATE_NOT_FOUND',
                      'The requested candidate was not found.') from exc
    except ContextOperationHeld as exc:
        raise failure(exc.status_code, exc.code,
                      'The business context could not be verified. '
                      'No candidate was generated.') from exc
    except WorkflowHeld as exc:
        # Composition holds only: the engine returns its statuses as data.
        raise failure(503, str(exc),
                      'Question generation is waiting for its required setup.') from exc


class CandidateRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    expected_revision: int = Field(ge=0, strict=True)
    context_id: UUID


@router.post('/research-objectives/{objective_id}/qg-candidate')
def prepare_candidate(objective_id: UUID, payload: CandidateRequest, user: Owner,
                      service: Service, response: Response):
    result = owned(lambda: service.prepare(
        objective_id, user.user_id, payload.expected_revision, payload.context_id,
        actor_role=rbac.canonical_role(user.role)))
    return outcome(result, response)


@router.get('/research-questions/{version}')
def read_candidate(version: UUID, user: Owner, service: Service, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    return owned(lambda: service.read(version, user.user_id))


@router.get('/research-objectives/{objective_id}/research-questions')
def candidate_history(objective_id: UUID, user: Owner, service: Service, response: Response,
                      expected_revision: Annotated[int, Query(ge=0)]):
    response.headers['Cache-Control'] = 'no-store'
    return owned(lambda: service.history(objective_id, user.user_id, expected_revision))


@router.post('/research-questions/{version}/revision')
def revise_candidate(version: UUID, payload: CandidateRequest, user: Owner,
                     service: Service, response: Response):
    result = owned(lambda: service.revise(
        version, user.user_id, payload.expected_revision, payload.context_id,
        actor_role=rbac.canonical_role(user.role)))
    return outcome(result, response)


__all__ = ['CONFLICT_CODES', 'router', 'status_code_for']
