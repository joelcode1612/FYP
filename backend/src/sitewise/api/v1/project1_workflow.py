"""Authenticated candidate review surface. No model or approval HTTP endpoint."""
from typing import Annotated
from functools import lru_cache
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import text, create_engine
from sqlalchemy.engine import make_url
from sqlalchemy.exc import SQLAlchemyError
from sqlmodel import Session

from sitewise.core.config import settings
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, require_entrepreneur, require_admin_mfa
from sitewise.project1.bdj import BDJEngine, load_rules
from sitewise.project1.contracts import WorkflowHeld, no_authority
from sitewise.project1.projection import M2SourceProjection
from sitewise.repositories.m2_repository import SqlModelM2Repository


def configuration_gate(session: Annotated[Session, Depends(get_db)]):
    # Before auth opens/syncs a profile. The current Final_Location_Analysis
    # configuration cannot be repurposed into application authority by a flag.
    try:
        url = make_url(settings.database_url)
        valid = (settings.project1_workflow_enabled and url.database == 'Dss' and
                 url.get_backend_name() == 'postgresql' and url.username != 'postgres')
    except (ValueError, SQLAlchemyError):
        valid = False
    if not valid:
        raise HTTPException(503, detail={'code': 'WORKFLOW_CONFIGURATION_REQUIRED',
            'message': 'Business review is waiting for its required setup.'})
    try:
        identity = session.execute(text('SELECT current_database(), rolsuper, rolbypassrls '
            'FROM pg_roles WHERE rolname=current_user')).one()
        if identity[0] != 'Dss' or identity[1] or identity[2]:
            raise HTTPException(503, detail={'code': 'SOURCE_PRINCIPAL_REVIEW_REQUIRED'})
    except SQLAlchemyError:
        raise HTTPException(503, detail={'code': 'SOURCE_STORAGE_UNAVAILABLE'}) from None
    finally:
        session.rollback()


router = APIRouter(dependencies=[Depends(configuration_gate)])
Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]
Admin = Annotated[AuthenticatedUser, Depends(require_admin_mfa)]
Database = Annotated[Session, Depends(get_db)]


def source(session, user, assessment_id, revision):
    try:
        role = session.execute(text('SELECT current_database(), rolsuper, rolbypassrls '
            'FROM pg_roles WHERE rolname=current_user')).one()
        if role[0] != 'Dss' or role[1] or role[2]:
            raise HTTPException(503, detail={'code': 'SOURCE_PRINCIPAL_REVIEW_REQUIRED',
                'message': 'Business review is waiting for its required setup.'})
        # Explicit owner SQL checks remain necessary even if existing RLS grants deny.
        return M2SourceProjection(SqlModelM2Repository(session)).read(
            assessment_id, user.user_id, revision)
    except SQLAlchemyError:
        session.rollback()
        raise HTTPException(503, detail={'code': 'SOURCE_STORAGE_UNAVAILABLE',
            'message': 'Your business details could not be loaded for review.'}) from None


@router.get('/assessments/{assessment_id}/source')
def read_source(assessment_id: UUID, expected_revision: Annotated[int, Query(ge=0)],
                user: Owner, session: Database, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    return source(session, user, assessment_id, expected_revision)


class ReviewRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    expected_revision: int = Field(ge=0)


@router.get('/setup')
def setup_status(user: Owner, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    return {'outcome': 'held', 'message':
            'Your questionnaire preview needs a saved M2 record before business review.',
            'workspace_m2_binding_available': False, **no_authority()}


@router.post('/assessments/{assessment_id}/business-understanding')
def business_understanding(assessment_id: UUID, payload: ReviewRequest,
                           user: Owner, session: Database, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    packet = source(session, user, assessment_id, payload.expected_revision)
    try:
        rules = load_rules(settings.project1_rules_version, settings.project1_rules_sha256,
                           settings.project1_rules_adoption_receipt)
    except WorkflowHeld:
        rules = None
    # Deliberately no cloud runner here until durable storage/disclosure adapters
    # and the shared status register have an adopted integration contract.
    result = BDJEngine(rules).review(packet, recheck_current=lambda:
        source(session, user, assessment_id, payload.expected_revision)['source_fingerprint'])
    result['message'] = {
        'held': 'Your business details are available. The consistency review is waiting for its required setup.',
        'reviewed': 'Your details have been checked. Please review any suggested clarifications.',
        'rejected': 'The suggested review could not be validated. Your answers are unchanged.',
        'stale': 'Your business details changed. Review the latest version first.',
    }[result['outcome']]
    return result


@router.get('/technical-audit')
def technical_audit(user: Admin, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    # Metadata only; no key presence, credentials, provider bodies or raw M2 text.
    return {'status_contract': 'UNRECONCILED_PROPOSAL',
            'source_contract': 'project1-m2-projection/1-candidate',
            'cloud_http_execution': False, 'automatic_migrations': False,
            'rules_configured': bool(settings.project1_rules_version),
            'unresolved': ['shared_status_adoption', 'BCB_live_authority_adapters',
                           'approved_bank_register', 'provider_disclosure',
                           'restricted_database_grants'], **no_authority()}


@lru_cache(maxsize=1)
def audit_engine(secret):
    return create_engine(secret, hide_parameters=True, pool_pre_ping=True)


@router.get('/technical-audit/runs/{run_id}')
def audit_run(run_id: UUID, user: Admin, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    # Separate read-only metadata principal. The model/runtime principal is not
    # reused for global staff audit and has no endpoint for issuing approvals.
    secret = settings.project1_audit_database_url.get_secret_value()
    try:
        url = make_url(secret)
        app_url = make_url(settings.database_url)
        if (url.get_backend_name() != 'postgresql' or url.username != 'p1ai_audit' or
                (url.host,url.port,url.database) != (app_url.host,app_url.port,app_url.database)):
            raise ValueError
        with Session(audit_engine(secret)) as session:
            identity = session.execute(text('SELECT current_user,rolsuper,rolbypassrls '
                'FROM pg_roles WHERE rolname=current_user')).one()
            if tuple(identity) != ('p1ai_audit',False,False):
                raise ValueError
            rows = session.execute(text('SELECT a.attempt_no,a.stage,a.prompt_version,'
                'a.prompt_hash,a.request_hash,a.reserved_at,r.outcome,r.output_digest,r.created_at '
                'FROM project1_ai.attempts a LEFT JOIN project1_ai.attempt_receipts r '
                'ON r.run_id=a.run_id AND r.attempt_no=a.attempt_no '
                'WHERE a.run_id=:id ORDER BY a.attempt_no'), {'id':run_id}).mappings().all()
            return {'run_id':run_id, 'attempts':[dict(row) for row in rows],
                    'missing_receipt_means':'unknown_outcome_do_not_redispatch', **no_authority()}
    except (ValueError, SQLAlchemyError):
        raise HTTPException(503,detail={'code':'AUDIT_STORAGE_UNAVAILABLE'}) from None
