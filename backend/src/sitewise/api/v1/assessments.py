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

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, Field
from sqlalchemy.exc import SQLAlchemyError
from sqlmodel import Session

from sitewise.core.exceptions import AssessmentError
from sitewise.db.analytics_session import get_analytics_db
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, require_entrepreneur, get_m2_service
from sitewise.api.v1.m2 import get_assessment_link_service
from sitewise.repositories.catalog_repository import CatalogRepository
from sitewise.services.assessment_service import AssessmentService
from sitewise.services.explanation_service import ExplanationService
from sitewise.services.report_service import ReportService
from sitewise.services.report_measurement import resolve_report_measurement
from sitewise.api.v1.report_business_description import (
    get_report_business_description_service,
)

router = APIRouter()

EntrepreneurUser = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]
AppSession = Annotated[Session, Depends(get_db)]
AnalyticsSession = Annotated[Session, Depends(get_analytics_db)]
#: Resolved through ``Depends`` so FastAPI fills the provider's own nested
#: dependencies. The provider is imported at module scope deliberately: it is
#: mounted unconditionally, so it cannot drag in the M2 stage module that this
#: router must stay importable without.
BusinessDescriptionService = Annotated[
    Any, Depends(get_report_business_description_service)]


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


@router.get("/{assessment_id}/workflow-readiness")
def read_workflow_readiness(
    assessment_id: uuid.UUID,
    session: AppSession,
    analytics: AnalyticsSession,
    user: EntrepreneurUser,
    response: Response,
    link_service: Annotated[object, Depends(get_assessment_link_service)],
    m2_service: Annotated[object, Depends(get_m2_service)],
) -> dict:
    """Evaluate current M2 readiness without changing legacy stage records."""
    from sitewise.services.assessment_link_service import AssessmentLinkError
    from sitewise.services.assessment_workflow_readiness import workflow_readiness

    response.headers["Cache-Control"] = "private, no-store"
    assessment = _service(session, analytics).get_owned(assessment_id, user.user_id)
    try:
        return workflow_readiness(assessment, user.user_id, user.email, link_service, m2_service)
    except AssessmentLinkError as exc:
        raise HTTPException(status_code=exc.status_code,
                            detail={"code": exc.code, "message": str(exc)}) from exc
    except SQLAlchemyError as exc:
        raise HTTPException(status_code=503, detail={
            "code": "WORKFLOW_READINESS_UNAVAILABLE",
            "message": "The assessment's confirmation could not be verified. Try again.",
        }) from exc


@router.get("/{assessment_id}/questionnaire-preview")
def questionnaire_preview(
    assessment_id: uuid.UUID,
    session: AppSession,
    analytics: AnalyticsSession,
    user: EntrepreneurUser,
    response: Response,
    link_service: Annotated[object, Depends(get_assessment_link_service)],
    m2_service: Annotated[object, Depends(get_m2_service)],
) -> dict:
    """Read-only source status; no campaign, session or sample question is made.

    The existing CQ release and candidate APIs do not yet supply an adopted
    assessment-bound preview contract. Until they do, expose an explicit hold
    rather than claiming their contents are available or authorized.
    """
    readiness = read_workflow_readiness(assessment_id, session, analytics, user,
                                        response, link_service, m2_service)
    stage = readiness['stage_2']
    return {
        'contract_version': 'sitewise-questionnaire-preview/1',
        'marketplace_assessment_id': str(assessment_id),
        'm2_assessment_id': stage.get('m2_assessment_id'),
        'confirmation_id': stage.get('confirmation_id'),
        'assessment_revision': stage.get('assessment_revision'),
        'status': 'UNAVAILABLE',
        'reason': ('QUESTIONNAIRE_SOURCE_PROJECTION_UNVERIFIED' if stage['complete']
                   else stage.get('reason', 'CURRENT_CONFIRMATION_REQUIRED')),
        'question_items': [],
        'fielding_authorized': False,
        'publication_authorized': False,
    }


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


@router.delete("/{assessment_id}", status_code=204)
def delete_assessment(
    assessment_id: uuid.UUID,
    session: AppSession,
    analytics: AnalyticsSession,
    user: EntrepreneurUser,
) -> None:
    """Owner-scoped CP-12 discard; 204 only after durable completion.

    Missing provisioning or protected dependencies refuse the operation. Retrying
    the same owner/assessment resumes the same durable discard operation.
    """
    _service(session, analytics).delete_owned(assessment_id, user.user_id)


