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
from sitewise.repositories.fyp_property_repository import FypPropertyRepository
from sitewise.services.agent_inspection_policy import (
    REQUIRED_INSPECTION,
    agent_assignment,
    require_ready_for_admin,
    completed_agent_panorama,
)
from sitewise.services.property_verification_service import (
    PropertyVerificationService,
    listing_completeness_errors,
    rental_listing,
)

router = APIRouter()
Db = Annotated[Session, Depends(get_db)]
Provider = Annotated[AuthenticatedUser, Depends(require_property_owner)]
Agent = Annotated[AuthenticatedUser, Depends(require_agent_mfa)]


class AgentRequest(BaseModel):
    agent_user_id: uuid.UUID


class AgentDecline(BaseModel):
    reason: str = Field(min_length=2, max_length=500)


class AgentInspectionSubmission(BaseModel):
    panorama_id: uuid.UUID | None = None
    acknowledge_unavailable_population: bool = False


class InspectionInput(BaseModel):
    floor_area_verified: bool = False
    condition_verified: bool = False
    parking_verified: bool = False
    accessibility_verified: bool = False
    observed_floor_area_sqft: float | None = Field(default=None, gt=0, le=10_000_000)
    condition_notes: str = Field(default="", max_length=2000)
    parking_notes: str = Field(default="", max_length=2000)
    accessibility_notes: str = Field(default="", max_length=2000)


def _owner_property(
    session: Session, property_id: int, user: AuthenticatedUser, *, for_update: bool = False,
) -> dict:
    if rbac.canonical_role(user.role) != rbac.ROLE_OWNER:
        raise HTTPException(status_code=403, detail="Only Property Owners may request an Agent.")
    repo = FypPropertyRepository(session)
    row = repo.owner_listing(property_id)
    if row is None or str(row["owner_user_id"]) != str(user.user_id):
        raise HTTPException(status_code=404, detail="Owned property not found.")
    if for_update:
        row = repo.owner_listing(property_id, for_update=True)
        if row is None or str(row["owner_user_id"]) != str(user.user_id):
            raise HTTPException(status_code=404, detail="Owned property not found.")
    return row


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
    listing = _owner_property(session, property_id, user)
    missing = listing_completeness_errors(listing, require_availability=False)
    row = session.execute(text("""
        SELECT agent_id, workflow_status, requested_at, responded_at, submitted_at,
               panorama_uploaded_at, inspection_updated_at, decline_reason
          FROM fyp.agent_listing_assignment WHERE listing_id=:pid
    """), {'pid': property_id}).mappings().first()
    proof_status = session.execute(text("""
        SELECT status FROM fyp.verification_document
         WHERE property_id=:pid AND verification_type='ownership' AND document_type='ownership_proof'
         ORDER BY uploaded_at DESC LIMIT 1
    """), {'pid': property_id}).scalar()
    summary = {'missing_required_fields': missing, 'ownership_proof_status': proof_status}
    if row is None:
        return {'data': None, **summary}
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
    return {'data': data, **summary}


def _require_requestable_listing(prop: dict) -> None:
    if prop['is_published'] or prop['verification_status'] not in ('draft','rejected'):
        raise HTTPException(status_code=409, detail="This property cannot be reassigned while in review or published.")
    # The Agent's assignment is explicitly the opportunity to collect missing
    # information. The completeness gate remains mandatory at Admin submit.


@router.post('/properties/{property_id}/request-agent')
def request_agent(property_id: int, payload: AgentRequest, session: Db, user: Provider) -> dict:
    _require_requestable_listing(_owner_property(session, property_id, user))
    agent = _agent_profile(session, payload.agent_user_id)
    # Lock the listing before checking the assignment, matching the owner edit path.
    _require_requestable_listing(_owner_property(session, property_id, user, for_update=True))
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



