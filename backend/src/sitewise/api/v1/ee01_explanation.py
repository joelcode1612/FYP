"""Candidate EE-01 explanation surface. Default-held; no admission or report write.

Mounted unconditionally so the hold is discoverable (a 503 explains itself),
rather than silently absent behind a flag. Every response is no-store.
"""
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, ConfigDict, Field

from sitewise.core.config import settings
from sitewise.dependencies import AuthenticatedUser, require_entrepreneur
from sitewise.domain.cq_runtime import CqRefused

router = APIRouter()
Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]


def get_explanation_service():
    if not settings.ee01_explanation_enabled:
        raise HTTPException(503, detail={'code': 'EXPLANATION_MODULE_HOLD',
            'message': 'EE-01 explanation candidates are not activated.'},
            headers={'Cache-Control': 'no-store'})
    # Reuse the EE-01 target verification: restricted principal, expected DB,
    # no fallback to the application or analytics connections.
    from sitewise.api.v1.customer_questionnaire import get_ee01_service
    from sitewise.services.ee01_explanation_service import Ee01ExplanationService
    return Ee01ExplanationService(get_ee01_service())


Service = Annotated[object, Depends(get_explanation_service)]


class Strict(BaseModel):
    model_config = ConfigDict(extra='forbid')


class ExplainRequest(Strict):
    task_mode: str = Field(pattern=r'^(CLAIM_EXPLANATION|REPORT_SYNTHESIS)$')
    claim_ids: list[str] = Field(default_factory=list, max_length=32)
    context_hash: str = Field(pattern=r'^[0-9a-f]{64}$')


# Namespaced under /explanations: the CQ router already owns /cq/availability.
@router.get('/explanations/availability')
def availability(user: Owner, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    return {'contract_version': 'ee01-explanation-availability/1', 'state': 'held',
        'code': 'EXPLANATION_MODULE_HOLD',
        'message': 'Explanation candidates require an admitted measurement, a disclosure '
                   'adapter and a reviewed attempt ledger row.',
        'candidate_generation_authorized': False, 'report_admission_authorized': False}


@router.post('/assessments/{assessment_id}/campaigns/{campaign_id}/measurements/{snapshot_id}/explanations')
def explain(assessment_id: UUID, campaign_id: UUID, snapshot_id: UUID,
            body: ExplainRequest, user: Owner, service: Service, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    try:
        return service.explain(user.user_id, assessment_id, campaign_id, snapshot_id,
            task_mode=body.task_mode, claim_ids=body.claim_ids, context_hash=body.context_hash)
    except CqRefused as exc:
        raise HTTPException(exc.status, detail={'code': exc.code,
            'message': 'The explanation could not be authorized or completed.'},
            headers={'Cache-Control': 'no-store'}) from exc
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(503, detail={'code': 'EXPLANATION_CONTEXT_UNAVAILABLE',
            'message': 'The versioned EE-01 explanation context is unavailable.'},
            headers={'Cache-Control': 'no-store'}) from exc