@router.post("/{assessment_id}/explanation")
def explain_assessment(
    assessment_id: uuid.UUID,
    session: AppSession,
    analytics: AnalyticsSession,
    user: EntrepreneurUser,
) -> dict:
    """Genuine SHAP for this assessment's property, then confirm the stage.

    The stage is only recorded after an explanation that reconstructs the
    model output exists. A missing artifact, missing ``shap`` package, missing
    features or an additive-inconsistency all raise a coded error instead of
    returning placeholder values, so Stage 4 can never be marked complete on
    unverified output.
    """
    service = _service(session, analytics)
    assessment = service.get_owned(assessment_id, user.user_id)
    payload = ExplanationService(session, analytics).explain_assessment(assessment)
    assessment = service.update(assessment, complete_stage="ai_explanation")
    return {
        "explanation": payload,
        "assessment": service.payload(assessment),
    }


@router.get("/{assessment_id}/explanation")
def get_assessment_explanation(
    assessment_id: uuid.UUID,
    session: AppSession,
    analytics: AnalyticsSession,
    user: EntrepreneurUser,
) -> dict:
    """Read the persisted validated explanation; never compute or advance.

    ``{"explanation": null}`` means Stage 4 has not produced one yet. The Full
    Analysis page shows that honest state instead of calling the POST, which
    would run permutation SHAP and confirm a stage as a side effect.
    """
    service = _service(session, analytics)
    assessment = service.get_owned(assessment_id, user.user_id)
    explanation = ExplanationService(
        session, analytics
    ).latest_for_assessment(assessment)
    return {"explanation": explanation}


@router.get("/{assessment_id}/report")
def assessment_report(
    assessment_id: uuid.UUID,
    session: AppSession,
    analytics: AnalyticsSession,
    user: EntrepreneurUser,
) -> dict:
    """The five-stage report for this assessment.

    Assembled from the persisted record, the property report, the analysed
    evidence and the stored SHAP explanation. Sections without backing data
    report ``available: false`` with a reason; the report is never padded with
    invented evidence.
    """
    service = _service(session, analytics)
    assessment = service.get_owned(assessment_id, user.user_id)
    return _report_payload(
        service=service, assessment=assessment, session=session,
        analytics=analytics, user=user,
    )


def _report_payload(
    *, service, assessment, session, analytics, user, record=None,
) -> dict:
    """The report body, shared by ``/report`` and ``/report-composition``.

    Extracted rather than duplicated: the composition endpoint has to see the
    *same* report a reader sees, so it must not build a second, thinner one that
    could disagree with it about which sections have evidence.

    ``record`` is the already-computed ``service.payload(assessment)``. The
    composition route reads it for its own identity fields, and passing it in
    stops that read from being issued twice for one document.
    """
    if record is None:
        record = service.payload(assessment)

    property_report = None
    try:
        property_report = ReportService(session).generate_property_report(
            assessment.property_id
        )
    except HTTPException:
        # The listing left the published catalogue; the report says so rather
        # than failing the whole request.
        property_report = None

    # Stage-3 evidence is the analysed location record the standalone
    # /catalog/properties/{id}/evidence endpoint serves. An analytics failure
    # must degrade the evidence section, never fail the whole report.
    try:
        evidence = CatalogRepository(analytics).get_evidence(
            assessment.property_id)
    except (SQLAlchemyError, KeyError, ValueError):
        evidence = None
    explanation = ExplanationService(
        session, analytics
    ).latest_for_assessment(assessment)

    # The questionnaire association: marketplace assessment -> M2 (already
    # resolved and owner-checked inside ``payload``) -> campaign -> frozen
    # snapshot. It carries identity and admission only, never a count, so this
    # read cannot publish a withheld finding. A questionnaire store that cannot
    # be reached degrades the section with a named reason; it never fails the
    # report, and it never renders as a measured zero.
    measurement = resolve_report_measurement(
        record=record,
        actor_user_id=user.user_id,
        ee01_factory=_ee01_service_for_report,
    )

    return ReportService(session).generate_assessment_report(
        assessment=record,
        property_report=property_report,
        explanation=explanation,
        evidence=evidence,
        measurement=measurement,
    )


