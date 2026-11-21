"""Opt-in, authenticated M2 upstream research API; no QJ or QG endpoints.

Routes are not registered unless settings.m2_upstream_enabled is explicitly true.
The database schema and authorized questionnaire records still require
separate Owner/governance approval and a controlled migration.
"""
from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from sqlalchemy.exc import SQLAlchemyError
from pydantic import BaseModel, ConfigDict, Field
from typing import Literal

from sitewise.dependencies import AuthenticatedUser, require_entrepreneur, get_m2_service, get_bdj_service, get_confirmation_service
from sitewise.domain.m2_rules import M2ValidationError
from sitewise.services.m2_service import M2Service
from sitewise.services.bdj_service import BDJService
from sitewise.services.confirmation_service import ConfirmationService
from sitewise.api.v1.m2_route import M2SourceRoute
from sitewise.dependencies import get_active_user, get_confirmed_review_service
from sitewise.services.confirmed_review_service import ConfirmedReview, ConfirmedReviewService

router = APIRouter(route_class=M2SourceRoute)
Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]
M2 = Annotated[M2Service, Depends(get_m2_service)]
BDJ = Annotated[BDJService, Depends(get_bdj_service)]
Confirmation = Annotated[ConfirmationService, Depends(get_confirmation_service)]


class M2Request(BaseModel):
    model_config = ConfigDict(extra='forbid')


@router.get('/assessments/{assessment_id}/confirmed-review', response_model=ConfirmedReview)
def read_confirmed_review(assessment_id: UUID, confirmation_id: UUID, user: Owner,
        response: Response,
        service: Annotated[ConfirmedReviewService, Depends(get_confirmed_review_service)],
        expected_revision: Annotated[int, Query(ge=0)]):
    response.headers['Cache-Control'] = 'no-store'
    try:
        return service.read(assessment_id, user.user_id, confirmation_id=confirmation_id,
                            expected_revision=expected_revision)
    except SQLAlchemyError as exc:
        raise HTTPException(status_code=503, headers={'Cache-Control': 'no-store'}, detail={
            'code': 'M2_REVIEW_SOURCE_UNAVAILABLE',
            'message': 'The complete business review source is unavailable. No substitute data was loaded.',
        }) from exc


class NewAssessment(M2Request):
    instrument_version_id: UUID


@router.get('/instruments')
def instruments(user:Owner,service:M2,response:Response,limit:int=Query(50,ge=1,le=100),offset:int=Query(0,ge=0)):
    response.headers['Cache-Control']='no-store'
    return service.list_instruments(limit,offset)


@router.get('/assessments')
def owned_assessments(user:Owner,service:M2,response:Response,limit:int=Query(50,ge=1,le=100),offset:int=Query(0,ge=0)):
    response.headers['Cache-Control']='no-store'
    return service.list_assessments(user.user_id,limit,offset)


@router.get('/assessments/{assessment_id}/source-projection')
def source_projection(assessment_id:UUID,user:Owner,service:M2,response:Response,
        expected_revision:int=Query(ge=0)):
    from sitewise.project1.projection import M2SourceProjection
    response.headers['Cache-Control']='no-store'
    return M2SourceProjection(service.repo).read(assessment_id,user.user_id,expected_revision)


@router.get('/assessments/{assessment_id}/activity')
def activity(assessment_id:UUID,user:Owner,service:M2,response:Response,limit:int=Query(50,ge=1,le=100)):
    response.headers['Cache-Control']='no-store'
    return service.activity(assessment_id,user.user_id,limit)


class AnswerUpdate(M2Request):
    expected_revision: int = Field(ge=0, strict=True)
    answer_state: str = Field(max_length=32)
    value: str | list[str] | dict[str, str] | None = None


class RevisionRequest(M2Request):
    expected_revision: int = Field(ge=0, strict=True)


class ConfirmRequest(RevisionRequest):
    acknowledged_issue_ids: list[str] = Field(default_factory=list)


class UncertaintyRequest(M2Request):
    exact_text: str = Field(min_length=1, max_length=1000)


class UncertaintyResponse(M2Request):
    id: UUID
    confirmation_id: UUID
    actor_user_id: UUID
    exact_text: str


class FindingDecisionRequest(RevisionRequest):
    decision: Literal['KEEP_ORIGINAL', 'REVIEW_LATER']
    request_id: UUID


@router.post('/assessments/{assessment_id}/findings/{finding_id}/decisions')
def decide_finding(assessment_id: UUID, finding_id: UUID,
                   payload: FindingDecisionRequest, user: Owner, service: Confirmation):
    return service.record_finding_decision(assessment_id, user.user_id,
        finding_id=finding_id, expected_revision=payload.expected_revision,
        decision=payload.decision, request_id=payload.request_id)


@router.get('/assessments/{assessment_id}/confirmations/{confirmation_id}')
def read_confirmation(assessment_id: UUID, confirmation_id: UUID, user: Owner,
        service: M2, response: Response, expected_revision: Annotated[int, Query(ge=0)]):
    response.headers['Cache-Control'] = 'no-store'
    return service.read_confirmed_source(assessment_id, user.user_id,
        confirmation_id=confirmation_id, expected_revision=expected_revision)


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
def evaluate_bdj(assessment_id: UUID, payload: RevisionRequest, user: Owner, service: BDJ):
    return service.evaluate(assessment_id, user.user_id, expected_revision=payload.expected_revision)


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


