"""Opt-in, authenticated M2 upstream research API; no QJ or QG endpoints.

Routes are not registered unless settings.m2_upstream_enabled is explicitly true.
The database schema and authorized questionnaire records still require
separate Owner/governance approval and a controlled migration.
"""
from datetime import datetime
from typing import Annotated, Any, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from sqlalchemy.exc import SQLAlchemyError
from pydantic import BaseModel, ConfigDict, Field
from typing import Literal

from sitewise.dependencies import AuthenticatedUser, require_entrepreneur, get_m2_service, get_bdj_service, get_confirmation_service
from sitewise.modules.decision_engine.domain.m2_rules import M2ValidationError
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


@router.get('/assessments/{assessment_id}/bdj/current')
def read_current_bdj(assessment_id: UUID, confirmation_id: UUID, user: Owner,
                     service: M2, response: Response,
                     expected_revision: Annotated[int, Query(ge=0)]):
    """Return only a result bound to this owner and current confirmed source."""
    response.headers['Cache-Control'] = 'private, no-store'
    from sitewise.services.m2_bdj_execution import read_current_bdj as read
    return read(service, user, assessment_id, confirmation_id, expected_revision)


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


# --- assessment -> M2 link (CP-10F) -----------------------------------------
# The marketplace assessment lives in Final_Location_Analysis; the M2 assessment
# and its link live in Dss. These routes are the only sanctioned way to cross
# that boundary, and they never guess a relationship.

def get_assessment_link_service():
    from sitewise.db.m2_session import get_m2_engine
    from sitewise.db.session import engine as marketplace_engine
    from sitewise.services.assessment_link_service import AssessmentLinkService
    return AssessmentLinkService(marketplace_engine=marketplace_engine,
                                 m2_engine=get_m2_engine())


Link = Annotated[object, Depends(get_assessment_link_service)]


def _link_error(exc):
    from sitewise.services.assessment_link_service import AssessmentLinkError
    if not isinstance(exc, AssessmentLinkError):
        raise exc
    raise HTTPException(status_code=exc.status_code,
                        detail={'code': exc.code, 'message': str(exc)})


@router.get('/assessments/by-marketplace/{assessment_id}')
def resolve_assessment_link(assessment_id: UUID, user: Owner, response: Response,
                            service: Link):
    """Read the active link for a marketplace assessment. Never creates."""
    from sitewise.services.assessment_link_service import AssessmentLinkError
    response.headers['Cache-Control'] = 'no-store'
    try:
        result = service.resolve(marketplace_assessment_id=assessment_id,
                                 user_id=user.user_id,
                                 verified_email=user.email,
                                 create_if_missing=False)
    except AssessmentLinkError as exc:
        _link_error(exc)
    return result.as_dict()


@router.post('/assessments/by-marketplace/{assessment_id}/link')
def initialize_assessment_link(assessment_id: UUID, user: Owner, response: Response,
                               service: Link):
    """Resolve, or create once, the M2 assessment for a marketplace assessment.

    Idempotent: a second call returns the same M2 assessment with created=false.
    Creates no CQ campaign and no downstream research artefact.
    """
    from sitewise.services.assessment_link_service import AssessmentLinkError
    response.headers['Cache-Control'] = 'no-store'
    try:
        result = service.resolve(marketplace_assessment_id=assessment_id,
                                 user_id=user.user_id,
                                 verified_email=user.email,
                                 create_if_missing=True)
    except AssessmentLinkError as exc:
        _link_error(exc)
    return result.as_dict()


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
    # Structured (COMPOSITE) answers carry nested objects and lists, so the
    # value cannot be narrowed to ``dict[str, str]``. Shape is enforced by
    # validate_m2_answer against the item's declared value_schema, not here.
    value: Any = None
    marketplace_assessment_id: UUID | None = None


class RevisionRequest(M2Request):
    expected_revision: int = Field(ge=0, strict=True)


class BoundRevisionRequest(RevisionRequest):
    marketplace_assessment_id: UUID | None = None