# SITEWISE_AGENT_DETAILS_COMPLETION_V1
# Owner-supplied values are immutable in this completion route. Corrections of
# existing facts continue through the separate Agent proposal / Admin review.
class AgentMissingDetails(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=160)
    property_type: str | None = Field(default=None, max_length=60)
    address: str | None = Field(default=None, min_length=3, max_length=300)
    city: str | None = Field(default=None, min_length=2, max_length=80)
    state: str | None = Field(default=None, min_length=2, max_length=80)
    postcode: str | None = Field(default=None, pattern=r"^\d{5}$")
    rental_price: float | None = Field(default=None, gt=0, le=10_000_000)
    size_sqft: float | None = Field(default=None, gt=0, le=10_000_000)


_AGENT_MISSING_FIELDS = {
    'name': 'name',
    'property type': 'property_type',
    'address': 'address',
    'city': 'city',
    'state': 'state',
    'postcode': 'postcode',
    'rental price': 'rental_price',
    'a rental price greater than zero': 'rental_price',
    'size sqft': 'size_sqft',
    'a built-up area greater than zero': 'size_sqft',
}
_AGENT_ALLOWED_TYPES = {
    'Shoplot', 'Retail Space', 'Ground Floor Shop', 'Corner Shoplot',
    'Retail Unit', 'Kiosk', 'Commercial F&B Premise',
}


def _agent_missing_detail_view(session: Session, property_id: int, agent) -> dict:
    row = agent_assignment(session, property_id, agent)
    listing = rental_listing(session, property_id)
    if listing is None:
        raise HTTPException(status_code=404, detail='Property not found.')
    fields = {key: listing.get(key) for key in AgentMissingDetails.model_fields}
    return {'data': {
        'property_id': property_id,
        'fields': fields,
        'missing_required_fields': listing_completeness_errors(
            listing, require_availability=False),
        'editable': row['workflow_status'] in ('accepted', 'needs_correction')
                    and not row['is_published']
                    and row['verification_status'] in ('draft', 'rejected'),
    }}


@router.get('/properties/{property_id}/details')
def agent_missing_details(property_id: int, session: Db, agent: Agent) -> dict:
    # Authorized assignment lookup happens on every read, not in the client.
    return _agent_missing_detail_view(session, property_id, agent)


