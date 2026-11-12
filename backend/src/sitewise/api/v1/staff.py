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

import logging
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.supabase_admin import SupabaseAdminService
from sitewise.db.models.user import User
from sitewise.db.session import get_db
from sitewise.dependencies import (
    AdminMfaUser,
    AgentMfaUser,
    CurrentUser,
    _staff_mfa_required,
)
from sitewise.domain import rbac
from sitewise.services.user_service import UserService
from sitewise.repositories.agent_assignment_repository import (
    AgentAssignmentRepository,
)
from sitewise.services.property_management_service import resolve_listings

router = APIRouter()

logger = logging.getLogger("sitewise.staff")


def _record_audit(service: SupabaseAdminService, **kwargs) -> bool:
    """Record a privileged action WITHOUT failing a mutation that already
    succeeded.

    Both the invitation and the suspension flow commit their real state
    change before the audit row is written (two different databases cannot
    share a transaction). If the audit write fails there, the truthful
    outcome is "change applied, not audited" — reporting it as a failure made
    administrators retry already-applied changes and hid what actually
    happened. The technical cause is logged server-side; the response carries
    ``audit_recorded: false`` so the UI can say exactly that.
    """
    try:
        service.insert_role_audit(**kwargs)
        return True
    except Exception:
        logger.exception(
            "role_change_audit write failed for action=%s", kwargs.get("action")
        )
        return False


# ---------------------------------------------------------------------------
# Request models
# ---------------------------------------------------------------------------


class CreateAgentRequest(BaseModel):
    """Final step of the confirmed workflow: the administrator supplies
    identity information only - never a password (the agent sets their own
    via the Supabase invite email).

    ``company_id`` is the preferred, unambiguous assignment produced by the
    four-step wizard. ``company_name`` remains accepted for older clients;
    when both are sent the explicit id wins.
    """

    full_name: str = Field(min_length=1, max_length=120)
    email: EmailStr
    phone_number: str | None = Field(default=None, max_length=20)
    company_id: int | None = Field(default=None, ge=1)
    company_name: str | None = Field(default=None, max_length=120)
    # Explicit opt-in for emails that already belong to a Supabase identity.
    # Matching emails never upgrade roles automatically.
    allow_existing: bool = False


class CreateCompanyRequest(BaseModel):
    """Registration of a row in the existing ``public.company`` table.

    Only ``company_name`` is writable: the live table has no ``company_type``
    column, and inventing one here would fail against the real schema.
    """

    company_name: str = Field(min_length=1, max_length=120)


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


# The two states protected by the ``staff_invitations_one_open_per_email``
# unique partial index. Mirrored here so an invitation is never issued twice
# for the same address, and so revoking one genuinely frees the address.
_OPEN_INVITATION_STATES = ("pending", "sent")


def _invitation_state(row: dict) -> str:
    return str(row.get("invitation_status") or row.get("status") or "").lower()


def _iso(value: object) -> str:
    """ISO-8601 for a datetime column, empty string when the mirror has none."""
    formatter = getattr(value, "isoformat", None)
    return formatter() if callable(formatter) else ""


def _latest_invitations(
    service: SupabaseAdminService, rows: list[dict] | None = None
) -> dict[str, dict]:
    """Newest invitation per email, keyed by the lower-cased address."""
    if rows is None:
        rows = service.list_invitations()
    ordered = sorted(rows, key=lambda row: str(row.get("created_at") or ""), reverse=True)
    latest: dict[str, dict] = {}
    for row in ordered:
        email = str(row.get("invited_email") or "").lower()
        if email and email not in latest:
            latest[email] = row
    return latest


def _company_index(
    service: SupabaseAdminService, rows: list[dict] | None = None
) -> dict[int, str]:
    """``company_id -> company_name`` for the existing company rows."""
    return {
        int(company["company_id"]): str(company.get("company_name") or "")
        for company in (rows if rows is not None else service.list_companies())
        if company.get("company_id") is not None
    }


