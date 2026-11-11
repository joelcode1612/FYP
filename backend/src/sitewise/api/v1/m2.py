"""Opt-in, authenticated M2 upstream research API; no QJ or QG endpoints.

Routes are not registered unless settings.m2_upstream_enabled is explicitly true.
The database schema and authorized questionnaire records still require
separate Owner/governance approval and a controlled migration.
"""
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from sitewise.dependencies import AuthenticatedUser, require_entrepreneur, get_m2_service, get_bdj_service, get_confirmation_service
from sitewise.domain.m2_rules import M2ValidationError
from sitewise.services.m2_service import M2Service
from sitewise.services.bdj_service import BDJService
from sitewise.services.confirmation_service import ConfirmationService

router = APIRouter()
Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]
M2 = Annotated[M2Service, Depends(get_m2_service)]
BDJ = Annotated[BDJService, Depends(get_bdj_service)]
Confirmation = Annotated[ConfirmationService, Depends(get_confirmation_service)]


class NewAssessment(BaseModel):
    instrument_version_id: UUID


class AnswerUpdate(BaseModel):
    expected_revision: int = Field(ge=0)
    answer_state: str = Field(max_length=32)
    value: str | list[str] | None = None


class RevisionRequest(BaseModel):
    expected_revision: int = Field(ge=0)


class ConfirmRequest(RevisionRequest):
    acknowledged_issue_ids: list[str] = Field(default_factory=list)


class UncertaintyRequest(BaseModel):
    exact_text: str = Field(min_length=1, max_length=1000)


@router.get("/instruments/{instrument_version_id}")
def read_instrument(instrument_version_id: UUID, user: Owner, service: M2):
    # Authenticated users may inspect registered metadata; fieldability is
    # still indicated solely by the authoritative instrument approval state.
    return service.read_instrument(instrument_version_id)


@router.post("/assessments", status_code=201)
def new_assessment(payload: NewAssessment, user: Owner, service: M2):
    return service.create_assessment(payload.instrument_version_id, user.user_id)


@router.get("/assessments/{assessment_id}")
def read_assessment(assessment_id: UUID, user: Owner, service: M2):
    return service.read_assessment(assessment_id, user.user_id)


@router.put("/assessments/{assessment_id}/answers/{item_key}")
def update_answer(assessment_id: UUID, item_key: str, payload: AnswerUpdate,
                  user: Owner, service: M2):
    try:
        return service.update_answer(assessment_id, user.user_id,
            expected_revision=payload.expected_revision, item_key=item_key,
            state=payload.answer_state, value=payload.value)
    except M2ValidationError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.post("/assessments/{assessment_id}/bdj/evaluate")
def evaluate_bdj(assessment_id: UUID, user: Owner, service: BDJ):
    return service.evaluate(assessment_id, user.user_id)


@router.get("/assessments/{assessment_id}/business-understanding")
def read_business_understanding(assessment_id: UUID, user: Owner, service: BDJ):
    return service.read_worksheet(assessment_id, user.user_id)


@router.post("/assessments/{assessment_id}/review")
def record_review(assessment_id: UUID, payload: RevisionRequest, user: Owner,
                  service: Confirmation):
    return service.record_review(assessment_id, user.user_id, payload.expected_revision)


@router.post("/assessments/{assessment_id}/confirm")
def confirm_context(assessment_id: UUID, payload: ConfirmRequest, user: Owner,
                    service: Confirmation):
    return service.confirm(assessment_id, user.user_id,
        expected_revision=payload.expected_revision,
        acknowledged_issue_ids=payload.acknowledged_issue_ids)


@router.post("/confirmations/{confirmation_id}/uncertainty")
def confirm_research_uncertainty(confirmation_id: UUID, payload: UncertaintyRequest,
                                 user: Owner, service: Confirmation):
    try:
        return service.confirm_uncertainty(confirmation_id, user.user_id, payload.exact_text)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
