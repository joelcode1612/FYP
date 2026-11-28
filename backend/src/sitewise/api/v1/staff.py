"""Staff administration plus trusted invited-provider onboarding.

Administrator and Agent routes require a verified Supabase session, an ACTIVE
account, the appropriate role and completed MFA (the verified ``aal2`` claim
on the signed token). Password-only sessions receive a structured 403
(``code: "staff_mfa_required"``) so the frontend can route to the MFA
enrollment / challenge screens. The onboarding-completion route intentionally
uses ``CurrentUser`` and re-proves every pending Owner/Agent precondition.

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
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, ConfigDict, EmailStr, Field
from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.config import settings
from sitewise.core.exceptions import ConflictError
from sitewise.core.supabase_admin import SupabaseAdminError, SupabaseAdminService
from sitewise.db.models.user import User
from sitewise.db.session import get_db
from sitewise.dependencies import (
    AdminMfaUser,
    AgentMfaUser,
    CurrentUser,
    _staff_mfa_required,
    get_user_service,
)
from sitewise.domain import rbac
from sitewise.services.provider_verification_service import (
    ProviderVerificationService,
)
from sitewise.services.user_service import UserService
from sitewise.repositories.agent_assignment_repository import (
    AgentAssignmentRepository,
)
from sitewise.repositories.listing_verification_repository import (
    ListingVerificationRepository,
)
from sitewise.services.property_management_service import resolve_listings
from sitewise.services import security_audit_service as security_audit
from sitewise.services.admin_dashboard_service import dashboard_statistics

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


class CreateOwnerRequest(BaseModel):
    """Administrator-supplied identity details for an invited Property Owner.

    Role, account status and assurance are deliberately absent: the server
    always provisions ``owner`` / ``pending`` and activation requires the
    trusted onboarding checks.
    """

    model_config = ConfigDict(extra="forbid")

    full_name: str = Field(min_length=2, max_length=120)
    email: EmailStr
    phone_number: str | None = Field(default=None, max_length=20)


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


def _invitation_role(row: dict) -> str:
    """Legacy rows predate role tracking and are therefore Agent invitations."""
    raw = row.get("invited_role")
    if raw is None or str(raw).strip() == "":
        return rbac.ROLE_AGENT
    role = rbac.canonical_role(str(raw))
    return role if role in (rbac.ROLE_AGENT, rbac.ROLE_OWNER) else "invalid"


def _owner_invitation_expiry() -> str:
    return (
        datetime.now(timezone.utc)
        + timedelta(minutes=settings.staff_invitation_expiry_minutes)
    ).isoformat()


def _invitation_claim_is_active(row: dict) -> bool:
    claimed = _parse_supabase_timestamp(row.get("provisioning_claimed_at"))
    if claimed is None:
        return False
    return claimed > (
        datetime.now(timezone.utc)
        - timedelta(seconds=settings.staff_invitation_claim_seconds)
    )


def _claim_invitation_for_dispatch(
    service: SupabaseAdminService, row: dict
) -> tuple[dict, str]:
    if _invitation_state(row) != "pending":
        raise HTTPException(status_code=409, detail="Only pending invitations can be dispatched.")
    previous_claim = row.get("provisioning_claimed_at")
    if _invitation_claim_is_active(row):
        raise HTTPException(
            status_code=409,
            detail="This invitation is already being dispatched by another request.",
        )
    claimed_at = datetime.now(timezone.utc).isoformat()
    claimed = service.update_invitation(
        str(row["invitation_id"]),
        {"provisioning_claimed_at": claimed_at},
        expected_statuses=("pending",),
        expected_fields={"provisioning_claimed_at": previous_claim},
    )
    if claimed is None:
        raise HTTPException(
            status_code=409,
            detail="This invitation changed while its dispatch was being claimed.",
        )
    return claimed, claimed_at


def _release_invitation_claim(
    service: SupabaseAdminService, row: dict, claimed_at: str
) -> None:
    try:
        service.update_invitation(
            str(row["invitation_id"]),
            {"provisioning_claimed_at": None},
            expected_statuses=("pending",),
            expected_fields={"provisioning_claimed_at": claimed_at},
        )
    except Exception:
        logger.exception("Failed to release invitation dispatch claim")


def _expire_invitation_if_due(service: SupabaseAdminService, row: dict) -> dict:
    if _invitation_state(row) not in _OPEN_INVITATION_STATES or not _invitation_is_expired(row):
        return row
    expired = service.update_invitation(
        str(row["invitation_id"]),
        {"invitation_status": "expired", "provisioning_claimed_at": None},
        expected_statuses=_OPEN_INVITATION_STATES,
    )
    return expired or service.get_invitation(str(row["invitation_id"])) or row


def _iso(value: object) -> str:
    """ISO-8601 for a datetime column, empty string when the mirror has none."""
    formatter = getattr(value, "isoformat", None)
    return formatter() if callable(formatter) else ""


def _latest_invitations(
    service: SupabaseAdminService,
    rows: list[dict] | None = None,
    *,
    role: str | None = None,
) -> dict[str, dict]:
    """Newest invitation per email, optionally restricted to one role."""
    if rows is None:
        rows = service.list_invitations()
    ordered = sorted(
        (_expire_invitation_if_due(service, row) for row in rows),
        key=lambda row: str(row.get("created_at") or ""),
        reverse=True,
    )
    latest: dict[str, dict] = {}
    for row in ordered:
        if role is not None and _invitation_role(row) != role:
            continue
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
    user_service: UserService,
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
    invitations = _latest_invitations(
        service, invitation_rows, role=rbac.ROLE_AGENT
    )
    records: list[dict] = []
    for profile in user_service.list_users(limit=500):
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
    if payload.company_name:
        return service.resolve_company(payload.company_name), payload.company_name.strip()
    matches = [
        row for row in service.list_companies()
        if str(row.get("company_name") or "").strip().casefold() == "sitewise"
        and row.get("company_id") is not None
    ]
    if len(matches) != 1:
        raise HTTPException(409, "The SiteWise company could not be verified. No invitation was sent.")
    return int(matches[0]["company_id"]), str(matches[0]["company_name"])


# ---------------------------------------------------------------------------
# Step 1-3 of the confirmed workflow: administrator creates the agent account
# and Supabase emails the native password-setup (invite) link.
# ---------------------------------------------------------------------------


@router.post("/agents", status_code=201)
def create_agent(
    payload: CreateAgentRequest,
    admin: AdminMfaUser,
    user_service: UserService = Depends(get_user_service),
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
    local_profile = user_service.get_user_by_email(email)
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

    if existing is not None and not payload.allow_existing:
        raise HTTPException(
            409, "This email already has an account. Confirm that you want to grant it Agent access."
        )
    existing_agent = service.get_agent_profile(str(existing["id"])) if existing else None
    if existing_agent and existing_agent.get("company_id") is not None:
        company_id = int(existing_agent["company_id"])
        company_name = str((service.get_company(company_id) or {}).get("company_name") or "")
    else:
        company_id, company_name = _resolve_assignment(service, payload)

    invited = False
    if existing is not None:
        auth_user_id = str(existing["id"])
    else:
        invited_user = service.invite_staff_user(
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
    mirror = user_service.ensure_staff_profile(
        user_id=uuid.UUID(auth_user_id),
        email=email,
        full_name=payload.full_name,
        phone_number=payload.phone_number,
        role=rbac.ROLE_AGENT,
        account_status=rbac.STATUS_PENDING,
    )

    # Agent profile in the existing public.agent table (links auth identity
    # to listing assignments via agent.user_id).
    agent_profile = existing_agent or service.create_agent_profile(
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
            invited_role=rbac.ROLE_AGENT,
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
            "invited_role": rbac.ROLE_AGENT,
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


@router.post("/owners", status_code=201)
def create_owner(
    payload: CreateOwnerRequest,
    admin: AdminMfaUser,
    user_service: UserService = Depends(get_user_service),
) -> dict:
    """Invite or safely reconcile a Property Owner without Agent side effects.

    Every new invitation starts as ``pending``. A compare-and-set dispatch
    claim prevents concurrent administrators from sending the same email, and
    a retry can finish partial provisioning without duplicating the identity.
    Revoked/expired invitations may be replaced only for the same unconfirmed
    provisional identity or an already-bound pending Owner. Confirmed pending
    Owners receive a replacement ``accepted`` row without a redundant email;
    established accounts are never promoted automatically.
    """
    service = _admin_service()
    email = str(payload.email).strip().lower()
    full_name = payload.full_name.strip()
    phone_number = payload.phone_number.strip() if payload.phone_number else None
    phone_number = phone_number or None
    if len(full_name) < 2:
        raise HTTPException(status_code=422, detail="Full name is required.")

    existing = service.find_auth_user_by_email(email)
    local_profile = user_service.get_user_by_email(email)
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

    authoritative = (
        service.get_identity_profile(str(existing["id"])) if existing else None
    )
    if authoritative is not None:
        if (
            str(authoritative.get("user_id")) != str(existing["id"])
            or str(authoritative.get("email") or "").strip().lower() != email
        ):
            raise HTTPException(
                status_code=409,
                detail="The existing identity and authoritative profile do not match.",
            )
    existing_role = (
        rbac.canonical_role(str(authoritative.get("role")))
        if authoritative is not None
        else (rbac.canonical_role(local_profile.role) if local_profile else None)
    )
    existing_status = (
        str(authoritative.get("account_status") or "").strip().lower()
        if authoritative is not None
        else (local_profile.account_status if local_profile else None)
    )
    existing_confirmed = bool(
        existing and (existing.get("email_confirmed_at") or existing.get("confirmed_at"))
    )
    provisional_identity = bool(
        existing
        and not existing_confirmed
        and existing_role in (None, rbac.ROLE_ENTREPRENEUR, rbac.ROLE_OWNER)
        and existing_status in (None, rbac.STATUS_PENDING)
    )
    confirmed_pending_owner = bool(
        existing_confirmed
        and existing_role == rbac.ROLE_OWNER
        and existing_status == rbac.STATUS_PENDING
    )

    invitation_rows = [
        _expire_invitation_if_due(service, row)
        for row in service.list_invitations(email)
    ]
    open_invitation = next(
        (
            row
            for row in invitation_rows
            if _invitation_state(row) in _OPEN_INVITATION_STATES
        ),
        None,
    )
    if open_invitation is not None and _invitation_role(open_invitation) != rbac.ROLE_OWNER:
        raise HTTPException(
            status_code=409,
            detail=(
                "An open invitation already exists for this email for another "
                "role. Revoke it before inviting an Owner."
            ),
        )

    replaced_invitation_id = None
    invitation = next(
        (
            row
            for row in invitation_rows
            if _invitation_state(row) in _OPEN_INVITATION_STATES
            and _invitation_role(row) == rbac.ROLE_OWNER
        ),
        None,
    )
    if invitation is None:
        latest = _newest_invitation(
            service, email, role=rbac.ROLE_OWNER, rows=invitation_rows
        )
        state = _invitation_state(latest or {})
        if latest is not None and state == "accepted":
            invited_for = latest.get("invited_user_id")
            if (
                existing is None
                or not invited_for
                or str(invited_for) != str(existing["id"])
                or not confirmed_pending_owner
            ):
                raise HTTPException(
                    status_code=409,
                    detail=(
                        "The accepted invitation no longer matches a pending "
                        "Owner account. Administrator reconciliation is required."
                    ),
                )
            invitation = latest
        elif latest is not None and state in ("revoked", "expired"):
            invited_for = latest.get("invited_user_id")
            if existing is not None:
                if invited_for and str(invited_for) != str(existing["id"]):
                    raise HTTPException(
                        status_code=409,
                        detail=(
                            "The closed invitation belongs to a different identity. "
                            "Administrator reconciliation is required."
                        ),
                    )
                if not (provisional_identity or confirmed_pending_owner):
                    raise HTTPException(
                        status_code=409,
                        detail=(
                            "This email belongs to an established account. Owner "
                            "invitations cannot change its role or status."
                        ),
                    )
            replaced_invitation_id = latest.get("invitation_id")
            invitation = service.insert_invitation(
                invited_user_id=None,
                invited_email=email,
                invited_by_user_id=admin.user_id,
                status="pending",
                expires_at=_owner_invitation_expiry(),
                invited_role=rbac.ROLE_OWNER,
            )
        elif latest is not None:
            raise HTTPException(
                status_code=409,
                detail=f"The latest Owner invitation has invalid state {state or 'unknown'}.",
            )
        elif existing is not None:
            raise HTTPException(
                status_code=409,
                detail=(
                    "This email already belongs to an existing account. Owner "
                    "invitations cannot change an established account's role."
                ),
            )
        else:
            invitation = service.insert_invitation(
                invited_user_id=None,
                invited_email=email,
                invited_by_user_id=admin.user_id,
                status="pending",
                expires_at=_owner_invitation_expiry(),
                invited_role=rbac.ROLE_OWNER,
            )
    else:
        state = _invitation_state(invitation)
        invited_for = invitation.get("invited_user_id")
        if invited_for and (existing is None or str(invited_for) != str(existing["id"])):
            raise HTTPException(
                status_code=409,
                detail=(
                    "This invitation is bound to a different identity. "
                    "Revoke it before issuing another invitation."
                ),
            )
        if state == "sent" and existing is None:
            raise HTTPException(
                status_code=409,
                detail=(
                    "The invited identity is missing. Revoke this invitation "
                    "before issuing a replacement."
                ),
            )
        if existing is not None and not (
            provisional_identity or confirmed_pending_owner
        ):
            raise HTTPException(
                status_code=409,
                detail="The existing account cannot be changed by an Owner invitation.",
            )

    auth_user_id = str(existing["id"]) if existing is not None else ""
    new_identity = existing is None
    email_sent = False
    state = _invitation_state(invitation)

    if state == "pending" and existing is not None and existing_confirmed:
        if not confirmed_pending_owner:
            raise HTTPException(
                status_code=409,
                detail="A confirmed account cannot be promoted by an Owner invitation.",
            )
        accepted = service.update_invitation(
            str(invitation["invitation_id"]),
            {
                "invited_user_id": auth_user_id,
                "invitation_status": "accepted",
                "accepted_at": datetime.now(timezone.utc).isoformat(),
                "provisioning_claimed_at": None,
            },
            expected_statuses=("pending",),
        )
        current = accepted or service.get_invitation(str(invitation["invitation_id"]))
        if (
            current is None
            or _invitation_state(current) != "accepted"
            or str(current.get("invited_user_id") or "") != auth_user_id
        ):
            raise HTTPException(
                status_code=409,
                detail="The replacement invitation changed during reconciliation.",
            )
        invitation = current
    elif state == "pending":
        claimed, claimed_at = _claim_invitation_for_dispatch(service, invitation)
        try:
            if existing is None:
                invited_user = service.invite_staff_user(
                    email=email,
                    full_name=full_name,
                    phone_number=phone_number,
                )
                if str(invited_user.get("email") or "").strip().lower() != email:
                    raise SupabaseAdminError("Supabase returned a mismatched invited identity.")
                existing = invited_user
                auth_user_id = str(existing["id"])
                new_identity = True
            else:
                service.resend_signup_confirmation(email=email)
            email_sent = True
        except Exception:
            _release_invitation_claim(service, claimed, claimed_at)
            raise
        sent = service.update_invitation(
            str(invitation["invitation_id"]),
            {
                "invited_user_id": auth_user_id,
                "invitation_status": "sent",
                "sent_at": datetime.now(timezone.utc).isoformat(),
                "provisioning_claimed_at": None,
            },
            expected_statuses=("pending",),
            expected_fields={"provisioning_claimed_at": claimed_at},
        )
        if sent is None:
            raise HTTPException(
                status_code=409,
                detail=(
                    "The invitation dispatch claim changed before completion. "
                    "Retry to reconcile the identity safely."
                ),
            )
        invitation = sent
    elif state == "sent" and not invitation.get("invited_user_id"):
        attached = service.update_invitation(
            str(invitation["invitation_id"]),
            {"invited_user_id": auth_user_id},
            expected_statuses=("sent",),
        )
        invitation = attached or service.get_invitation(str(invitation["invitation_id"]))
        if invitation is None or str(invitation.get("invited_user_id") or "") != auth_user_id:
            raise HTTPException(
                status_code=409,
                detail="The invitation identity changed during reconciliation.",
            )

    if not auth_user_id:
        raise SupabaseAdminError("Owner provisioning completed without an identity.")
    profile_name = (
        str(authoritative.get("full_name"))
        if existing_role == rbac.ROLE_OWNER
        and authoritative is not None
        and authoritative.get("full_name")
        else full_name
    )
    profile_phone = (
        str(authoritative.get("phone_number"))
        if existing_role == rbac.ROLE_OWNER
        and authoritative is not None
        and authoritative.get("phone_number")
        else phone_number
    )
    service.reconcile_invited_owner_profile(
        user_id=auth_user_id,
        email=email,
        full_name=profile_name,
        phone_number=profile_phone,
    )
    mirror = user_service.ensure_staff_profile(
        user_id=uuid.UUID(auth_user_id),
        email=email,
        full_name=profile_name,
        phone_number=profile_phone,
        role=rbac.ROLE_OWNER,
        account_status=rbac.STATUS_PENDING,
    )
    audit_recorded = _record_audit(
        service,
        affected_user_id=auth_user_id,
        affected_email=email,
        performed_by_user_id=admin.user_id,
        performed_by_email=admin.email,
        action=(
            "staff.owner_invited"
            if email_sent
            else "staff.owner_invitation_reconciled"
        ),
        previous_role=existing_role,
        new_role=rbac.ROLE_OWNER,
        new_status=rbac.STATUS_PENDING,
        details={
            "invitation_id": invitation.get("invitation_id"),
            "replaced_invitation_id": replaced_invitation_id,
            "invited_role": rbac.ROLE_OWNER,
            "email_sent": email_sent,
            "reconciled": not email_sent,
        },
    )
    return {
        "owner_user_id": auth_user_id,
        "email": email,
        "role": rbac.ROLE_OWNER,
        "account_status": rbac.STATUS_PENDING,
        "invited": new_identity,
        "email_sent": email_sent,
        "invitation": invitation,
        "invitation_status": _invitation_state(invitation),
        "mirror": _mirror_payload(mirror),
        "audit_recorded": audit_recorded,
    }


@router.get("/agents")
def list_agents(
    admin: AdminMfaUser,
    user_service: UserService = Depends(get_user_service),
) -> list[dict]:
    """Agent accounts joined to their company and latest invitation state."""
    return _agent_records(user_service, _admin_service())


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
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed.replace(tzinfo=timezone.utc) if parsed.tzinfo is None else parsed


def _invitation_is_expired(row: dict) -> bool:
    expires = _parse_supabase_timestamp(row.get("expires_at"))
    return expires is not None and expires <= datetime.now(timezone.utc)


def _newest_invitation(
    service: SupabaseAdminService,
    email: str,
    *,
    role: str | None = None,
    rows: list[dict] | None = None,
) -> dict | None:
    invitation_rows = rows if rows is not None else service.list_invitations(email)
    matching = [
        _expire_invitation_if_due(service, row)
        for row in invitation_rows
        if role is None or _invitation_role(row) == role
    ]
    if not matching:
        return None
    return sorted(
        matching, key=lambda row: str(row.get("created_at") or ""), reverse=True
    )[0]


def _has_verified_totp_factor(service: SupabaseAdminService, auth_user_id: str) -> bool:
    return any(
        factor.get("status") == "verified"
        and str(factor.get("factor_type") or factor.get("type") or "").lower() == "totp"
        for factor in service.admin_list_factors(auth_user_id)
    )


def invitation_accepted_for(
    service: SupabaseAdminService,
    email: str,
    *,
    role: str = rbac.ROLE_AGENT,
) -> bool:
    """True when the address's newest invitation for ``role`` is ``accepted``.

    The evidence gate for Agent account verification: only a completed Agent
    invitation lifecycle counts. An open, expired, revoked or missing
    invitation is never evidence — agents provisioned without an invite
    (allow_existing) stay on the submission-review workflow, and merely
    selecting the agent role verifies nobody.
    """
    invitation = _newest_invitation(service, email, role=role)
    if invitation is None:
        return False
    return _invitation_state(invitation) == "accepted"


@router.post("/onboarding/complete")
def complete_onboarding(
    user: CurrentUser,
    session: Session = Depends(get_db),
    user_service: UserService = Depends(get_user_service),
) -> dict:
    """Trusted completion of an invited Owner or Agent lifecycle.

    Preconditions re-proven here on every call (never trusted from the
    client): the signed token's subject, an invited provider role, a signed
    ``aal2`` claim backed by a verified TOTP factor on the identity,
    Supabase's own invitation-acceptance evidence (``email_confirmed_at``),
    and ownership plus validity of a role-matched invitation row.

    Transitions are idempotent and reconciling: the invitation row moves to
    ``accepted`` with ``accepted_at``, the authoritative ``public.users``
    row and the enforcement mirror both move to ``active``, and a single
    ``role_change_audit`` entry records the real transition. Re-calling the
    endpoint after a partial failure completes only the missing writes.
    """
    role = rbac.canonical_role(user.role)
    if role not in rbac.INVITED_PROVIDER_ROLES:
        raise _structured_error(
            403,
            "onboarding_forbidden",
            "Onboarding completion requires an invited Owner or Agent account.",
        )
    if user.assurance_level != rbac.REQUIRED_STAFF_AAL:
        raise _staff_mfa_required()
    if user.account_status == rbac.STATUS_SUSPENDED:
        raise _structured_error(
            403,
            "onboarding_suspended",
            "This account is suspended; activation is not possible.",
        )

    service = _admin_service()
    email = str(user.email or "").strip().lower()

    # 1. Supabase-verified acceptance evidence: the authoritative proof that
    # the invited user actually accepted the invite (set a password through
    # the emailed link) is the confirmation timestamp on the auth identity -
    # never "the email was sent" or "the invite link was opened".
    auth_user = service.get_auth_user(str(user.user_id))
    if auth_user is None:
        raise _structured_error(
            409,
            "identity_unavailable",
            "The invited identity could not be verified. Ask an administrator "
            "to reconcile the account.",
        )
    if (
        str(auth_user.get("id")) != str(user.user_id)
        or str(auth_user.get("email") or "").strip().lower() != email
    ):
        raise _structured_error(
            403,
            "identity_mismatch",
            "The authenticated identity does not match the invited account.",
        )
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

    # 3. Role-matched invitation ownership + validity. The legacy Agent
    # allow_existing workflow may omit an invitation; Owner onboarding may not.
    invitation = _newest_invitation(service, email, role=role)
    invitation_id = ""
    state = ""
    if invitation is None and role == rbac.ROLE_OWNER:
        raise _structured_error(
            409,
            "owner_invitation_required",
            "A matching Owner invitation is required before activation.",
        )
    if invitation is not None:
        invitation_id = str(invitation.get("invitation_id") or "")
        state = _invitation_state(invitation)
        invited_for = invitation.get("invited_user_id")
        if role == rbac.ROLE_OWNER and (
            not invited_for or str(invited_for) != str(user.user_id)
        ):
            raise _structured_error(
                403,
                "invitation_ownership",
                "This invitation was issued to a different identity.",
            )
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
                expired = service.update_invitation(
                    invitation_id,
                    {"invitation_status": "expired", "provisioning_claimed_at": None},
                    expected_statuses=_OPEN_INVITATION_STATES,
                )
                if expired is None:
                    current = service.get_invitation(invitation_id) or {}
                    current_state = _invitation_state(current)
                    if current_state == "revoked":
                        raise _structured_error(
                            410,
                            "invitation_revoked",
                            "This invitation was revoked while onboarding was being completed.",
                        )
                    raise _structured_error(
                        409,
                        "invitation_changed",
                        "This invitation changed while onboarding was being completed.",
                    )
            raise _structured_error(
                410,
                "invitation_expired",
                "This invitation has expired. Ask an administrator to send "
                "a new one.",
            )
        if state not in (*_OPEN_INVITATION_STATES, "accepted"):
            raise _structured_error(
                409,
                "invitation_invalid",
                "This invitation is not in a state that permits activation.",
            )

    # 4. Close an open invitation with a compare-and-set before activation.
    # A concurrent revocation can no longer overwrite this accepted transition;
    # if activation later fails, the accepted row lets an idempotent retry heal
    # the remaining profile writes.
    if invitation is not None and state in _OPEN_INVITATION_STATES:
        closed = service.update_invitation(
            invitation_id,
            {
                "invitation_status": "accepted",
                "accepted_at": datetime.now(timezone.utc).isoformat(),
            },
            expected_statuses=_OPEN_INVITATION_STATES,
        )
        if closed is None:
            current = service.get_invitation(invitation_id)
            current_state = _invitation_state(current or {})
            if current is None or current_state != "accepted":
                code = "invitation_revoked" if current_state == "revoked" else "invitation_changed"
                raise _structured_error(
                    410 if current_state in ("revoked", "expired") else 409,
                    code,
                    "The invitation changed while onboarding was being completed.",
                )
            invitation = current
        else:
            invitation = closed
        state = "accepted"

    # 5. Activation - authoritative identity row first, then the enforcement
    # mirror, mirroring the ordering of every other status change. Skipped
    # entirely when the account is already active (idempotent retries).
    activated = False
    audit_recorded = True
    if user.account_status != rbac.STATUS_ACTIVE:
        transitioned = service.update_identity_profile_if(
            user.user_id,
            {"account_status": rbac.STATUS_ACTIVE, "email_verified": True},
            expected_status=user.account_status,
            expected_role=role,
        )
        if transitioned is None:
            current = service.get_identity_profile(user.user_id) or {}
            current_status = str(current.get("account_status") or "").lower()
            current_role = rbac.canonical_role(str(current.get("role") or ""))
            if current_role != role:
                raise _structured_error(
                    409,
                    "invitation_changed",
                    "The account role changed while onboarding was being completed.",
                )
            if current_status == rbac.STATUS_SUSPENDED:
                raise _structured_error(
                    403,
                    "onboarding_suspended",
                    "This account was suspended while onboarding was being completed.",
                )
            if current_status != rbac.STATUS_ACTIVE:
                raise _structured_error(
                    409,
                    "invitation_changed",
                    "The account status changed while onboarding was being completed.",
                )
        updated = user_service.update_user(
            user.user_id,
            {"account_status": rbac.STATUS_ACTIVE, "email_verified": True},
        )
        if updated is None:  # pragma: no cover - profile read above
            raise HTTPException(status_code=404, detail="Local profile not found.")
        if transitioned is not None:
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
                    "invited_role": role,
                    "email_confirmed_at": str(accepted_at),
                },
            )
            activated = True

    # 6. Account verification remains Agent-only. An accepted Agent invitation
    # verifies the provider without a separate submission; an allow_existing
    # Agent keeps the review workflow. Owners never acquire an Agent profile or
    # Agent verification record during onboarding.
    verification_status = ""
    if role == rbac.ROLE_AGENT and invitation is not None and state == "accepted":
        verification = ProviderVerificationService(session).verify_from_invitation(
            user_id=user.user_id,
            role=role,
            full_name=user.profile.full_name or "",
            contact_phone=user.profile.phone_number or "",
        )
        verification_status = verification["status"]

    return {
        "account_status": rbac.STATUS_ACTIVE,
        "role": role,
        "invitation_id": invitation_id,
        "invitation_status": state,
        "email_confirmed_at": str(accepted_at),
        "activated": activated,
        "audit_recorded": audit_recorded,
        "account_verification_status": verification_status or None,
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
    user_service: UserService = Depends(get_user_service),
) -> dict:
    """Backend-driven KPI values for the agent management page.

    Every figure is computed from the same live records as the directory,
    company list and invitations table — no client-side sample numbers.
    """
    service = _admin_service()
    agents = _agent_records(user_service, service)
    invitations = [
        _expire_invitation_if_due(service, row)
        for row in service.list_invitations()
    ]
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
            1
            for i in invitations
            if _invitation_role(i) == rbac.ROLE_AGENT
            and _invitation_state(i) in _OPEN_INVITATION_STATES
        ),
        "invitations": sum(
            1 for i in invitations if _invitation_role(i) == rbac.ROLE_AGENT
        ),
        "companies": len(service.list_companies()),
    }


@router.get("/overview")
def staff_overview(
    admin: AdminMfaUser,
    user_service: UserService = Depends(get_user_service),
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
    invitation_rows = [
        _expire_invitation_if_due(service, row)
        for row in invitation_rows
    ]
    agents = _agent_records(
        user_service, service,
        agent_profiles=agent_profiles,
        company_rows=company_rows,
        invitation_rows=invitation_rows,
    )
    assignments: dict[int, list[dict]] = {}
    for row in AgentAssignmentRepository(session).list_all():
        if not row["property_exists"]:
            continue
        assignments.setdefault(row["agent_id"], []).append({
            "property_id": row["listing_id"],
            "name": row["name"],
            "inspection_status": _workload_status(row),
        })
    for agent in agents:
        agent_id = (agent["agent_profile"] or {}).get("agent_id")
        agent["assigned_properties"] = assignments.get(int(agent_id), []) if agent_id else []
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
            1
            for row in invitation_rows
            if _invitation_role(row) == rbac.ROLE_AGENT
            and _invitation_state(row) in _OPEN_INVITATION_STATES
        ),
        "invitations": sum(
            1
            for row in invitation_rows
            if _invitation_role(row) == rbac.ROLE_AGENT
        ),
        "companies": len(company_rows),
    }
    return {
        "agents": agents,
        "companies": company_rows,
        "invitations": invitation_rows,
        "summary": summary,
    }


def _workload_status(row: dict) -> str:
    workflow = row.get("workflow_status")
    stage = row.get("verification_status")
    if workflow == "declined":
        return "declined"
    if stage == "approved":
        return "completed"
    if workflow == "needs_correction" or row.get("task_state") == "corrections":
        return "needs_correction"
    if workflow == "submitted" or row.get("task_state") == "awaiting_review" or stage == "under_review":
        return "pending_review"
    if workflow == "accepted":
        return "ongoing"
    if workflow == "requested":
        return "requested"
    return "unknown"


@router.get("/dashboard")
def admin_dashboard(admin: AdminMfaUser, session: Session = Depends(get_db)) -> dict:
    result = dashboard_statistics(session)
    counts: dict[int, dict[str, int]] = {}
    assigned: dict[int, int] = {}
    for row in AgentAssignmentRepository(session).list_all():
        if row["property_exists"]:
            status = _workload_status(row)
            agent_id = int(row["agent_id"])
            if status != "declined":
                assigned[row["listing_id"]] = agent_id
            workload = counts.setdefault(agent_id, {})
            workload[status] = workload.get(status, 0) + 1

    names_available = True
    try:
        names = {
            int(row["agent_id"]): row.get("agent_name")
            for row in _admin_service().list_agent_profiles()
            if row.get("agent_id") is not None
        }
    except SupabaseAdminError:
        logger.warning("Dashboard agent names unavailable", exc_info=True)
        names = {}
        names_available = False
    result["workload"] = [
        {"name": names.get(agent_id) or f"Agent {agent_id}", **counts.get(agent_id, {})}
        for agent_id in sorted(names.keys() | counts.keys())
    ]
    result["workload_available"] = names_available or bool(counts)
    for review in result["reviews"]:
        agent_id = assigned.get(review["id"])
        review["agent"] = (
            names.get(agent_id) or "Name unavailable" if agent_id is not None else None
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
    user_service: UserService = Depends(get_user_service),
) -> dict:
    new_status = payload.validated()
    if new_status not in (rbac.STATUS_ACTIVE, rbac.STATUS_SUSPENDED):
        raise HTTPException(
            status_code=422,
            detail="Staff account status may only be set to active or suspended.",
        )
    service = _admin_service()
    target = user_service.get_user(user_id)
    if target is None:
        raise HTTPException(status_code=404, detail="User not found.")
    if user_id == admin.user_id and new_status != rbac.STATUS_ACTIVE:
        raise HTTPException(409, "You cannot disable your own administrator account.")
    if rbac.canonical_role(target.role) != rbac.ROLE_AGENT:
        raise HTTPException(status_code=422, detail="Target account is not an Agent account.")
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
    service = _admin_service()
    return [
        _expire_invitation_if_due(service, row)
        for row in service.list_invitations()
    ]


@router.post("/invitations/{invitation_id}/revoke")
def revoke_invitation(
    invitation_id: str,
    admin: AdminMfaUser,
) -> dict:
    """Close an open invitation so the address can be invited again.

    The Supabase identity is NOT deleted and no email is sent: the partial
    unique index over ``pending`` / ``sent`` invitations is simply released.
    A closed or unknown invitation is refused rather than silently rewritten.
    """
    # The live Supabase table uses BIGINT keys, while older migrations used UUID.
    # Accept both formats without changing the stored ID or relaxing admin/MFA.
    if invitation_id.isascii() and invitation_id.isdigit():
        if (len(invitation_id) > 19 or int(invitation_id) < 1
                or int(invitation_id) > 9223372036854775807):
            raise HTTPException(status_code=422, detail="Invalid invitation ID.")
        invite_key = str(int(invitation_id))
    else:
        try:
            invite_key = str(uuid.UUID(invitation_id))
        except ValueError:
            raise HTTPException(
                status_code=422,
                detail="Invitation ID must be a positive integer or a UUID.",
            ) from None

    service = _admin_service()
    invitation = service.get_invitation(invite_key)
    if invitation is None:
        raise HTTPException(status_code=404, detail="Invitation not found.")
    state = _invitation_state(invitation)
    if state not in _OPEN_INVITATION_STATES:
        raise HTTPException(
            status_code=409,
            detail=f"Only open invitations can be revoked (current state: {state or 'unknown'}).",
        )
    revoked = service.update_invitation(
        invite_key,
        {"invitation_status": "revoked", "provisioning_claimed_at": None},
        expected_statuses=_OPEN_INVITATION_STATES,
    )
    if revoked is None:
        current = service.get_invitation(invite_key)
        current_state = _invitation_state(current or {})
        raise HTTPException(
            status_code=409,
            detail=(
                "The invitation changed while it was being revoked "
                f"(current state: {current_state or 'unknown'})."
            ),
        )
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
            "invitation_id": invite_key,
            "previous_status": state,
            "invited_user_id": invitation.get("invited_user_id"),
            "invited_role": _invitation_role(invitation),
        },
    )
    return {**revoked, "audit_recorded": audit_recorded}


@router.get("/audit")
def list_audit(
    admin: AdminMfaUser,
    affected_user_id: uuid.UUID | None = Query(default=None),
) -> list[dict]:
    return _admin_service().list_role_audit(affected_user_id)


@router.get("/audit/security")
def list_security_audit(
    admin: AdminMfaUser,
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=25, ge=1, le=200),
    category: str = Query(default="all", pattern="^(all|admin|auth|mfa)$"),
    search: str = Query(default="", max_length=120),
    result: str = Query(default="all", pattern="^(all|success|failed|info)$"),
    role: str = Query(default="all", max_length=40),
    date_from: str | None = Query(default=None, max_length=40),
    date_to: str | None = Query(default=None, max_length=40),
) -> dict:
    """Normalized security + activity audit read for the System activity page.

    ADDITIVE to ``GET /audit`` above, which keeps its exact response contract
    for the admin dashboard and any existing consumer. This endpoint merges
    the administrative feed with Supabase authentication/MFA events where the
    deployment can actually read them, applies every filter server-side and
    paginates, and reports each source's REAL availability — it never emits
    fabricated events when a source is unreadable.

    Authorization is identical to ``GET /audit``: an authenticated
    administrator with completed MFA (`AdminMfaUser`).
    """
    return security_audit.list_security_audit(
        _admin_service(),
        page=page,
        page_size=page_size,
        category=category,
        search=search,
        result=result,
        role=role,
        date_from=date_from,
        date_to=date_to,
    )


# ---------------------------------------------------------------------------
# Staff self-service: assigned listings + verification findings
# ---------------------------------------------------------------------------


def _agent_profile_or_empty(service: SupabaseAdminService, user_id: uuid.UUID) -> dict | None:
    """The signed-in agent's Supabase profile, or ``None`` when it has none.

    A profile-service OUTAGE is not "no profile": swallowing it here would
    turn an authorization-infrastructure failure into a valid-looking empty
    listing set (the exact silent-empty antipattern). It fails closed with a
    structured 503 the client renders as a clear error with Retry, while a
    genuine "this account has no agent profile" still answers 200 with an
    empty, honest workspace.
    """
    try:
        return service.get_agent_profile(user_id)
    except SupabaseAdminError as exc:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "agent_profile_service_unavailable",
                "message": (
                    "The agent profile service is temporarily unavailable, so "
                    "assigned listings cannot be resolved. Try again shortly."
                ),
                "cause": str(exc),
            },
        ) from exc


#: Newest confirmed 360° panorama per property, produced by a COMPLETED capture
#: session owned by this agent. This mirrors the canonical conditions in
#: ``agent_inspection_policy.completed_agent_panorama`` (the single readiness
#: classifier) as ONE batched query instead of a call per assignment: the
#: canonical ``fyp.panoramas`` row written only by the confirmation endpoint is
#: the evidence, never a client claim. The workflow-status part of that policy
#: is applied per row in Python (``accepted`` / ``needs_correction`` only).
_PANORAMA_SQL = """
SELECT DISTINCT ON (p.property_id)
       p.property_id, p.panorama_id, p.verification_status, p.created_at
  FROM fyp.panoramas p
  JOIN fyp.capture_sessions cs ON cs.id = p.session_id
 WHERE p.property_id = ANY(:ids)
   AND cs.property_id = p.property_id
   AND cs.owner_id = :uid
   AND cs.status = 'completed'
   AND p.verification_status IS DISTINCT FROM 'rejected'
   AND p.storage_path IS NOT NULL AND btrim(p.storage_path) <> ''
 ORDER BY p.property_id, p.created_at DESC