def _agent_records(
    session: Session,
    service: SupabaseAdminService,
    *,
    agent_profiles: list[dict] | None = None,
    company_rows: list[dict] | None = None,
    invitation_rows: list[dict] | None = None,
) -> list[dict]:
    """The single source of rows shared by the roster and the summary tiles.

    Both endpoints must agree on what an "agent" is, so the count in a KPI can
    never drift from the directory underneath it. Company names and invitation
    states are joined server-side from the real tables, not derived in the
    browser.
    """
    by_user: dict[str, dict] = {}
    for agent in (agent_profiles if agent_profiles is not None else service.list_agent_profiles()):
        uid = agent.get("user_id")
        if uid:
            by_user[str(uid)] = agent
    companies = _company_index(service, company_rows)
    invitations = _latest_invitations(service, invitation_rows)
    records: list[dict] = []
    for profile in UserService(session).list_users(limit=500):
        if not rbac.has_role(profile.role, (rbac.ROLE_AGENT,)):
            continue
        uid = str(profile.user_id)
        agent_profile = by_user.get(uid)
        raw_company_id = (agent_profile or {}).get("company_id")
        company_id = None
        if raw_company_id is not None:
            try:
                company_id = int(raw_company_id)
            except (TypeError, ValueError):
                company_id = None
        invitation = invitations.get(str(profile.email or "").lower()) or {}
        records.append(
            {
                **_mirror_payload(profile),
                "created_at": _iso(profile.created_at),
                "agent_profile": agent_profile,
                "company_id": company_id,
                "company_name": companies.get(company_id, "") if company_id else "",
                "invitation_status": _invitation_state(invitation),
                "invitation_id": str(invitation.get("invitation_id") or ""),
            }
        )
    return records


def _resolve_assignment(
    service: SupabaseAdminService,
    payload: CreateAgentRequest,
) -> tuple[int | None, str]:
    """Resolve the wizard's company choice to a real ``public.company`` id.

    An explicit ``company_id`` is verified before anything is provisioned, so
    a stale selection fails with a readable 404 instead of silently creating
    an agent profile with a dangling foreign key. The legacy ``company_name``
    path keeps its existing create-if-missing behaviour for older clients.
    """
    if payload.company_id is not None:
        company = service.get_company(payload.company_id)
        if company is None:
            raise HTTPException(
                status_code=404,
                detail=(
                    "The selected company no longer exists. Refresh the "
                    "company directory and choose again."
                ),
            )
        return int(company["company_id"]), str(company.get("company_name") or "")
    return service.resolve_company(payload.company_name), (payload.company_name or "").strip()


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
    # Detect local UUID collisions BEFORE creating/inviting the Supabase user
    # or changing the authoritative Supabase role. No automatic email-based
    # identity merge or primary-key reassignment is permitted.
    local_profile = UserService(session).get_user_by_email(email)
    if local_profile is not None and (
        existing is None or str(local_profile.user_id) != str(existing["id"])
    ):
        raise HTTPException(
            status_code=409,
            detail=(
                "A different local identity already uses this email. "
                "Administrator identity reconciliation is required."
            ),
        )
    # Duplicate guards run BEFORE any privileged identity write. The database
    # already has a unique partial index over open invitations, but failing
    # here gives the administrator an actionable sentence instead of a
    # provider-level 422 from Supabase Auth.
    if local_profile is not None and rbac.has_role(local_profile.role, (rbac.ROLE_AGENT,)):
        raise HTTPException(
            status_code=409,
            detail=(
                "An agent account already exists for this email. Manage it "
                "from the agent directory instead of inviting it again."
            ),
        )
    if any(
        _invitation_state(row) in _OPEN_INVITATION_STATES
        for row in service.list_invitations(email)
    ):
        raise HTTPException(
            status_code=409,
            detail=(
                "An open invitation already exists for this email. Revoke it "
                "in the invitations table before issuing a new one."
            ),
        )

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
    company_id, company_name = _resolve_assignment(service, payload)
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
    audit_recorded = _record_audit(
        service,
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
        "invitation_status": _invitation_state(invitation or {}),
        "agent_profile": agent_profile,
        "company": {"company_id": company_id, "company_name": company_name},
        "mirror": _mirror_payload(mirror),
        "audit_recorded": audit_recorded,
    }


@router.get("/agents")
def list_agents(
    admin: AdminMfaUser,
    session: Session = Depends(get_db),
) -> list[dict]:
    """Agent accounts joined to their company and latest invitation state."""
    return _agent_records(session, _admin_service())


# ---------------------------------------------------------------------------
# Invitation acceptance -> automatic activation (trusted completion step).
#
# The invited agent lands on the authorized redirect after the Supabase
# invite email, sets a password and verifies a TOTP factor. Because the
# account is still ``pending``, the ordinary ``get_active_user`` chain would
# reject it (the circular pending-vs-MFA dependency), so this endpoint runs
# on ``CurrentUser`` - a verified session and a verified local profile -
# and re-proves every activation precondition SERVER-SIDE before flipping
# the authoritative status. The frontend flag never activates anything.
# ---------------------------------------------------------------------------