class AiProcessingConsentRequest(M2Request):
    """The owner's decision about sending declarations to a cloud model.

    Every field here is an *echo* of what the interface showed. The server
    re-derives each term from canonical constants, so this model cannot widen
    the disclosure — it can only agree with it or be refused.
    """
    granted: bool
    disclosure_version: str = Field(min_length=1, max_length=64)
    provider: str = Field(min_length=1, max_length=64)
    purpose: str = Field(min_length=1, max_length=500)
    endpoint: str = Field(min_length=1, max_length=300)
    model: str = Field(min_length=1, max_length=200)


class ConfirmRequest(BoundRevisionRequest):
    acknowledged_issue_ids: list[str] = Field(default_factory=list)
    #: Omitted means "no permission granted". It is never inferred from the act
    #: of confirming declarations.
    ai_processing: AiProcessingConsentRequest | None = None
    #: The QG permission, a separate grant with its own version and purpose.
    #: Omitted means absent, which is *not* the same as declined — and neither
    #: one authorises a QG dispatch.
    ai_processing_qg: AiProcessingConsentRequest | None = None


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
            state=payload.answer_state, value=payload.value,
            marketplace_assessment_id=payload.marketplace_assessment_id)
    except M2ValidationError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.post("/assessments/{assessment_id}/bdj/evaluate")
def evaluate_bdj(assessment_id: UUID, payload: RevisionRequest, user: Owner, service: M2):
    """Confirmed declarations are required before the governed BDJ path."""
    row = service.repo.latest_confirmation(assessment_id, user.user_id)
    if row is None:
        raise HTTPException(409, detail={'code':'M2_CONFIRMATION_REQUIRED',
            'message':'Confirm the current saved M2 declarations before BDJ evaluation.'})
    with service.locked_confirmed_source(assessment_id, user.user_id,
            confirmation_id=row['id'], expected_revision=payload.expected_revision):
        pass
    from sitewise.services.m2_bdj_execution import execute_confirmed_bdj
    return execute_confirmed_bdj(service, user, assessment_id, payload.expected_revision)


@router.get("/assessments/{assessment_id}/business-understanding")
def read_business_understanding(assessment_id: UUID, user: Owner, service: BDJ):
    return service.read_worksheet(assessment_id, user.user_id)


@router.post("/assessments/{assessment_id}/review")
def record_review(assessment_id: UUID, payload: BoundRevisionRequest, user: Owner,
                  service: Confirmation):
    return service.record_review(assessment_id, user.user_id, payload.expected_revision,
                                 marketplace_assessment_id=payload.marketplace_assessment_id)


@router.post("/assessments/{assessment_id}/confirm")
def confirm_context(assessment_id: UUID, payload: ConfirmRequest, user: Owner,
                    service: Confirmation):
    from sitewise.project1.ai_processing_consent import build_consent
    from sitewise.project1.ai_processing_consent import build_qg_consent
    from sitewise.project1.provider import ENDPOINT, MODEL
    try:
        consent = build_consent(request=payload.ai_processing, endpoint=ENDPOINT,
                                model=MODEL, owner_id=user.user_id)
        # A second, independently versioned grant. It is built even when the
        # client omits it, so every new snapshot records the *absence* of the
        # QG permission explicitly rather than leaving a reader to infer it.
        consent_qg = build_qg_consent(request=payload.ai_processing_qg,
                                      endpoint=ENDPOINT, model=MODEL,
                                      owner_id=user.user_id)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail={
            'code': getattr(exc, 'args', ['AI_PROCESSING_DISCLOSURE_MISMATCH'])[0],
            'message': 'The AI-processing permission did not match the terms disclosed '
                       'by this release. Reload the disclosure and decide again.'}) from exc
    return service.confirm(assessment_id, user.user_id,
        expected_revision=payload.expected_revision,
        acknowledged_issue_ids=payload.acknowledged_issue_ids,
        marketplace_assessment_id=payload.marketplace_assessment_id,
        ai_processing=consent, ai_processing_qg=consent_qg)