def _ee01_service_for_report():
    """The restricted-principal EE-01 service, resolved lazily.

    Imported inside the call because the dependency lives on the questionnaire
    router, which imports this package's models. Resolving it lazily also keeps
    an unconfigured questionnaire store from breaking the import graph — the
    resolver catches the resulting 503 and reports ``UNAVAILABLE``.
    """
    from sitewise.api.v1.customer_questionnaire import get_ee01_service

    return get_ee01_service()


@router.get("/{assessment_id}/report-composition")
def assessment_report_composition(
    assessment_id: uuid.UUID,
    session: AppSession,
    analytics: AnalyticsSession,
    user: EntrepreneurUser,
    response: Response,
    description_service: BusinessDescriptionService,
) -> dict:
    """The nine-section composition for this assessment.

    Separate from ``/report`` because it answers a different question and costs
    different work. ``/report`` returns the five-stage evidence payload; this
    returns *which sections exist for this record, in what state, from which
    sources* — the decision that previously lived only in the Jaspr view, where
    a second consumer could not obtain it and the A10 section contract was never
    consulted.

    It reuses ``/report``'s own body rather than building a thinner report, so
    the composition cannot disagree with the document it describes. It adds one
    read the report never needed: the Section B question-design records.
    """
    from sitewise.core.config import settings
    from sitewise.db.m2_session import get_m2_engine
    from sitewise.project1 import a10_decisions, a10_gates
    from sitewise.services import report_composition
    from sitewise.services.report_additional_research import load_additional_research
    from sitewise.services.report_findings_state import load_findings_state

    response.headers['Cache-Control'] = 'no-store'

    service = _service(session, analytics)
    assessment = service.get_owned(assessment_id, user.user_id)
    record = service.payload(assessment)
    report = _report_payload(
        service=service, assessment=assessment, session=session,
        analytics=analytics, user=user, record=record,
    )

    # Section 02's own source. A held state here is data for the composition,
    # never an error: the section reports the absence with its reason code.
    description: dict | None = None
    if settings.m2_upstream_enabled:
        try:
            description = description_service.for_assessment(
                marketplace_assessment_id=assessment_id,
                user_id=user.user_id,
                role=user.role,
                verified_email=user.email,
            )
        except Exception as exc:  # noqa: BLE001 - a section state, not a 500
            description = {
                'status': 'UNAVAILABLE',
                'reason_code': 'BUSINESS_DESCRIPTION_UNAVAILABLE',
                'detail': ('The confirmed business description could not be read '
                           'while this report was composed '
                           f'({type(exc).__name__}).'),
            }
    else:
        description = {
            'status': 'UNAVAILABLE',
            'reason_code': 'M2_STAGE_NOT_ENABLED',
            'detail': ('The upstream business-declaration stage is not enabled '
                       'for this deployment, so no confirmed business context '
                       'exists to read.'),
        }

    # Section B. The M2 tables are RLS-scoped on ``project1.actor_id``, so this
    # runs on its own M2 session with the caller bound transaction-locally.
    # Section 03 reads the same store for the same reason: whether a finding
    # evaluation ran is an M2 fact, and the report may not assert it without
    # looking.
    m2_id = (record.get('m2_confirmation') or {}).get('m2_assessment_id')
    additional = None
    findings = None
    if m2_id:
        try:
            with Session(get_m2_engine()) as m2_session:
                additional = load_additional_research(
                    m2_session, actor_id=user.user_id, m2_assessment_id=str(m2_id),
                )
                findings = load_findings_state(
                    m2_session, actor_id=user.user_id, m2_assessment_id=str(m2_id),
                    has_measurement=bool(
                        (report.get('measurement') or {}).get('slots')),
                )
        except Exception as exc:  # noqa: BLE001 - degrades to a named state
            additional = {
                'status': 'UNAVAILABLE',
                'reason_code': 'ADDITIONAL_RESEARCH_UNAVAILABLE',
                'detail': ('The additional-research store could not be opened '
                           f'({type(exc).__name__}).'),
                'objectives': [], 'items': [],
            }

    return report_composition.compose(
        assessment=record,
        report=report,
        measurement=report.get('measurement'),
        business_description=description,
        additional=additional,
        findings=findings,
        section_map=a10_gates.section_map(),
        a10_counts=a10_gates.counts(),
        decision_counts=a10_decisions.counts(),
        adopted_decision_count=len(a10_decisions.adopted()),
        embed_report=True,
    )