def _structured_error(status_code: int, code: str, message: str) -> HTTPException:
    """Structured error the web client branches on by ``detail.code``."""
    return HTTPException(status_code=status_code, detail={"code": code, "message": message})


def _parse_supabase_timestamp(value: object) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def _invitation_is_expired(row: dict) -> bool:
    expires = _parse_supabase_timestamp(row.get("expires_at"))
    return expires is not None and expires <= datetime.now(timezone.utc)


def _newest_invitation(service: SupabaseAdminService, email: str) -> dict | None:
    rows = service.list_invitations(email)
    if not rows:
        return None
    return sorted(
        rows, key=lambda row: str(row.get("created_at") or ""), reverse=True
    )[0]


def _has_verified_totp_factor(service: SupabaseAdminService, auth_user_id: str) -> bool:
    return any(
        factor.get("status") == "verified"
        and str(factor.get("factor_type") or factor.get("type") or "").lower() == "totp"
        for factor in service.admin_list_factors(auth_user_id)
    )


@router.post("/onboarding/complete")
def complete_onboarding(
    user: CurrentUser,
    session: Session = Depends(get_db),
) -> dict:
    """Trusted completion of the agent invitation lifecycle.

    Preconditions re-proven here on every call (never trusted from the
    client): the signed token's subject, an agent role, a signed ``aal2``
    claim backed by a verified TOTP factor on the identity, Supabase's own
    invitation-acceptance evidence (``email_confirmed_at``), and ownership
    plus validity of the invitation row.

    Transitions are idempotent and reconciling: the invitation row moves to
    ``accepted`` with ``accepted_at``, the authoritative ``public.users``
    row and the enforcement mirror both move to ``active``, and a single
    ``role_change_audit`` entry records the real transition. Re-calling the
    endpoint after a partial failure completes only the missing writes.
    """
    if not rbac.has_role(user.role, (rbac.ROLE_AGENT,)):
        raise _structured_error(
            403,
            "onboarding_forbidden",
            "Onboarding completion requires an invited agent account.",
        )
    if user.assurance_level != rbac.REQUIRED_STAFF_AAL:
        raise _staff_mfa_required()

    service = _admin_service()
    user_service = UserService(session)
    email = str(user.email or "").lower()

    # 1. Supabase-verified acceptance evidence: the authoritative proof that
    # the invited user actually accepted the invite (set a password through
    # the emailed link) is the confirmation timestamp on the auth identity -
    # never "the email was sent" or "the invite link was opened".
    auth_user = service.get_auth_user(str(user.user_id))
    accepted_at = None
    if auth_user:
        accepted_at = auth_user.get("email_confirmed_at") or auth_user.get("confirmed_at")
    if not accepted_at:
        raise _structured_error(
            409,
            "invitation_not_accepted",
            "The invitation has not been accepted yet: no confirmed email on "
            "the identity. Open the invite link and set your password first.",
        )

    # 2. A verified TOTP factor must exist on the identity - defense in
    # depth behind the signed aal2 claim on the session token.
    if not _has_verified_totp_factor(service, str(user.user_id)):
        raise _structured_error(
            403,
            "staff_mfa_required",
            "Complete multi-factor enrollment and verification before "
            "finishing onboarding.",
        )

    # 3. Invitation ownership + validity. A missing invitation row is legal
    # (the allow_existing workflow grants the role without an invite); an
    # invitation issued to a DIFFERENT identity never is.
    invitation = _newest_invitation(service, email)
    invitation_id = ""
    state = ""
    if invitation is not None:
        invitation_id = str(invitation.get("invitation_id") or "")
        state = _invitation_state(invitation)
        invited_for = invitation.get("invited_user_id")
        if invited_for and str(invited_for) != str(user.user_id):
            raise _structured_error(
                403,
                "invitation_ownership",
                "This invitation was issued to a different identity.",
            )
        if state == "revoked":
            raise _structured_error(
                410,
                "invitation_revoked",
                "This invitation was revoked. Ask an administrator to send "
                "a new one.",
            )
        if state == "expired" or (
            state in _OPEN_INVITATION_STATES and _invitation_is_expired(invitation)
        ):
            # Lifecycle reconciliation: persist the expired state so the
            # administrator's directory stops showing a dead invite as open.
            if state in _OPEN_INVITATION_STATES:
                service.update_invitation(
                    invitation_id, {"invitation_status": "expired"}
                )
            raise _structured_error(
                410,
                "invitation_expired",
                "This invitation has expired. Ask an administrator to send "
                "a new one.",
            )

    # 4. Activation - authoritative identity row first, then the enforcement
    # mirror, mirroring the ordering of every other status change. Skipped
    # entirely when the account is already active (idempotent retries).
    activated = False
    audit_recorded = True
    if user.account_status != rbac.STATUS_ACTIVE:
        if user.account_status == rbac.STATUS_SUSPENDED:
            raise _structured_error(
                403,
                "onboarding_suspended",
                "This account is suspended; activation is not possible.",
            )
        service.update_identity_profile(
            user.user_id, {"account_status": rbac.STATUS_ACTIVE}
        )
        updated = user_service.update_user(
            user.user_id, {"account_status": rbac.STATUS_ACTIVE}
        )
        if updated is None:  # pragma: no cover - profile read above
            raise HTTPException(status_code=404, detail="Local profile not found.")
        audit_recorded = _record_audit(
            service,
            affected_user_id=user.user_id,
            affected_email=user.email,
            performed_by_user_id=user.user_id,
            performed_by_email=user.email,
            action="staff.onboarding_completed",
            previous_status=user.account_status,
            new_status=rbac.STATUS_ACTIVE,
            details={
                "invitation_id": invitation_id or None,
                "email_confirmed_at": str(accepted_at),
            },
        )
        activated = True

    # 5. Invitation close (reconciliation): an open invitation is moved to
    # ``accepted`` with ``accepted_at`` - also on idempotent retries where
    # activation already happened, so a partial failure self-heals here.
    if invitation is not None and state in _OPEN_INVITATION_STATES:
        service.update_invitation(
            invitation_id,
            {
                "invitation_status": "accepted",
                "accepted_at": datetime.now(timezone.utc).isoformat(),
            },
        )
        state = "accepted"

    return {
        "account_status": rbac.STATUS_ACTIVE,
        "role": user.role,
        "invitation_id": invitation_id,
        "invitation_status": state,
        "email_confirmed_at": str(accepted_at),
        "activated": activated,
        "audit_recorded": audit_recorded,
    }