@router.post("/confirmations/{confirmation_id}/uncertainty", response_model=UncertaintyResponse)
def confirm_research_uncertainty(confirmation_id: UUID, payload: UncertaintyRequest,
                                 user: Owner, service: Confirmation):
    try:
        return service.confirm_uncertainty(confirmation_id, user.user_id, payload.exact_text)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

class ResearchObjectiveRequest(RevisionRequest):
    origin: Literal['BDJ', 'ENTREPRENEUR']
    objective: str = Field(min_length=1, max_length=1000)
    finding_id: UUID | None = None


@router.post("/confirmations/{confirmation_id}/research-objectives", status_code=201)
def confirm_objective(confirmation_id: UUID, payload: ResearchObjectiveRequest,
                      user: Owner, service: Confirmation):
    try:
        return service.confirm_objective(confirmation_id, user.user_id, payload.expected_revision,
                                         payload.objective, payload.origin, payload.finding_id)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

@router.get("/research-objectives/{objective_id}/qj-context")
def read_qj_context(objective_id: UUID, user: Owner, service: Confirmation, response: Response,
                    expected_revision: Annotated[int, Query(ge=0)]):
    response.headers["Cache-Control"] = "no-store"
    return service.qj_context(objective_id, user.user_id, expected_revision)

class ObjectiveRevisionRequest(RevisionRequest):
    action: Literal["CLARIFY", "EXPLORE"]
    clarification: str | None = Field(default=None, max_length=1000)


@router.post("/research-objectives/{objective_id}/confirmed-revisions", status_code=201)
def confirm_objective_revision(objective_id: UUID, payload: ObjectiveRevisionRequest,
                               user: Owner, service: Confirmation):
    try:
        return service.revise_objective(objective_id, user.user_id, payload.expected_revision,
                                        payload.action, payload.clarification)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

class DesiredOptionRequest(RevisionRequest):
    option_code: str | None = Field(max_length=100)


@router.get("/research-questions/{version}/entrepreneur-review")
def entrepreneur_question(version: UUID, user: Owner, service: Confirmation, response: Response,
                          expected_revision: Annotated[int, Query(ge=0)]):
    response.headers["Cache-Control"] = "no-store"
    return service.question_for_review(version, user.user_id, expected_revision)


@router.put("/research-questions/{version}/desired-option")
def choose_desired_option(version: UUID, payload: DesiredOptionRequest, user: Owner, service: Confirmation):
    try:
        return service.select_desired_option(version, user.user_id, payload.expected_revision, payload.option_code)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

class CandidateReviewRequest(M2Request):
    decision: Literal['APPROVE_FOR_REVIEW', 'REJECT']
    rationale: str = Field(min_length=1,max_length=1000)


@router.post('/research-questions/{version}/owner-review', status_code=201)
def owner_candidate_review(version: UUID, payload: CandidateReviewRequest,
                           reviewer: Annotated[AuthenticatedUser, Depends(get_active_user)],
                           service: Confirmation):
    try:
        return service.record_owner_review(version, reviewer.user_id, payload.decision, payload.rationale)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

@router.get('/confirmations/{confirmation_id}/research-workspace')
def research_workspace(confirmation_id: UUID, user: Owner, service: Confirmation, response: Response,
                       expected_revision: Annotated[int, Query(ge=0)]):
    response.headers["Cache-Control"] = "no-store"
    record = service.repo.get_confirmation(confirmation_id, user.user_id)
    if record is None or record["assessment_revision"] != expected_revision:
        raise HTTPException(status_code=404, detail="Current confirmation unavailable.")
    return {"objectives": service.repo.research_workspace(confirmation_id,user.user_id,expected_revision)}


@router.get('/candidate-review-assignments')
def review_assignments(reviewer: Annotated[AuthenticatedUser, Depends(get_active_user)],
                       service: Confirmation, response: Response):
    response.headers["Cache-Control"] = "no-store"
    return {"assignments": service.repo.assigned_candidate_reviews(reviewer.user_id)}

class WorkflowSummary(BaseModel):
    campaigns: list[dict] | None
    review_events: list[dict]
    clarifications: list[dict]
    assessment: dict
    confirmations: list[dict]
    contexts: list[dict]
    builds: list[dict]
    bdj_evaluations: list[dict]
    findings: list[dict]
    objectives: list[dict]
    candidates: list[dict]
    llm_execution: Literal['NOT_VERIFIED']
    scientific_review: Literal['NOT_VERIFIED']
    fielding: Literal['NOT_VERIFIED']
    report_admission: Literal['NOT_VERIFIED']


class WorkflowOverview(BaseModel):
    projection_id: UUID
    assessment_id: UUID
    assessment_revision: int
    schema_version: Literal['workflow-overview/1']
    projection_sequence: int
    source_fingerprint: str
    projection_data: WorkflowSummary
    created_at: datetime
    is_current: bool


@router.get('/assessments/{assessment_id}/workflow-overview', response_model=WorkflowOverview)
def workflow_overview(assessment_id: UUID, user: Owner, service: M2, response: Response,
                      sequence: Annotated[int | None, Query(ge=1)] = None):
    response.headers['Cache-Control'] = 'private, no-store'
    try:
        row = service.repo.workflow_overview(assessment_id,user.user_id,sequence)
    except SQLAlchemyError as exc:
        raise HTTPException(status_code=503, detail='Workflow overview unavailable.',
                            headers={'Cache-Control':'no-store'}) from exc
    if row is None:
        raise HTTPException(status_code=404,detail='Workflow overview unavailable.')
    return dict(row)