@router.patch('/properties/{property_id}/details')
def complete_agent_missing_details(
    property_id: int, payload: AgentMissingDetails, session: Db, agent: Agent,
) -> dict:
    # Lock canonical property before assignment (same lock order as owner edit).
    listing_row = session.execute(text('''
        SELECT id FROM fyp.rental_properties WHERE id=:pid FOR UPDATE
    '''), {'pid': property_id}).first()
    if listing_row is None:
        raise HTTPException(status_code=404, detail='Property not found.')
    assignment = agent_assignment(session, property_id, agent, writable=True)
    current = session.execute(text('''
        SELECT workflow_status FROM fyp.agent_listing_assignment
        WHERE listing_id=:pid AND agent_id=:aid FOR UPDATE
    '''), {'pid': property_id, 'aid': assignment['agent_id']}).scalar_one_or_none()
    if current not in ('accepted', 'needs_correction'):
        raise HTTPException(status_code=409, detail='Agent assignment is no longer editable.')
    listing = rental_listing(session, property_id)
    if listing is None:
        raise HTTPException(status_code=404, detail='Property not found.')
    missing_names = listing_completeness_errors(listing, require_availability=False)
    missing_keys = {_AGENT_MISSING_FIELDS.get(name) for name in missing_names}
    updates = payload.model_dump(exclude_unset=True)
    if not updates:
        raise HTTPException(status_code=422, detail='Provide at least one missing field.')
    for key, value in list(updates.items()):
        if key not in missing_keys:
            raise HTTPException(
                status_code=409,
                detail=f'{key} already has an owner-provided value. Use the change proposal workflow.',
            )
        if value is None or (isinstance(value, str) and not value.strip()):
            raise HTTPException(status_code=422, detail=f'{key} cannot be blank.')
        if isinstance(value, str):
            updates[key] = value.strip()
    if 'property_type' in updates and updates['property_type'] not in _AGENT_ALLOWED_TYPES:
        raise HTTPException(status_code=422, detail='Choose a supported property type.')

    # Fixed server allowlist, with bound values only. No lifecycle, owner, or
    # verification columns can ever be edited from this endpoint.
    expressions = [f'{key} = :{key}' for key in updates]
    arguments = {'pid': property_id, **updates}
    if 'rental_price' in updates or 'size_sqft' in updates:
        expressions.append('''psf = CASE
            WHEN COALESCE(:price, rental_price) > 0 AND
                 COALESCE(:area, size_sqft) > 0
            THEN ROUND(COALESCE(:price, rental_price)::numeric /
                       COALESCE(:area, size_sqft)::numeric, 2)
            ELSE psf END''')
        arguments['price'] = updates.get('rental_price')
        arguments['area'] = updates.get('size_sqft')
    session.execute(text(
        'UPDATE fyp.rental_properties SET ' + ', '.join(expressions) +
        ', updated_at=now() WHERE id=:pid'
    ), arguments)
    # A completed physical inspection must be re-confirmed when facts change.
    # Preserve the uploaded tour and its original photo assets.
    # Bind the JSON object: text() would read ':false' inside a JSON string
    # literal as a bind parameter and fail before reaching PostgreSQL.
    session.execute(text('''
        UPDATE fyp.agent_listing_assignment
           SET inspection_data = COALESCE(inspection_data, '{}'::jsonb) ||
                 CAST(:reset_checks AS jsonb),
               inspection_updated_at = NULL, updated_at=now()
         WHERE listing_id=:pid AND agent_id=:aid
    '''), {
        'pid': property_id,
        'aid': assignment['agent_id'],
        'reset_checks': json.dumps({key: False for key in REQUIRED_INSPECTION}),
    })
    # The audit explicitly identifies the Agent; it is never recorded as an
    # administrator decision and does not create a verification submission.
    session.execute(text('''
        INSERT INTO fyp.verification_audit
            (audit_id, property_id, verification_id, verification_type,
             previous_status, new_status, action, reason, created_at)
        VALUES (gen_random_uuid(), :pid, NULL, NULL, NULL, NULL,
                'agent_completed_property_details', :reason, now())
    '''), {'pid': property_id,
           'reason': f'Agent {agent.user_id} supplied previously missing fields: '
                     + ', '.join(sorted(updates))})
    session.commit()
    return _agent_missing_detail_view(session, property_id, agent)

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


# SITEWISE_READINESS_V1
# Read-only preview of the SAME requirements enforced by the final submit path.
# Never create/modify property, assignment, verification or panorama rows here.
def _agent_submission_readiness(
    session: Session, property_id: int, agent: AuthenticatedUser,
    assignment: dict, listing: dict, panorama_id: str | None,
) -> dict:
    inspection = assignment.get('inspection_data') or {}
    missing_checks = [
        key for key in REQUIRED_INSPECTION if inspection.get(key) is not True
    ]
    missing_fields = listing_completeness_errors(listing, require_availability=False)

    # Ownership proof is separate from inspection photos and the 360 tour.
    # Local document storage has to contain the file, not just a stale DB row.
    keys = session.execute(text("""
        SELECT storage_key FROM fyp.verification_document
         WHERE property_id=:pid AND verification_type='ownership'
           AND status='active' ORDER BY uploaded_at DESC
    """), {'pid': property_id}).scalars().all()
    from sitewise.services import verification_storage
    proof_available = False
    for key in keys:
        try:
            verification_storage.open_document(str(key))
            proof_available = True
            break
        except Exception:
            # Preserve evidence metadata; report missing/unreachable storage.
            continue

    enrichment = dict(session.execute(text("""
        SELECT category, status FROM fyp.property_enrichment_category
         WHERE property_id=:pid
    """), {'pid': property_id}).all())
    running = sorted(
        key for key, status in enrichment.items() if status == 'running'
    )
    population_ack = enrichment.get('population') in ('unavailable', 'failed', 'stale')
    blockers: list[str] = []
    if assignment.get('workflow_status') not in ('accepted', 'needs_correction'):
        blockers.append('Agent request must be accepted before submission.')
    if missing_fields:
        blockers.append('Complete property details: ' + ', '.join(missing_fields) + '.')
    if missing_checks:
        labels = {
            'floor_area_verified': 'floor area',
            'condition_verified': 'physical condition',
            'parking_verified': 'parking',
            'accessibility_verified': 'access / entrance',
        }
        blockers.append('Save inspection checks: ' + ', '.join(
            labels.get(key, key) for key in missing_checks
        ) + '.')
    if not proof_available:
        blockers.append(
            'Ownership proof is registered but its file is unavailable; '
            'ask the Owner to re-upload it.' if keys else
            'Owner must upload ownership proof before Admin submission.'
        )
    if not panorama_id:
        blockers.append(
            'Finish 360 capture and sync the panorama to SiteWise (server confirmed).'
        )
    if running:
        blockers.append('Wait for geospatial processing: ' + ', '.join(running) + '.')
    return {
        'ready': not blockers,
        'blockers': blockers,
        'missing_property_fields': missing_fields,
        'missing_inspection_checks': missing_checks,
        'ownership_proof_uploaded': proof_available,
        'ownership_proof_record_count': len(keys),
        'panorama_confirmed': bool(panorama_id),
        'enrichment_running': running,
        'population_acknowledgement_required': population_ack,
    }


