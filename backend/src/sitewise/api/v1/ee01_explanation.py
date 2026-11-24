"""Candidate EE-01 explanation surface. Default-held; no admission or report write.

Mounted unconditionally so the hold is discoverable (a 503 explains itself),
rather than silently absent behind a flag. Every response is no-store.
"""
import re
from functools import lru_cache
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.engine import make_url

from sitewise.core.config import settings
from sitewise.dependencies import AuthenticatedUser, require_entrepreneur
from sitewise.domain.cq_runtime import CqRefused
from sitewise.project1.contracts import WorkflowHeld

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


@lru_cache(maxsize=2)
def _explanation_store_engine(raw_url: str):
    from sqlalchemy import create_engine
    return create_engine(raw_url, hide_parameters=True, pool_pre_ping=True)


def get_explanation_read_service(user: Owner):
    if not settings.ee01_explanation_enabled:
        raise HTTPException(503, detail={'code': 'EXPLANATION_MODULE_HOLD',
            'message': 'EE-01 explanation candidates are not activated.'},
            headers={'Cache-Control': 'no-store'})
    raw = settings.explanation_store_database_url.get_secret_value()
    if not raw:
        raise HTTPException(503, detail={'code': 'EXPLANATION_STORE_TARGET_UNVERIFIED'},
            headers={'Cache-Control': 'no-store'})
    url = make_url(raw)
    if (url.drivername != 'postgresql+psycopg2'
            or url.host not in ('127.0.0.1', 'localhost')
            or url.port != settings.explanation_store_expected_port
            or url.database != settings.explanation_store_expected_database):
        raise HTTPException(503, detail={'code': 'EXPLANATION_STORE_TARGET_UNVERIFIED'},
            headers={'Cache-Control': 'no-store'})
    from sitewise.api.v1.customer_questionnaire import get_ee01_service
    from sitewise.project1.explanation_store import PostgresExplanationStore
    from sitewise.services.explanation_read_service import ExplanationReadService
    store = PostgresExplanationStore(
        _explanation_store_engine(raw), actor_id=str(user.user_id),
        role='p1ai_runtime', allowed_databases=frozenset(
            {settings.explanation_store_expected_database}),
        allowed_port=settings.explanation_store_expected_port)
    return ExplanationReadService(get_ee01_service(), store)


ReadService = Annotated[object, Depends(get_explanation_read_service)]


def get_explanation_binding_service():
    """Server-resolved campaign/snapshot chain; never trusts client IDs."""
    if not settings.ee01_explanation_enabled:
        raise HTTPException(503, detail={'code': 'EXPLANATION_MODULE_HOLD'},
                            headers={'Cache-Control': 'no-store'})
    from sitewise.api.v1.customer_questionnaire import get_ee01_service
    return get_ee01_service()


BindingService = Annotated[object, Depends(get_explanation_binding_service)]


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


@router.get('/assessments/{assessment_id}/explanations/binding')
def explanation_binding(assessment_id: UUID, user: Owner,
                        service: BindingService, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    try:
        return service.explanation_binding(user.user_id, assessment_id)
    except CqRefused as exc:
        raise HTTPException(exc.status, detail={'code': exc.code,
            'message': 'The explanation source binding could not be verified.'},
            headers={'Cache-Control': 'no-store'}) from exc


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
    except WorkflowHeld as exc:
        # A governed validation refusal is a held result, never a partial report.
        raise HTTPException(503, detail={'code': str(exc),
            'message': 'The explanation candidate failed governed validation.'},
            headers={'Cache-Control': 'no-store'}) from exc
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(503, detail={'code': 'EXPLANATION_CONTEXT_UNAVAILABLE',
            'message': 'The versioned EE-01 explanation context is unavailable.'},
            headers={'Cache-Control': 'no-store'}) from exc


@router.get('/assessments/{assessment_id}/campaigns/{campaign_id}/'
            'measurements/{snapshot_id}/explanations/{question_id}')
def read_explanation(assessment_id: UUID, campaign_id: UUID, snapshot_id: UUID,
                     question_id: str, user: Owner, service: ReadService,
                     response: Response, context_hash: str | None = None,
                     official: bool = False):
    response.headers['Cache-Control'] = 'no-store'
    if not 1 <= len(question_id) <= 16:
        raise HTTPException(422, detail={'code': 'EXPLANATION_QUESTION_ID_INVALID'},
                            headers={'Cache-Control': 'no-store'})
    if context_hash is not None and not re.fullmatch(r'[0-9a-f]{64}', context_hash):
        raise HTTPException(422, detail={'code': 'EXPLANATION_CONTEXT_HASH_INVALID'},
                            headers={'Cache-Control': 'no-store'})
    try:
        return service.read(user.user_id, assessment_id, campaign_id, snapshot_id,
                            question_id, expected_context_hash=context_hash,
                            official=official)
    except CqRefused as exc:
        raise HTTPException(exc.status, detail={'code': exc.code,
            'message': 'The explanation result could not be authorized.'},
            headers={'Cache-Control': 'no-store'}) from exc
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(503, detail={'code': 'EXPLANATION_READBACK_UNAVAILABLE',
            'message': 'The versioned explanation readback is unavailable.'},
            headers={'Cache-Control': 'no-store'}) from exc
