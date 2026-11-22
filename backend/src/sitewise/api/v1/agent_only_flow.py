"""Owner requests -> Agent accepts -> site inspection -> Agent submits for Admin.

Built on existing fyp.rental_properties + fyp.agent_listing_assignment.
Never trusts client-supplied account roles, owner ids or inspection status.
The DB migration in sql/01_agent_only_360_workflow.sql is required.
"""
from __future__ import annotations

import json
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.supabase_admin import SupabaseAdminService
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, require_agent_mfa, require_property_owner
from sitewise.domain import rbac
from sitewise.services.agent_inspection_policy import agent_assignment, require_ready_for_admin, completed_agent_panorama
from sitewise.services.property_verification_service import PropertyVerificationService

router = APIRouter()
Db = Annotated[Session, Depends(get_db)]
Provider = Annotated[AuthenticatedUser, Depends(require_property_owner)]
Agent = Annotated[AuthenticatedUser, Depends(require_agent_mfa)]


class AgentRequest(BaseModel):
    agent_user_id: uuid.UUID


class AgentDecline(BaseModel):
    reason: str = Field(min_length=2, max_length=500)


class InspectionInput(BaseModel):
    floor_area_verified: bool = False
    condition_verified: bool = False
    parking_verified: bool = False
    accessibility_verified: bool = False
    observed_floor_area_sqft: float | None = Field(default=None, gt=0, le=10_000_000)
    condition_notes: str = Field(default="", max_length=2000)
    parking_notes: str = Field(default="", max_length=2000)
    accessibility_notes: str = Field(default="", max_length=2000)


def _owner_property(session: Session, property_id: int, user: AuthenticatedUser) -> dict:
    if rbac.canonical_role(user.role) != rbac.ROLE_OWNER:
        raise HTTPException(status_code=403, detail="Only Property Owners may request an Agent.")
    row = session.execute(text("""
        SELECT id, verification_status, is_published
          FROM fyp.rental_properties
         WHERE id=:pid AND owner_user_id=:uid
    """), {"pid": int(property_id), "uid": str(user.user_id)}).mappings().first()
    if row is None:
        raise HTTPException(status_code=404, detail="Owned property not found.")
    return dict(row)


def _agent_profile(session: Session, user_id: uuid.UUID) -> dict:
    # Require active role in authoritative local profile as well as the
    # Supabase agent profile. No direct client-supplied agent_id is accepted.
    local = session.execute(text("""
       SELECT user_id, full_name FROM public.users
        WHERE user_id=:uid AND role='agent' AND account_status='active'
    """), {"uid": str(user_id)}).mappings().first()
    if local is None:
        raise HTTPException(status_code=422, detail="Selected Agent is not an active Agent account.")
    try:
        profile = SupabaseAdminService().get_agent_profile(user_id)
    except Exception as exc:
        raise HTTPException(status_code=503, detail="Agent directory temporarily unavailable.") from exc
    if not profile or profile.get('agent_id') is None:
        raise HTTPException(status_code=422, detail="Selected Agent is not registered.")
    return {"agent_id": int(profile['agent_id']),
            "agent_user_id": str(user_id),
            "display_name": (profile.get('agent_name') or local['full_name'] or 'Property Agent')}


@router.get('/agents')
def available_agents(session: Db, user: Provider) -> dict:
    if rbac.canonical_role(user.role) != rbac.ROLE_OWNER:
        raise HTTPException(status_code=403, detail="Only owners may browse Agents for assignment.")
    try:
        profiles = SupabaseAdminService().list_agent_profiles()
    except Exception as exc:
        raise HTTPException(status_code=503, detail="Agent directory temporarily unavailable.") from exc
    result = []
    for profile in profiles:
        uid = profile.get('user_id')
        if not uid:
            continue
        row = session.execute(text("""
            SELECT full_name FROM public.users
             WHERE user_id=:uid AND role='agent' AND account_status='active'
        """), {"uid": str(uid)}).mappings().first()
        if row and profile.get('agent_id') is not None:
            result.append({'user_id': str(uid),
                           'name': profile.get('agent_name') or row['full_name'] or 'Property Agent'})
    return {'data': result}


@router.get('/properties/{property_id}/assignment')
def owner_assignment(property_id: int, session: Db, user: Provider) -> dict:
    _owner_property(session, property_id, user)
    row = session.execute(text("""
        SELECT agent_id, workflow_status, requested_at, responded_at, submitted_at,
               panorama_uploaded_at, inspection_updated_at, decline_reason
          FROM fyp.agent_listing_assignment WHERE listing_id=:pid
    """), {'pid': property_id}).mappings().first()
    if row is None:
        return {'data': None}
    data = dict(row)
    for key in ('requested_at','responded_at','submitted_at',
                'panorama_uploaded_at','inspection_updated_at'):
        if data.get(key) is not None:
            data[key] = data[key].isoformat()
    try:
        profile = SupabaseAdminService().get_agent_profile_by_id(int(data['agent_id']))
        data['agent_name'] = (profile or {}).get('agent_name')
    except Exception:
        data['agent_name'] = None
    return {'data': data}