@router.get("/ai-processing-disclosure")
def read_ai_processing_disclosure():
    """The exact terms the interface must display before asking for consent."""
    from sitewise.project1.ai_processing_consent import disclosure
    return disclosure({})


@router.get("/ai-processing-disclosure-qg")
def read_ai_processing_qg_disclosure():
    """The exact terms for the *separate* question-generation permission.

    A distinct route because it is a distinct grant: an interface that showed
    one set of terms for both acts would be asking the owner to agree to
    something the disclosure never described.
    """
    from sitewise.project1.ai_processing_consent import qg_disclosure
    return qg_disclosure()


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
    # Must agree with m2_candidate_owner_reviews_decision_check
    # (migrations/m2/20261118_02_candidate_review_v2.sql). A value the database
    # rejects would turn a 422 into a 500.
    decision: Literal['APPROVE_FOR_REVIEW', 'REJECT', 'REQUEST_REVISION']
    rationale: str = Field(default='', max_length=1000)


@router.post('/research-questions/{version}/owner-review', status_code=201)
def owner_candidate_review(version: UUID, payload: CandidateReviewRequest,
                           reviewer: Annotated[AuthenticatedUser, Depends(get_active_user)],
                           service: Confirmation):
    try:
        return service.record_owner_review(version, reviewer.user_id, payload.decision, payload.rationale)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except SQLAlchemyError as exc:
        # The older Dss schema lacks the reviewed context-hash column. Do not
        # fall back to an unbound review or expose database diagnostics.
        if getattr(getattr(exc, 'orig', None), 'pgcode', None) == '42703':
            raise HTTPException(status_code=503, detail={
                'code': 'CANDIDATE_REVIEW_SCHEMA_UNAVAILABLE',
                'message': 'Question review is unavailable until its versioned storage schema is provisioned.',
            }) from exc
        raise

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


@router.get('/assessments/{assessment_id}/confirmation-current')
def read_current_confirmation(assessment_id: UUID, user: Owner, service: M2,
                              response: Response):
    """Read-only current-confirmation lookup.

    CP-10 DEF-06: the M2 panel kept the confirmation only in memory, so any
    reload left 'Save research objective' permanently dead while the server
    refuses a duplicate confirm. This read-only endpoint lets the panel
    restore the persisted confirmation state without weakening any write
    guard. Returns 404 when no confirmation exists.
    """
    response.headers['Cache-Control'] = 'private, no-store'
    row = service.repo.latest_confirmation(assessment_id, user.user_id)
    if row is None or not row['is_current']:
        raise HTTPException(status_code=404, detail='No confirmation recorded for this assessment.')
    with service.locked_confirmed_source(assessment_id, user.user_id,
            confirmation_id=row['id'], expected_revision=row['assessment_revision']) as source:
        return {**dict(row), 'snapshot_contract_version':source['snapshot'].get('snapshot_contract_version'),
                'snapshot_digest':source['snapshot_digest']}


