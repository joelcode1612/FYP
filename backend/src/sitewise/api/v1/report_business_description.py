"""RP-13 — `GET /assessments/{id}/business-description`.

Read-only. Returns the confirmed Business Context description bound to this
assessment, or an explicit held state that says which prerequisite is missing.

Mounted unconditionally so the section always has an answer: when the M2 stage is
switched off the route reports ``M2_STAGE_NOT_ENABLED`` instead of 404, which is
what lets the report print "no confirmed business context" rather than an error
or a blank card.
"""
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Response

from sitewise.core.config import settings
from sitewise.dependencies import (
    AuthenticatedUser, get_persisted_business_context_service, require_entrepreneur,
)
from sitewise.services.report_business_description import (
    CONTRACT_VERSION, ReportBusinessDescriptionService,
)

router = APIRouter()
Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]


def get_report_business_description_service(
        contexts=Depends(get_persisted_business_context_service)):
    """Compose the link reader and the BCB readback.

    Deliberately not imported from ``api.v1.m2``: that module is only imported
    when the upstream stage is enabled, and this route must stay mountable while
    it is not. The two dependencies it needs are the same objects, built the
    same way.

    ``contexts`` arrives through ``Depends`` rather than being called here: the
    provider's own parameters are ``Depends(...)`` markers, so calling it
    directly would hand the service a marker object instead of a resolver and
    fail at request time with ``'Depends' object is not callable``.
    """
    from sitewise.db.m2_session import get_m2_engine
    from sitewise.db.session import engine as marketplace_engine
    from sitewise.services.assessment_link_service import AssessmentLinkService

    return ReportBusinessDescriptionService(
        links=AssessmentLinkService(marketplace_engine=marketplace_engine,
                                    m2_engine=get_m2_engine()),
        contexts=contexts,
    )


Service = Annotated[ReportBusinessDescriptionService,
                    Depends(get_report_business_description_service)]


@router.get('/{assessment_id}/business-description')
def business_description(assessment_id: UUID, user: Owner, response: Response,
                         service: Service):
    response.headers['Cache-Control'] = 'no-store'
    if not settings.m2_upstream_enabled:
        # Not an error: the report renders its held state from this answer.
        return {
            'contract_version': CONTRACT_VERSION,
            'status': 'UNAVAILABLE',
            'reason_code': 'M2_STAGE_NOT_ENABLED',
            'detail': 'The upstream business-declaration stage is not enabled '
                      'for this deployment, so no confirmed business context '
                      'exists to read.',
            'source': None, 'rows': [], 'uncertainty': None,
            'limitations': [], 'evidence_class': None,
        }
    return service.for_assessment(
        marketplace_assessment_id=assessment_id,
        user_id=user.user_id,
        role=user.role,
        verified_email=user.email,
    )
