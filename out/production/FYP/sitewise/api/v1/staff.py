"""Staff administration + staff-only endpoints (Agent & Admin portal).

All routes here require a verified Supabase session, an ACTIVE account, a
staff role (``agent`` / ``admin``) and completed MFA (the verified ``aal2``
claim on the signed token). Password-only sessions receive a structured 403
(``code: "staff_mfa_required"``) so the frontend can route to the MFA
enrollment / challenge screens.

Administrator operations (create/suspend agents, invitations, listing
assignment, MFA recovery, audit review) additionally require the ``admin``
role AND ``aal2`` - enforced by the backend, never by UI navigation.

Identity writes go to the authoritative ``public.users`` row in the Supabase
identity database through the service-role adapter; the local ``sitesense``
``users`` row is the enforcement mirror the auth dependencies read on every
request. Every privileged operation is recorded in ``role_change_audit``.
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, EmailStr, Field
from sqlmodel import Session

from sitewise.core.supabase_admin import SupabaseAdminService
from sitewise.db.models.user import User
from sitewise.db.session import get_db
from sitewise.dependencies import AdminMfaUser, AgentMfaUser
from sitewise.domain import rbac
from sitewise.services.user_service import UserService

router = APIRouter()


# ---------------------------------------------------------------------------
# Request models
# ---------------------------------------------------------------------------


class CreateAgentRequest(BaseModel):
    """Step 1 of the confirmed workflow: the administrator supplies identity
    information only - never a password (the agent sets their own via the
    Supabase invite email)."""

    full_name: str = Field(min_length=1, max_length=120)
    email: EmailStr
    phone_number: str | None = Field(default=None, max_length=20)
    company_name: str | None = Field(default=None, max_length=120)
    # Explicit opt-in for emails that already belong to a Supabase identity.
    # Matching emails never upgrade roles automatically.
    allow_existing: bool = False


class UpdateAgentStatusRequest(BaseModel):
    account_status: str

    def validated(self) -> str:
        if not rbac.is_valid_status(self.account_status):
            raise HTTPException(status_code=422, detail="Unknown account status value.")
        return self.account_status


class MfaRecoveryRequest(BaseModel):
    reason: str = Field(min_length=3, max_length=500)


class AssignListingRequest(BaseModel):
    agent_user_id: uuid.UUID


class VerificationFindingRequest(BaseModel):
    property_authenticity_status: str = Field(min_length=1, max_length=40)
    commercial_classification_status: str = Field(min_length=1, max_length=40)
    verification_reason: str = Field(min_length=3, max_length=2000)
    evidence_url: str | None = Field(default=None, max_length=500)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _admin_service() -> SupabaseAdminService:
    return SupabaseAdminService()


def _mirror_payload(user: User) -> dict:
    return {
        "user_id": str(user.user_id),
        "email": user.email,
        "full_name": user.full_name,
        "phone_number": user.phone_number,
        "role": user.role,
        "account_status": user.account_status,
        "email_verified": user.email_verified,
    }


# ---------------------------------------------------------------------------
# Step 1-3 of the confirmed workflow: administrator creates the agent account
# and Supabase emails the native password-setup (invite) link.
# ---------------------------------------------------------------------------


@router.post("/agents", status_code=201)
def create_agent(
    payload: CreateAgentRequest,
    admin: AdminMfaUser,
    session: Session = Depends(get_db),
) -> dict:
    """Provision an agent account.

    * New email  -> Supabase ``invite_user_by_email`` creates the identity and
      sends the native password-setup email (no custom token, no plaintext
      password); identity row + mirror provisioned as ``agent`` / ``pending``;
      invitation tracked.
    * Known email -> 409 unless ``allow_existing`` is set; the explicit
      authorized workflow then grants the role WITHOUT re-inviting, and the
      decision is audited.
    """
    service = _admin_service()
    email = payload.email.lower()
    existing = service.find_auth_user_by_email(email)

    invited = False
    if existing is not None:
        if not payload.allow_existing:
            raise HTTPException(
                status_code=409,
                detail=(
                    "This email already belongs to an existing Supabase account. "
                    "Repeat the request with allow_existing=true to explicitly "
                    "grant staff access to that account."
                ),
            )
        auth_user_id = str(existing["id"])
    else:
        invited_user = service.invite_agent(
            email=email,
            full_name=payload.full_name,
            phone_number=payload.phone_number,
        )
        auth_user_id = str(invited_user["id"])
        invited = True

    # Authoritative identity row (role is decided here, never by the client).
    service.upsert_identity_profile(
        user_id=auth_user_id,
        email=email,
        full_name=payload.full_name,
        phone_number=payload.phone_number,
        role=rbac.ROLE_AGENT,
        account_status=rbac.STATUS_PENDING,
    )

    # Enforcement mirror in the application database.
    mirror = UserService(session).ensure_staff_profile(
        user_id=uuid.UUID(auth_user_id),
        email=email,
        full_name=payload.full_name,
        phone_number=payload.phone_number,
        role=rbac.ROLE_AGENT,
        account_status=rbac.STATUS_PENDING,
    )

    # Agent profile in the existing public.agent table (links auth identity
    # to listing assignments via agent.user_id).
    company_id = service.resolve_company(payload.company_name)
    agent_profile = service.create_agent_profile(
        user_id=auth_user_id,
        agent_name=payload.full_name,
        company_id=company_id,
    )

    # Onboarding tracking + audit.
    invitation = None
    if invited:
        invitation = service.insert_invitation(
            invited_user_id=auth_user_id,
            invited_email=email,
            invited_by_user_id=admin.user_id,
            status="sent",
        )
    service.insert_role_audit(
        affected_user_id=auth_user_id,
        affected_email=email,
        performed_by_user_id=admin.user_id,
        performed_by_email=admin.email,
        action="staff.invited" if invited else "staff.role_granted",
        previous_role=None if invited else (payload.allow_existing and existing.get("role")),
        new_role=rbac.ROLE_AGENT,
        new_status=rbac.STATUS_PENDING,
        details={
            "agent_id": agent_profile.get("agent_id"),
            "company_id": company_id,
            "invitation_id": (invitation or {}).get("invitation_id"),
        },
    )

    return {
        "agent_user_id": auth_user_id,
        "email": email,
        "role": rbac.ROLE_AGENT,
        "account_status": rbac.STATUS_PENDING,
        "invited": invited,
        "invitation": invitation,
        "agent_profile": agent_profile,
        "mirror": _mirror_payload(mirror),
    }


@router.get("/agents")
def list_agents(
    admin: AdminMfaUser,
    session: Session = Depends(get_db),
) -> list[dict]:
    """All agent accounts with their account status and agent profile."""
    service = _admin_service()
    agents = service.list_agent_profiles()
    by_user: dict[str, dict] = {}
    for agent in agents:
        uid = agent.get("user_id")
        if uid:
            by_user[str(uid)] = agent
    profiles = UserService(session).list_users(limit=500)
    result = []
    for profile in profiles:
        if not rbac.has_role(profile.role, (rbac.ROLE_AGENT,)):
            continue
        uid = str(profile.user_id)
        result.append(
            {
                **_mirror_payload(profile),
                "agent_profile": by_user.get(uid),
            }
        )
    return result


# ---------------------------------------------------------------------------
# Suspension / reactivation (Step: assign and suspend agent permissions)
# ---------------------------------------------------------------------------


_STATUS_ACTIONS = {
    (rbac.STATUS_PENDING, rbac.STATUS_ACTIVE): "staff.activated",
    (rbac.STATUS_ACTIVE, rbac.STATUS_SUSPENDED): "staff.suspended",
    (rbac.STATUS_SUSPENDED, rbac.STATUS_ACTIVE): "staff.reactivated",
    (rbac.STATUS_PENDING, rbac.STATUS_SUSPENDED): "staff.suspended",
}


@router.patch("/agents/{user_id}/status")
def update_agent_status(
    user_id: uuid.UUID,
    payload: UpdateAgentStatusRequest,
    admin: AdminMfaUser,
    session: Session = Depends(get_db),
) -> dict:
    new_status = payload.validated()
    if new_status not in (rbac.STATUS_ACTIVE, rbac.STATUS_SUSPENDED):
        raise HTTPException(
            status_code=422,
            detail="Staff account status may only be set to active or suspended.",
        )
    service = _admin_service()
    user_service = UserService(session)
    target = user_service.get_user(user_id)
    if target is None:
        raise HTTPException(status_code=404, detail="User not found.")
    if not rbac.is_staff(target.role):
        raise HTTPException(status_code=422, detail="Target account is not a staff account.")
    if target.account_status == new_status:
        raise HTTPException(status_code=409, detail="Account is already in that status.")

    previous = target.account_status
    # Authoritative identity row first, then the enforcement mirror.
    service.update_identity_profile(user_id, {"account_status": new_status})
    updated = user_service.update_user(user_id, {"account_status": new_status})
    if updated is None:  # pragma: no cover - existence checked above
        raise HTTPException(status_code=404, detail="User not found.")

    service.insert_role_audit(
        affected_user_id=user_id,
        affected_email=updated.email,
        performed_by_user_id=admin.user_id,
        performed_by_email=admin.email,
        action=_STATUS_ACTIONS.get((previous, new_status), "staff.status_changed"),
        previous_status=previous,
        new_status=new_status,
    )
    return _mirror_payload(updated)


# ---------------------------------------------------------------------------
# MFA recovery (administrator-supervised, documented Supabase method)
# ---------------------------------------------------------------------------


@router.post("/agents/{user_id}/mfa-recovery")
def mfa_recovery(
    user_id: uuid.UUID,
    payload: MfaRecoveryRequest,
    admin: AdminMfaUser,
) -> dict:
    """Delete the staff member's TOTP factors so they can re-enroll.

    Uses Supabase's documented admin factor-removal endpoint (the same one
    supabase-js wraps). No factor secret or recovery code is exposed; the
    agent re-enrolls through the standard enrollment screen on next sign-in.
    """
    service = _admin_service()
    factors = service.admin_list_factors(str(user_id))
    removed = []
    for factor in factors:
        factor_id = factor.get("id") or factor.get("factor_id")
        if factor.get("status") == "verified" and factor.get("factor_type", factor.get("type")) == "totp":
            service.admin_delete_factor(str(user_id), str(factor_id))
            removed.append(str(factor_id))
    service.insert_role_audit(
        affected_user_id=user_id,
        performed_by_user_id=admin.user_id,
        performed_by_email=admin.email,
        action="staff.mfa_factor_reset",
        details={"removed_factors": removed, "reason": payload.reason},
    )
    return {"removed_factors": removed, "re_enrollment_required": True}


# ---------------------------------------------------------------------------
# Invitation + audit review
# ---------------------------------------------------------------------------


@router.get("/invitations")
def list_invitations(admin: AdminMfaUser) -> list[dict]:
    return _admin_service().list_invitations()


@router.get("/audit")
def list_audit(
    admin: AdminMfaUser,
    affected_user_id: uuid.UUID | None = Query(default=None),
) -> list[dict]:
    return _admin_service().list_role_audit(affected_user_id)


# ---------------------------------------------------------------------------
# Staff self-service: assigned listings + verification findings
# ---------------------------------------------------------------------------


def _agent_profile_or_empty(service: SupabaseAdminService, user_id: uuid.UUID) -> dict | None:
    return service.get_agent_profile(user_id)


@router.get("/me/listings")
def my_assigned_listings(agent: AgentMfaUser) -> dict:
    """Listings assigned to the authenticated agent (valid empty state when
    there is no agent profile or no assignment - never unrelated listings)."""
    service = _admin_service()
    profile = _agent_profile_or_empty(service, agent.user_id)
    if profile is None:
        return {"agent": None, "listings": []}
    listings = service.list_assigned_listings(int(profile["agent_id"]))
    return {"agent": profile, "listings": listings}


def _require_listing_access(
    service: SupabaseAdminService,
    user: AgentMfaUser,
    listing_id: int,
) -> tuple[dict, dict | None]:
    listing = service.get_listing(listing_id)
    if listing is None:
        raise HTTPException(status_code=404, detail="Listing not found.")
    if rbac.can_administer_users(user.role):
        return listing, None  # administrators may act on any listing
    profile = _agent_profile_or_empty(service, user.user_id)
    if profile is None or listing.get("agent_id") != profile.get("agent_id"):
        # Scope enforcement: an agent cannot reach another agent's listing by
        # changing a request parameter.
        raise HTTPException(status_code=403, detail="This listing is not assigned to you.")
    return listing, profile


@router.post("/listings/{listing_id}/verifications", status_code=201)
def submit_verification(
    listing_id: int,
    payload: VerificationFindingRequest,
    user: AgentMfaUser,
) -> dict:
    """Record a listing-verification finding on an ASSIGNED listing.

    Keeps the existing ``listing_verification`` mechanism (review findings,
    change requests, outcomes); final approval decisions stay with the
    administrator through the listing review workflow.
    """
    service = _admin_service()
    _require_listing_access(service, user, listing_id)
    record = service.insert_listing_verification(
        listing_id=listing_id,
        verified_by_user_id=user.user_id,
        property_authenticity_status=payload.property_authenticity_status,
        commercial_classification_status=payload.commercial_classification_status,
        verification_reason=payload.verification_reason,
        evidence_url=payload.evidence_url,
    )
    return record


@router.get("/listings/{listing_id}/verifications")
def listing_verifications(
    listing_id: int,
    user: AgentMfaUser,
) -> list[dict]:
    service = _admin_service()
    _require_listing_access(service, user, listing_id)
    return service.list_listing_verifications(listing_id)


@router.post("/listings/{listing_id}/assign")
def assign_listing(
    listing_id: int,
    payload: AssignListingRequest,
    admin: AdminMfaUser,
) -> dict:
    """Assign (or reassign) a listing to an agent profile."""
    service = _admin_service()
    profile = _agent_profile_or_empty(service, payload.agent_user_id)
    if profile is None:
        raise HTTPException(status_code=404, detail="Agent profile not found.")
    updated = service.assign_listing(listing_id, int(profile["agent_id"]))
    service.insert_role_audit(
        affected_user_id=payload.agent_user_id,
        performed_by_user_id=admin.user_id,
        performed_by_email=admin.email,
        action="listing.assigned",
        details={"listing_id": listing_id, "agent_id": profile["agent_id"]},
    )
    return updated
