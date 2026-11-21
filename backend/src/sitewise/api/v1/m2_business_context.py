"""M2 → persisted BCB only. Identity/authority never supplied in request JSON."""
from typing import Annotated
from uuid import UUID
from datetime import datetime
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, ConfigDict, Field

from sitewise.core.config import settings
from sitewise.domain import rbac
from sitewise.dependencies import (
    AuthenticatedUser, require_entrepreneur, get_persisted_business_context_service,
)
from sitewise.services.persisted_business_context_service import (
    ContextOperationHeld, PersistedBusinessContextService,
)
from sitewise.services.ports.business_context_store_port import ContextActor, ContextSelection

router = APIRouter()
Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]


def enabled_service(service=Depends(get_persisted_business_context_service)):
    if not settings.m2_bcb_persistence_enabled:
        raise HTTPException(503, detail={'code':'BCB_PERSISTENCE_NOT_CONFIGURED',
            'message':'BCB persistence requires its reviewed schema and verified source bindings.'},
            headers={'Cache-Control':'no-store'})
    return service


Service = Annotated[PersistedBusinessContextService, Depends(enabled_service)]


class BuildRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    confirmation_id: UUID
    expected_revision: int = Field(ge=0, strict=True)


class ContextResponse(BaseModel):
    """Existing persisted-business-context/1 envelope, now described in OpenAPI."""
    model_config = ConfigDict(extra='forbid')
    contract_version: Literal['persisted-business-context/1']
    context_id: UUID
    assessment_id: UUID
    confirmation_id: UUID
    assessment_revision: int = Field(ge=0)
    lifecycle_status: Literal['PERSISTED']
    created_at: datetime
    replayed: bool
    packet: dict
    qj_execution_authorized: Literal[False]
    qg_execution_authorized: Literal[False]


class ContextStatusResponse(BaseModel):
    """Latest build snapshot, not immutable attempt history or fielding authority."""
    model_config = ConfigDict(extra='forbid')
    confirmation_id: UUID
    assessment_id: UUID
    owner_user_id: UUID
    assessment_revision: int = Field(ge=0)
    status: Literal['PENDING', 'HELD', 'PERSISTED', 'FAILED']
    last_code: str | None
    context_id: UUID | None
    attempt_count: int = Field(ge=0)
    created_at: datetime
    updated_at: datetime
    source_is_current: bool


def call(operation):
    try:
        return operation()
    except ContextOperationHeld as exc:
        raise HTTPException(exc.status_code, detail={'code':exc.code,
            'message':'Business context could not be verified or persisted. No substitute context was accepted.'},
            headers={'Cache-Control':'no-store'}) from exc


def actor(user):
    return ContextActor(user.user_id,rbac.canonical_role(user.role))


@router.post('/assessments/{assessment_id}/business-context', response_model=ContextResponse,
             responses={201: {'model': ContextResponse, 'description': 'New immutable context persisted'}})
def construct_context(assessment_id: UUID, payload: BuildRequest, user: Owner,
                      service: Service, response: Response):
    result = call(lambda: service.construct_and_save(
        ContextSelection(assessment_id,payload.confirmation_id,payload.expected_revision),
        actor(user)))
    response.headers['Cache-Control'] = 'no-store'
    response.status_code = 200 if result['replayed'] else 201
    return result


@router.get('/assessments/{assessment_id}/business-contexts/{context_id}', response_model=ContextResponse)
def read_context(assessment_id: UUID, context_id: UUID, user: Owner,
                 service: Service, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    return call(lambda: service.retrieve(assessment_id,context_id,actor(user)))


@router.get('/assessments/{assessment_id}/confirmations/{confirmation_id}/business-context-status', response_model=ContextStatusResponse)
def read_status(assessment_id: UUID, confirmation_id: UUID, user: Owner,
                service: Service, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    return call(lambda: service.status(assessment_id,confirmation_id,actor(user)))