# ---------------------------------------------------------------------------
# Company directory + registration (existing public.company table)
# ---------------------------------------------------------------------------


@router.get("/companies")
def list_companies(admin: AdminMfaUser) -> list[dict]:
    """Existing companies for the invitation wizard's assignment step."""
    return _admin_service().list_companies()


@router.post("/companies", status_code=201)
def create_company(
    payload: CreateCompanyRequest,
    admin: AdminMfaUser,
) -> dict:
    """Register a company so its real ``company_id`` can be assigned."""
    service = _admin_service()
    company = service.create_company(payload.company_name)
    audit_recorded = _record_audit(
        service,
        affected_user_id=None,
        affected_email=None,
        performed_by_user_id=admin.user_id,
        performed_by_email=admin.email,
        action="company.registered",
        entity_type="company",
        details={
            "company_id": company["company_id"],
            "company_name": company["company_name"],
        },
    )
    return {**company, "audit_recorded": audit_recorded}


@router.get("/summary")
def staff_summary(
    admin: AdminMfaUser,
    session: Session = Depends(get_db),
) -> dict:
    """Backend-driven KPI values for the agent management page.

    Every figure is computed from the same live records as the directory,
    company list and invitations table — no client-side sample numbers.
    """
    service = _admin_service()
    agents = _agent_records(session, service)
    invitations = service.list_invitations()
    return {
        "total_agents": len(agents),
        "active_agents": sum(
            1 for a in agents if a["account_status"] == rbac.STATUS_ACTIVE
        ),
        "pending_agents": sum(
            1 for a in agents if a["account_status"] == rbac.STATUS_PENDING
        ),
        "suspended_agents": sum(
            1 for a in agents if a["account_status"] == rbac.STATUS_SUSPENDED
        ),
        "open_invitations": sum(
            1 for i in invitations if _invitation_state(i) in _OPEN_INVITATION_STATES
        ),
        "invitations": len(invitations),
        "companies": len(service.list_companies()),
    }


