"""Authenticated availability reads only; no candidate, fielding or report writes."""
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Response

from sitewise.dependencies import (
    AuthenticatedUser, require_entrepreneur, get_project1_read_service,
)
from sitewise.services.project1_read_service import Project1Readiness, Project1ReadService

router = APIRouter()
Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]
Reader = Annotated[Project1ReadService, Depends(get_project1_read_service)]


@router.get("/readiness", response_model=Project1Readiness)
def collection_readiness(user: Owner, service: Reader, response: Response):
    response.headers["Cache-Control"] = "no-store"
    return service.read(None, user.user_id)


@router.get("/assessments/{assessment_id}/readiness", response_model=Project1Readiness)
def assessment_readiness(assessment_id: UUID, user: Owner, service: Reader, response: Response):
    response.headers["Cache-Control"] = "no-store"
    return service.read(assessment_id, user.user_id)