@router.get('/assessments/{assessment_id}/concept-preview')
def read_concept_preview(assessment_id: UUID, user: Owner, service: M2,
                         response: Response,
                         expected_revision: int | None = Query(None, ge=0)):
    """Read-only draft concept preview for M2 V2, before M2-21 confirmation.

    The projection is the same one the confirmed Business Context Builder uses,
    so the entrepreneur reviews the real concept rather than a second rendering
    of it. Nothing is written: no confirmation snapshot, no BCB, no answer
    revision. ``confirmation_id`` is null on every reference precisely because
    no confirmation exists yet.
    """
    response.headers['Cache-Control'] = 'private, no-store'
    assessment = service.repo.get_assessment(assessment_id, user.user_id)
    if assessment is None:
        # Owner-scoped: another owner's assessment is indistinguishable from a
        # missing one, so nothing about its existence leaks.
        raise HTTPException(status_code=404, detail='Assessment not found.')
    if expected_revision is not None and expected_revision != assessment['revision']:
        raise HTTPException(status_code=409, detail={
            'code': 'M2_PREVIEW_STALE_REVISION',
            'message': 'The assessment changed after the preview was requested. Reload and try again.'})
    instrument = service.repo.get_instrument(assessment['instrument_id'])
    if instrument is None:
        raise HTTPException(status_code=503, detail={
            'code': 'M2_INSTRUMENT_UNAVAILABLE',
            'message': 'The assessment instrument could not be read.'})
    from sitewise.services.instrument_authorization import (
        authorization_reason, instrument_is_usable)
    if not instrument_is_usable(instrument):
        raise HTTPException(status_code=503, detail={
            'code': 'INSTRUMENT_UNAUTHORIZED', 'message': authorization_reason(instrument)})
    if not instrument['version_tag'].startswith('M2V2-'):
        raise HTTPException(status_code=409, detail={
            'code': 'CONCEPT_PREVIEW_UNSUPPORTED_INSTRUMENT',
            'message': 'The deterministic concept preview is defined for the M2 V2 instrument only.'})
    items = service.repo.list_items(assessment['instrument_id'])
    answers = service.repo.get_latest_answers(assessment_id, assessment['revision'])
    from sitewise.services.m2_concept_preview import build_concept_preview
    return build_concept_preview(assessment, instrument, items, answers)


@router.get('/assessments/{assessment_id}/questionnaire-preview')
def read_questionnaire_preview(assessment_id: UUID, user: Owner, service: M2,
                               response: Response):
    """Read-only draft preview of the assessment-bound research questionnaire.

    Stage 5. It reuses the persisted objective and question rows that already
    exist — it does not assemble a new questionnaire, adopt a policy or authorise
    fielding. Every item is labelled ``accepted: False`` because no adopted
    preview contract exists yet, and the envelope always reports
    ``fielding_authorized`` and ``publication_authorized`` as false.

    When there is nothing to preview it returns the specific blocker rather than
    an empty list that would read as "no questions needed".
    """
    response.headers['Cache-Control'] = 'private, no-store'
    assessment = service.repo.get_assessment(assessment_id, user.user_id)
    if assessment is None:
        raise HTTPException(status_code=404, detail='Assessment not found.')

    def envelope(status, reason, confirmation=None, items=None):
        return {
            'contract_version': 'sitewise-questionnaire-preview/1',
            'm2_assessment_id': str(assessment_id),
            'assessment_revision': assessment['revision'],
            'confirmation_id': str(confirmation['id']) if confirmation else None,
            'status': status,
            'reason': reason,
            'question_items': items or [],
            'draft_only': True,
            'fielding_authorized': False,
            'publication_authorized': False,
        }

    row = service.repo.latest_confirmation(assessment_id, user.user_id)
    if row is None:
        return envelope('UNAVAILABLE', 'CURRENT_CONFIRMATION_REQUIRED')
    if not row['is_current']:
        return envelope('UNAVAILABLE', 'CONFIRMATION_STALE', row)

    rows = service.repo.research_workspace(
        row['id'], user.user_id, row['assessment_revision'])
    if not rows:
        return envelope('UNAVAILABLE', 'NO_ADMITTED_OBJECTIVE', row)

    items = []
    for entry in rows:
        if not entry.get('version') or not entry.get('question'):
            continue
        options = entry.get('options') or []
        if isinstance(options, dict):
            options = options.get('options') or []
        items.append({
            'objective_id': str(entry['id']),
            'objective_text': entry['exact_text'],
            'objective_authority': entry.get('approval_status'),
            'question_version': str(entry['version']),
            'question': entry['question'],
            'options': options,
            'accepted': False,
            'source': 'm2_review_question_versions',
        })
    if not items:
        return envelope('UNAVAILABLE', 'NO_VALIDATED_QUESTION', row)

    # A question exists, but the adopted preview contract still does not, so the
    # status stays a draft. Claiming READY here would be the fabrication this
    # endpoint exists to prevent.
    return envelope('DRAFT_AVAILABLE', 'QUESTIONNAIRE_SOURCE_PROJECTION_UNVERIFIED',
                    row, items)


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