@router.get('/properties/{property_id}/inspection')
def inspection_status(property_id: int, session: Db, agent: Agent) -> dict:
    row = agent_assignment(session, property_id, agent)
    listing = rental_listing(session, property_id)
    if listing is None:
        raise HTTPException(status_code=404, detail="Assigned property not found.")
    panorama_id = completed_agent_panorama(session, property_id, agent)
    population = session.execute(text(
        "SELECT status FROM fyp.property_enrichment_category "
        "WHERE property_id=:pid AND category='population'"
    ), {"pid": property_id}).scalar()
    readiness = _agent_submission_readiness(
        session, property_id, agent, row, listing, panorama_id
    )
    # Read real active ownership evidence; never synthesize a verification.
    ownership_proof = bool(session.execute(text("""
        SELECT EXISTS (
            SELECT 1 FROM fyp.verification_document
             WHERE property_id=:pid AND verification_type='ownership'
               AND status='active'
        )
    """), {'pid': property_id}).scalar())
    return {'data': {
      'ownership_proof_available': ownership_proof,
      'assignment_status': row['workflow_status'],
      'submission_readiness': readiness,
      'checklist': row['inspection_data'] or {},
      'missing_required_fields': listing_completeness_errors(listing, require_availability=False),
      'panorama_uploaded': panorama_id is not None,
      'panorama_id': panorama_id,
      'panorama_requires_recapture': False,
      'population_requires_acknowledgement': readiness['population_acknowledgement_required'],
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
def submit_verified_property(
    property_id: int, session: Db, agent: Agent, payload: AgentInspectionSubmission | None = None
) -> dict:
    payload = payload or AgentInspectionSubmission()
    # Preflight lists every actionable gap instead of failing only after capture.
    assignment = agent_assignment(session, property_id, agent)
    listing = rental_listing(session, property_id)
    if listing is None:
        raise HTTPException(status_code=404, detail='Assigned property not found.')
    panorama_id = completed_agent_panorama(
        session, property_id, agent,
        str(payload.panorama_id) if payload.panorama_id else None,
    )
    readiness = _agent_submission_readiness(
        session, property_id, agent, assignment, listing, panorama_id,
    )
    if not readiness['ready']:
        raise HTTPException(
            status_code=409,
            detail={'code': 'agent_submission_not_ready',
                    'blockers': readiness['blockers']},
        )
    evidence = require_ready_for_admin(
        session, property_id, agent, str(payload.panorama_id) if payload.panorama_id else None
    )
    from sitewise.api.v1.property_verification import _guard_enrichment_before_submit
    _guard_enrichment_before_submit(
        session, property_id, acknowledged=payload.acknowledge_unavailable_population
    )
    result = PropertyVerificationService(session).submit(
        property_id, agent.user_id, scope='full', role=agent.role,
        panorama_id=evidence['completed_panorama_id'],
    )
    return {'data': result, 'stage': 'pending_admin_review'}
