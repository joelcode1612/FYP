"""Location Assessment Workspace endpoints (Jaspr web decision-support).

Every route is scoped to the authenticated entrepreneur: the owner id comes
from the verified token, never from the request body, and a record belonging to
another account returns 403. Opening the workspace for a property resumes the
caller's existing assessment instead of creating a second one.

The Flutter mobile data-collection workflow does not use these routes.
"""

from __future__ import annotations

import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field
from sqlmodel import Session

from sitewise.core.exceptions import AssessmentError
from sitewise.db.analytics_session import get_analytics_db
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, require_entrepreneur
from sitewise.services.assessment_service import AssessmentService

router = APIRouter()

EntrepreneurUser = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]
AppSession = Annotated[Session, Depends(get_db)]
AnalyticsSession = Annotated[Session, Depends(get_analytics_db)]


class StartAssessmentRequest(BaseModel):
    property_id: str = Field(min_length=1, max_length=64)


class UpdateAssessmentRequest(BaseModel):
    """Save requirements, confirm a stage, or both in one round trip."""

    requirements: dict[str, Any] | None = None
    complete_stage: str | None = Field(default=None, max_length=40)


def _service(session: Session, analytics: Session) -> AssessmentService:
    return AssessmentService(session, analytics)


@router.post("/")
def start_assessment(
    body: StartAssessmentRequest,
    session: AppSession,
    analytics: AnalyticsSession,
    user: EntrepreneurUser,
) -> dict:
    """Create the caller's assessment for a property, or resume it.

    ``created`` tells the client which happened; the payload is identical
    either way so the workspace always renders persisted state.
    """
    service = _service(session, analytics)
    assessment, created = service.create_or_resume(user.user_id, body.property_id.strip())
    return {"created": created, "assessment": service.payload(assessment)}


@router.get("/me")
def list_own_assessments(
    session: AppSession,
    analytics: AnalyticsSession,
    user: EntrepreneurUser,
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
) -> dict:
    """Assessment history, most recently updated first."""
    return _service(session, analytics).history_payload(user.user_id, limit=limit, offset=offset)


@router.get("/me/current")
def get_current_assessment(
    session: AppSession,
    analytics: AnalyticsSession,
    user: EntrepreneurUser,
) -> dict:
    """The dashboard's "Current Assessment" record.

    "Current" is defined as the most recently updated assessment. No record is
    a normal empty state, not an error, so the response is 200 with a null.
    """
    service = _service(session, analytics)
    assessment = service.repo.most_recent(user.user_id)
    return {"assessment": service.payload(assessment) if assessment is not None else None}


@router.get("/by-property/{property_id}")
def get_assessment_for_property(
    property_id: str,
    session: AppSession,
    analytics: AnalyticsSession,
    user: EntrepreneurUser,
) -> dict:
    """Resume lookup used by the workspace and every entry point.

    A property with no assessment yet returns 200 with a null - the caller
    decides whether to start one. An unknown property id is still 404 so the
    workspace can distinguish "not started" from "invalid id".
    """
    service = _service(session, analytics)
    if service.catalog.get_property(property_id) is None:
        raise AssessmentError(
            f"No property with id '{property_id}' exists in the catalogue.",
            code="property_not_found",
            status_code=404,
        )
    assessment = service.find_by_property(user.user_id, property_id)
    return {"assessment": service.payload(assessment) if assessment is not None else None}


@router.get("/{assessment_id}")
def get_assessment(
    assessment_id: uuid.UUID,
    session: AppSession,
    analytics: AnalyticsSession,
    user: EntrepreneurUser,
) -> dict:
    service = _service(session, analytics)
    assessment = service.get_owned(assessment_id, user.user_id)
    return {"assessment": service.payload(assessment)}


@router.patch("/{assessment_id}")
def update_assessment(
    assessment_id: uuid.UUID,
    body: UpdateAssessmentRequest,
    session: AppSession,
    analytics: AnalyticsSession,
    user: EntrepreneurUser,
) -> dict:
    """Persist requirements and/or confirm one stage.

    Stage confirmation is refused (409) when the prior stages are incomplete,
    when the evidence does not exist, or when the model/report capability is
    unavailable - progress is never written ahead of what actually happened.
    """
    service = _service(session, analytics)
    assessment = service.get_owned(assessment_id, user.user_id)
    assessment = service.update(
        assessment,
        requirements=body.requirements,
        complete_stage=body.complete_stage,
    )
    return {"assessment": service.payload(assessment)}