@router.get("/overview")
def staff_overview(
    admin: AdminMfaUser,
    session: Session = Depends(get_db),
) -> dict:
    """Agent management snapshot: read each Supabase table only once.

    Keep /agents, /companies, /invitations and /summary for existing callers.
    Authentication/role/MFA checks remain the same as those endpoints.
    """
    service = _admin_service()
    agent_profiles = service.list_agent_profiles()
    company_rows = service.list_companies()
    invitation_rows = service.list_invitations()
    agents = _agent_records(
        session, service,
        agent_profiles=agent_profiles,
        company_rows=company_rows,
        invitation_rows=invitation_rows,
    )
    summary = {
        "total_agents": len(agents),
        "active_agents": sum(
            1 for row in agents if row["account_status"] == rbac.STATUS_ACTIVE
        ),
        "pending_agents": sum(
            1 for row in agents if row["account_status"] == rbac.STATUS_PENDING
        ),
        "suspended_agents": sum(
            1 for row in agents if row["account_status"] == rbac.STATUS_SUSPENDED
        ),
        "open_invitations": sum(
            1 for row in invitation_rows
            if _invitation_state(row) in _OPEN_INVITATION_STATES
        ),
        "invitations": len(invitation_rows),
        "companies": len(company_rows),
    }
    return {
        "agents": agents,
        "companies": company_rows,
        "invitations": invitation_rows,
        "summary": summary,
    }


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

    audit_recorded = _record_audit(
        service,
        affected_user_id=user_id,
        affected_email=updated.email,
        performed_by_user_id=admin.user_id,
        performed_by_email=admin.email,
        action=_STATUS_ACTIONS.get((previous, new_status), "staff.status_changed"),
        previous_status=previous,
        new_status=new_status,
    )
    return {**_mirror_payload(updated), "audit_recorded": audit_recorded}


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
    audit_recorded = _record_audit(
        service,
        affected_user_id=user_id,
        performed_by_user_id=admin.user_id,
        performed_by_email=admin.email,
        action="staff.mfa_factor_reset",
        details={"removed_factors": removed, "reason": payload.reason},
    )
    return {"removed_factors": removed, "re_enrollment_required": True, "audit_recorded": audit_recorded}


# ---------------------------------------------------------------------------
# Invitation + audit review
# ---------------------------------------------------------------------------


@router.get("/invitations")
def list_invitations(admin: AdminMfaUser) -> list[dict]:
    return _admin_service().list_invitations()


@router.post("/invitations/{invitation_id}/revoke")
def revoke_invitation(
    invitation_id: uuid.UUID,
    admin: AdminMfaUser,
) -> dict:
    """Close an open invitation so the address can be invited again.

    The Supabase identity is NOT deleted and no email is sent: the partial
    unique index over ``pending`` / ``sent`` invitations is simply released.
    A closed or unknown invitation is refused rather than silently rewritten.
    """
    service = _admin_service()
    invitation = service.get_invitation(str(invitation_id))
    if invitation is None:
        raise HTTPException(status_code=404, detail="Invitation not found.")
    state = _invitation_state(invitation)
    if state not in _OPEN_INVITATION_STATES:
        raise HTTPException(
            status_code=409,
            detail=f"Only open invitations can be revoked (current state: {state or 'unknown'}).",
        )
    service.update_invitation(str(invitation_id), {"invitation_status": "revoked"})
    audit_recorded = _record_audit(
        service,
        # The audit table's user_id_affected has an FK to public.users; an
        # invitation may reference an auth identity with no mirror row, so the
        # id is recorded in details instead of forcing a broken foreign key.
        affected_user_id=None,
        affected_email=invitation.get("invited_email"),
        performed_by_user_id=admin.user_id,
        performed_by_email=admin.email,
        action="staff.invitation_revoked",
        details={
            "invitation_id": str(invitation_id),
            "previous_status": state,
            "invited_user_id": invitation.get("invited_user_id"),
        },
    )
    return {**invitation, "invitation_status": "revoked", "audit_recorded": audit_recorded}


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
def my_assigned_listings(
    agent: AgentMfaUser, session: Session = Depends(get_db)
) -> dict:
    """Listings assigned to the authenticated agent (valid empty state when
    there is no agent profile or no assignment - never unrelated listings).

    The assignment rows live in ``agent_listing_assignment`` with a REAL
    foreign key to ``fyp.rental_properties(id)``; the Supabase agent profile
    only supplies the ``agent_id`` scope. A row whose operational property
    disappeared is reported with ``property_exists: false`` rather than being
    rendered as a property.
    """
    service = _admin_service()
    profile = _agent_profile_or_empty(service, agent.user_id)
    if profile is None:
        return {"agent": None, "listings": []}
    listings = AgentAssignmentRepository(session).list_for_agent(
        int(profile["agent_id"])
    )
    # The derived management state travels with each row so the workspace never
    # has to assume "I am the manager" — a row reassigned elsewhere, or an
    # assignment whose agent account was suspended, is reported truthfully.
    management = resolve_listings(
        session, [int(r["listing_id"]) for r in listings if r.get("property_exists")]
    )
    for row in listings:
        row["management"] = management.get(int(row["listing_id"]))
    return {"agent": profile, "listings": listings}