"""


def _enrich_agent_rows(session: Session, agent_user_id: str, listings: list[dict]) -> None:
    """Attach the authoritative agent-workflow facts to each assignment row.

    Everything added here is READ from records that already exist — the
    assignment row's own workflow columns, the single readiness classifier
    ``agent_submission_readiness`` (reused verbatim, never reimplemented), and
    the batched canonical-panorama query above. Screens classify tasks from
    these fields; nothing is derived a second time on the client.

    Rows whose operational property disappeared stay untouched: there is no
    workflow to report for a property that no longer exists.
    """
    from sitewise.services.agent_inspection_policy import (
        REQUIRED_INSPECTION,
        agent_submission_readiness,
    )

    active = [
        int(r["listing_id"]) for r in listings
        if r.get("property_exists")
        and r.get("workflow_status") in ("accepted", "needs_correction")
    ]
    panorama_by_property: dict[str, dict] = {}
    if active:
        try:
            for p in session.execute(
                text(_PANORAMA_SQL),
                {"ids": [str(i) for i in active], "uid": str(agent_user_id)},
            ).mappings().all():
                created = p.get("created_at")
                panorama_by_property[str(p["property_id"])] = {
                    "panorama_id": str(p["panorama_id"]),
                    "verification_status": p.get("verification_status"),
                    "created_at": created.isoformat()
                    if created is not None and hasattr(created, "isoformat") else None,
                }
        except Exception:  # noqa: BLE001 - evidence display must not void the listing read
            logger.warning("Panorama batch lookup failed; reporting without it.", exc_info=True)

    for row in listings:
        if not row.get("property_exists"):
            continue
        workflow = row.get("workflow_status")
        inspection = row.get("inspection_data") or {}
        row["assignment_status"] = workflow
        row["inspection_checks_completed"] = sum(
            1 for key in REQUIRED_INSPECTION if inspection.get(key) is True
        )
        row["inspection_checks_total"] = len(REQUIRED_INSPECTION)
        confirmed = panorama_by_property.get(str(row["listing_id"]))
        row["panorama_record_id"] = confirmed["panorama_id"] if confirmed else None
        row["panorama_verification_status"] = (
            confirmed["verification_status"] if confirmed else None
        )
        readiness = None
        if workflow in ("accepted", "needs_correction"):
            readiness = agent_submission_readiness(
                session,
                int(row["listing_id"]),
                row,
                row,
                confirmed["panorama_id"] if confirmed else None,
            )
            row["submission_readiness"] = readiness
        row["next_action"], row["next_action_owner"] = _next_agent_action(row, readiness)


def _next_agent_action(row: dict, readiness: dict | None) -> tuple[str | None, str]:
    """The single next step the records support, and who owns it.

    Returned as ``(action, owner)`` where owner is ``agent`` | ``owner`` |
    ``admin`` | ``system`` | ``none``. An agent is never told to upload a
    document only the property owner can produce, and nothing is offered that
    the backend would refuse.
    """
    workflow = row.get("workflow_status")
    stage = (row.get("verification_status") or "").strip()

    if workflow == "requested":
        return "review_request", "agent"
    if workflow == "declined":
        return None, "none"
    if stage in ("pending", "under_review") or workflow == "submitted":
        return "await_admin_review", "admin"
    if stage == "rejected" or row.get("task_state") == "corrections" or workflow == "needs_correction":
        return "review_corrections", "agent"
    if stage == "approved":
        return ("view_published", "agent") if row.get("is_published") else (None, "admin")

    if workflow in ("accepted", "needs_correction") and readiness is not None:
        # Owner responsibility comes first: an agent cannot substitute for the
        # owner's readable, submitted ownership proof.
        if not readiness.get("ownership_proof_uploaded") or readiness.get(
            "ownership_submission_status"
        ) not in ("pending", "under_review", "verified"):
            return "await_owner_proof", "owner"
        if readiness.get("missing_property_fields"):
            return "complete_details", "agent"
        if readiness.get("missing_inspection_checks"):
            return "continue_inspection", "agent"
        if readiness.get("enrichment_running"):
            return "wait_enrichment", "system"
        if not readiness.get("panorama_confirmed"):
            return "capture_panorama", "agent"
        if readiness.get("ready"):
            return "submit_for_review", "agent"
    return None, "none"


def _agent_counts(rows: list[dict]) -> dict:
    """Workflow counts over the SAME enriched rows the response returns.

    Rules the specification fixes:
    * a declined assignment is a closed record — never an active inspection;
    * a property is only "in progress" / "ready" when its assignment is
      actually accepted (or under correction) and not yet submitted — a draft
      with no workflow behind it is not actionable inspection work;
    * "approved" and "published" are separate: an approved-but-unpublished
      property is not live.
    """
    counts = {
        "total": len(rows),
        "new_requests": 0,
        "accepted": 0,
        "inspections_in_progress": 0,
        "ready_to_submit": 0,
        "awaiting_admin_review": 0,
        "corrections_required": 0,
        "approved": 0,
        "published": 0,
        "declined": 0,
    }
    for row in rows:
        workflow = row.get("workflow_status")
        stage = (row.get("verification_status") or "").strip()
        readiness = row.get("submission_readiness") or {}
        if workflow == "requested":
            counts["new_requests"] += 1
        elif workflow == "accepted":
            counts["accepted"] += 1
        elif workflow == "declined":
            counts["declined"] += 1
        if workflow in ("accepted", "needs_correction") and stage in ("", "draft"):
            if readiness.get("ready"):
                counts["ready_to_submit"] += 1
            else:
                counts["inspections_in_progress"] += 1
        if stage in ("pending", "under_review") or workflow == "submitted":
            counts["awaiting_admin_review"] += 1
        if (
            stage == "rejected"
            or row.get("task_state") == "corrections"
            or workflow == "needs_correction"
        ):
            counts["corrections_required"] += 1
        if stage == "approved":
            counts["approved"] += 1
        if row.get("is_published"):
            counts["published"] += 1
    return counts


@router.get("/me/listings")
def my_assigned_listings(
    agent: AgentMfaUser, session: Session = Depends(get_db)
) -> dict:
    """Listings assigned to the authenticated agent (valid empty state when
    there is no agent profile, no agent id, or no assignment - never unrelated
    listings).

    The assignment rows live in ``agent_listing_assignment`` with a REAL
    foreign key to ``fyp.rental_properties(id)``; the Supabase agent profile
    only supplies the ``agent_id`` scope. A row whose operational property
    disappeared is reported with ``property_exists: false`` rather than being
    rendered as a property.

    The raw ``agent`` row carries only ``company_id``, so the associated
    ``public.company`` name is joined here for display (the profile screens
    show the real agency name, never the bare id). The join is additive
    display data: a failed lookup leaves ``company_name`` absent rather than
    failing the authorized listing read.

    Each row additionally carries the authoritative workflow facts (see
    ``_enrich_agent_rows``) and the response carries a ``counts`` block
    computed from those same rows (see ``_agent_counts``). Both are additive:
    existing consumers of ``{agent, listings}`` are unaffected.
    """
    service = _admin_service()
    profile = _agent_profile_or_empty(service, agent.user_id)
    if profile is None:
        return {"agent": None, "listings": [], "counts": _agent_counts([])}
    try:
        raw_company_id = profile.get("company_id")
        company = (
            service.get_company(int(raw_company_id))
            if raw_company_id is not None
            else None
        )
        if company and company.get("company_name"):
            profile["company_name"] = company["company_name"]
    except Exception:  # noqa: BLE001 - display join must never void the listings
        pass
    raw_agent_id = profile.get("agent_id")
    if raw_agent_id is None:
        # A profile row that resolves to no agent id manages nothing, which is
        # the same honest empty workspace as having no assignments. It must not
        # become a 500 here: every other agent-identity reader treats a missing
        # id as "no scope", and a failure on this read blanked the whole Agent
        # workspace rather than reporting an empty one.
        return {"agent": profile, "listings": [], "counts": _agent_counts([])}
    listings = AgentAssignmentRepository(session).list_for_agent(int(raw_agent_id))
    # The derived management state travels with each row so the workspace never
    # has to assume "I am the manager" — a row reassigned elsewhere, or an
    # assignment whose agent account was suspended, is reported truthfully.
    management = resolve_listings(
        session, [int(r["listing_id"]) for r in listings if r.get("property_exists")]
    )
    for row in listings:
        row["management"] = management.get(int(row["listing_id"]))
    _enrich_agent_rows(session, agent.user_id, listings)
    return {
        "agent": profile,
        "listings": listings,
        "counts": _agent_counts(listings),
    }


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

    Keeps the existing listing-verification mechanism (review findings,
    change requests, outcomes); final approval decisions stay with the
    administrator through the listing review workflow.

    Findings persist to the canonical ``fyp.property_listing_verification``
    table (one state per listing, property FK to ``fyp.rental_properties``).
    The former Supabase ``public.listing_verification`` destination was never
    provisioned in the live project; the repository raises ValueError for a
    non-existent listing, which maps to 404.
    """
    service = _admin_service()
    _require_listing_access(session, service, user, listing_id)
    repo = ListingVerificationRepository(session)
    try:
        record = repo.record_finding(
            listing_id=listing_id,
            verified_by_user_id=user.user_id,
            property_authenticity_status=payload.property_authenticity_status,
            commercial_classification_status=payload.commercial_classification_status,
            verification_reason=payload.verification_reason,
            evidence_url=payload.evidence_url,
        )
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return record


@router.get("/listings/{listing_id}/verifications")
def listing_verifications(
    listing_id: int,
    user: AgentMfaUser,
    session: Session = Depends(get_db),
) -> list[dict]:
    service = _admin_service()
    _require_listing_access(session, service, user, listing_id)
    return ListingVerificationRepository(session).list_for_listing(listing_id)


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
    eligible = session.execute(text("""
        SELECT role, account_status FROM public.users WHERE user_id=:id
    """), {"id": payload.agent_user_id}).first()
    if not eligible or rbac.canonical_role(eligible[0]) != rbac.ROLE_AGENT or eligible[1] != "active":
        raise HTTPException(409, "Choose an active Agent.")
    # Match the Owner request policy for existing owned properties. Hold the
    # property lock until the assignment write commits.
    owned = session.execute(text("""
        SELECT owner_user_id FROM fyp.rental_properties WHERE id=:id FOR UPDATE
    """), {"id": listing_id}).first()
    if owned and owned[0] is not None:
        from sitewise.services.agent_inspection_policy import require_submitted_ownership_proof
        require_submitted_ownership_proof(session, listing_id)
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