@router.post('/properties/{property_id}/request-agent')
def request_agent(property_id: int, payload: AgentRequest, session: Db, user: Provider) -> dict:
    prop = _owner_property(session, property_id, user)
    if prop['is_published'] or prop['verification_status'] not in ('draft','rejected'):
        raise HTTPException(status_code=409, detail="This property cannot be reassigned while in review or published.")
    agent = _agent_profile(session, payload.agent_user_id)
    current = session.execute(text("""
        SELECT workflow_status FROM fyp.agent_listing_assignment
         WHERE listing_id=:pid FOR UPDATE
    """), {'pid': property_id}).scalar()
    if current in ('requested','accepted','submitted'):
        raise HTTPException(status_code=409, detail="A live Agent request already exists for this property.")
    # Existing assignment row is updated in place; never invent another listing.
    session.execute(text("""
        INSERT INTO fyp.agent_listing_assignment
          (listing_id,agent_id,assigned_by_user_id,created_at,updated_at,
           workflow_status,requested_at,responded_at,inspection_data,
           inspection_updated_at,panorama_tour_id,panorama_uploaded_at,
           submitted_at,decline_reason)
        VALUES (:pid,:aid,:uid,now(),now(),'requested',now(),NULL,'{}'::jsonb,
                NULL,NULL,NULL,NULL,NULL)
        ON CONFLICT (listing_id) DO UPDATE SET
          agent_id=excluded.agent_id, assigned_by_user_id=excluded.assigned_by_user_id,
          workflow_status='requested',requested_at=now(),responded_at=NULL,
          inspection_data='{}'::jsonb,inspection_updated_at=NULL,
          panorama_tour_id=NULL,panorama_uploaded_at=NULL,submitted_at=NULL,
          decline_reason=NULL,updated_at=now()
    """), {'pid':property_id,'aid':agent['agent_id'],'uid':str(user.user_id)})
    session.commit()
    return {'data': {'property_id': property_id, 'assignment_status':'requested',
                     'agent_name': agent['display_name']}}


def _respond(property_id: int, session: Session, user: AuthenticatedUser,
             *, accept: bool, reason: str | None = None) -> dict:
    row = agent_assignment(session, property_id, user)
    if row['workflow_status'] != 'requested':
        raise HTTPException(status_code=409, detail="Only new or legacy Agent requests can be answered.")
    status = 'accepted' if accept else 'declined'
    session.execute(text("""
        UPDATE fyp.agent_listing_assignment
           SET workflow_status=:status, responded_at=now(), updated_at=now(),
               decline_reason=:reason
         WHERE listing_id=:pid AND agent_id=:aid
           AND workflow_status = 'requested'
    """), {'status': status, 'reason': reason, 'pid': property_id, 'aid':row['agent_id']})
    session.commit()
    return {'data': {'property_id': property_id, 'assignment_status':status}}


@router.post('/properties/{property_id}/accept')
def accept_request(property_id: int, session: Db, agent: Agent) -> dict:
    return _respond(property_id, session, agent, accept=True)


@router.post('/properties/{property_id}/decline')
def decline_request(property_id: int, payload: AgentDecline, session: Db, agent: Agent) -> dict:
    return _respond(property_id, session, agent, accept=False, reason=payload.reason)


@router.get('/properties/{property_id}/inspection')
def inspection_status(property_id: int, session: Db, agent: Agent) -> dict:
    row = agent_assignment(session, property_id, agent)
    return {'data': {
      'assignment_status': row['workflow_status'],
      'checklist': row['inspection_data'] or {},
      'panorama_uploaded': bool(completed_agent_panorama(session, property_id, agent)),
      'can_capture': row['workflow_status'] in ('accepted','needs_correction')
                     and not row['is_published'] and row['verification_status'] not in ('pending','approved','under_review'),
    }}


@router.patch('/properties/{property_id}/inspection')
def save_inspection(property_id: int, payload: InspectionInput, session: Db, agent: Agent) -> dict:
    row = agent_assignment(session, property_id, agent, writable=True)
    evidence = payload.model_dump()
    result = session.execute(text("""
        UPDATE fyp.agent_listing_assignment
           SET inspection_data=CAST(:data AS jsonb),inspection_updated_at=now(),updated_at=now()
         WHERE listing_id=:pid AND agent_id=:aid
    """), {'pid':property_id,'aid':row['agent_id'],'data':json.dumps(evidence)})
    if result.rowcount != 1:
        raise HTTPException(status_code=409, detail="Assignment changed during inspection; refresh.")
    session.commit()
    return {'data': {'checklist':evidence,'saved':True}}


@router.post('/properties/{property_id}/submit')
def submit_verified_property(property_id: int, session: Db, agent: Agent) -> dict:
    # Both checks are server-side. A crafted or outdated Flutter request cannot
    # submit without the assigned Agent's accepted request, checklist, and real
    # completed panorama from the upload endpoint.
    require_ready_for_admin(session, property_id, agent)
    from sitewise.api.v1.property_verification import _guard_enrichment_before_submit
    _guard_enrichment_before_submit(session, property_id, acknowledged=False)
    result = PropertyVerificationService(session).submit(
        property_id, agent.user_id, scope='full', role=agent.role
    )
    return {'data': result, 'stage': 'pending_admin_review'}