def _require_listing_access(
    session: Session,
    service: SupabaseAdminService,
    user: AgentMfaUser,
    listing_id: int,
) -> tuple[dict, dict | None]:
    """One enforcement point for listing scope.

    The assignment is read from ``agent_listing_assignment`` (FK to the
    operational property). A missing assignment is a 404 - it is also how a
    property that does not exist is reported, so an agent can never probe the
    property table through this route. A different agent's assignment is a
    403. Administrators pass without an assignment row (their decisions are
    audited separately).
    """
    repo = AgentAssignmentRepository(session)
    assignment = repo.get(listing_id)
    if rbac.can_administer_users(user.role):
        # Administrators may act on any listing, including one that has no
        # assignment row yet - but never on an id that is not a real property.
        if assignment is not None:
            return assignment, None
        exists = session.execute(
            text("SELECT 1 FROM fyp.rental_properties WHERE id = :lid"),
            {"lid": int(listing_id)},
        ).scalar()
        if not exists:
            raise HTTPException(status_code=404, detail="Listing not found.")
        return {"listing_id": int(listing_id), "agent_id": None, "property_exists": True}, None
    if assignment is None:
        raise HTTPException(status_code=404, detail="Listing not found.")
    profile = _agent_profile_or_empty(service, user.user_id)
    if profile is None or assignment.get("agent_id") != profile.get("agent_id"):
        # Scope enforcement: an agent cannot reach another agent's listing by
        # changing a request parameter.
        raise HTTPException(status_code=403, detail="This listing is not assigned to you.")
    return assignment, profile


@router.post("/listings/{listing_id}/verifications", status_code=201)
def submit_verification(
    listing_id: int,
    payload: VerificationFindingRequest,
    user: AgentMfaUser,
    session: Session = Depends(get_db),
) -> dict:
    """Record a listing-verification finding on an ASSIGNED listing.

    Keeps the existing ``listing_verification`` mechanism (review findings,
    change requests, outcomes); final approval decisions stay with the
    administrator through the listing review workflow.
    """
    service = _admin_service()
    _require_listing_access(session, service, user, listing_id)
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
    session: Session = Depends(get_db),
) -> list[dict]:
    service = _admin_service()
    _require_listing_access(session, service, user, listing_id)
    return service.list_listing_verifications(listing_id)


@router.post("/listings/{listing_id}/assign")
def assign_listing(
    listing_id: int,
    payload: AssignListingRequest,
    admin: AdminMfaUser,
    session: Session = Depends(get_db),
) -> dict:
    """Assign (or reassign) an operational property to an agent profile.

    Writes ``agent_listing_assignment``; the FK rejects ids that are not real
    properties, and that case is surfaced as 404 (never a phantom row).
    """
    service = _admin_service()
    profile = _agent_profile_or_empty(service, payload.agent_user_id)
    if profile is None:
        raise HTTPException(status_code=404, detail="Agent profile not found.")
    try:
        updated = AgentAssignmentRepository(session).assign(
            listing_id,
            int(profile["agent_id"]),
            assigned_by=admin.user_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    audit_recorded = _record_audit(
        service,
        affected_user_id=payload.agent_user_id,
        performed_by_user_id=admin.user_id,
        performed_by_email=admin.email,
        action="listing.assigned",
        details={"listing_id": listing_id, "agent_id": profile["agent_id"]},
    )
    return {**updated, "audit_recorded": audit_recorded}


@router.delete("/listings/{listing_id}/assign")
def unassign_listing(
    listing_id: int,
    admin: AdminMfaUser,
    session: Session = Depends(get_db),
) -> dict:
    """Remove the assignment (the property itself is untouched)."""
    removed = AgentAssignmentRepository(session).unassign(listing_id)
    if not removed:
        raise HTTPException(status_code=404, detail="No assignment for this listing.")
    return {"listing_id": listing_id, "unassigned": True}
