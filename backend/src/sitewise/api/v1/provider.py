"""Owner / Agent (Provider) workspace APIs.

The Provider workspace is the Flutter mobile app for BOTH property owners and
agents, so these routes are shared rather than duplicated per role. What
differs between the two is never the screen — it is the database relationship
that decides which rows each account may see, resolved by
:mod:`sitewise.services.provider_scope` on every request:

* an **owner** reaches the rows it owns;
* an **agent** reaches the rows it is assigned;
* an **administrator** is given the unrestricted scope, because administration
  is the only reason it reaches this surface at all.

Three surfaces are mounted from this module:

| Prefix                | Surface                                          |
|-----------------------|--------------------------------------------------|
| ``/api/v1/provider``  | inbox, performance and account verification       |
| ``/api/v1/properties``| enquiry creation, by the person doing the asking  |
| ``/api/v1/staff/providers`` | administrator decision, ``aal2`` enforced    |

``require_property_owner`` is reused rather than re-declared: it is the single
definition of "may act on property listings", and it already demands a signed
``aal2`` for staff accounts (agent and administrator) — which is exactly what
makes the mobile MFA step load-bearing instead of decorative.
"""

from __future__ import annotations

import logging
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlmodel import Session

from sitewise.api.v1.staff import _admin_service, invitation_accepted_for
from sitewise.db.session import get_db
from sitewise.dependencies import (
    AuthenticatedUser,
    require_admin_mfa,
    require_entrepreneur,
    require_property_owner,
)
from sitewise.services.enquiry_service import EnquiryService
from sitewise.services.provider_performance_service import ProviderPerformanceService
from sitewise.services.provider_scope import (
    is_agent_role,
    managed_property_ids,
)
from sitewise.services.provider_verification_service import (
    REQUIREMENTS,
    ProviderVerificationService,
    provider_role_for,
)

logger = logging.getLogger("sitewise.provider_api")

#: Mounted at ``/provider`` — the workspace itself.
router = APIRouter()
#: Mounted at ``/properties`` — enquiry creation, by the enquirer.
enquirer_router = APIRouter()
#: Mounted at ``/staff/providers`` — administrator decision (``aal2``).
staff_router = APIRouter()

DbSession = Annotated[Session, Depends(get_db)]
ProviderUser = Annotated[AuthenticatedUser, Depends(require_property_owner)]
AdminUser = Annotated[AuthenticatedUser, Depends(require_admin_mfa)]
EnquirerUser = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]


def _scope(session: Session, current: AuthenticatedUser) -> list[int] | None:
    return managed_property_ids(
        session, user_id=current.user_id, role=current.role
    )


# ---------------------------------------------------------------------------
# Enquiries — the provider inbox
# ---------------------------------------------------------------------------


@router.get("/enquiries")
def list_enquiries(
    session: DbSession,
    current: ProviderUser,
    status: str | None = None,
    limit: int = 100,
) -> dict:
    """Every enquiry received for a property this account manages.

    An owner sees enquiries on the listings it owns; an agent sees the ones on
    its assigned listings; nobody sees another provider's inbox.
    """
    service = EnquiryService(session)
    scope = _scope(session, current)
    rows = service.list_for_provider(
        property_ids=scope, status=status, limit=limit
    )
    return {
        "data": rows,
        "meta": {
            **service.metrics(property_ids=scope),
            "returned": len(rows),
        },
    }


class EnquiryUpdateRequest(BaseModel):
    status: Literal["read", "replied", "closed"]
    reply: str | None = Field(default=None, max_length=2000)


@router.patch("/enquiries/{enquiry_id}")
def update_enquiry(
    enquiry_id: int,
    payload: EnquiryUpdateRequest,
    session: DbSession,
    current: ProviderUser,
) -> dict:
    """Progress one enquiry. An enquiry outside the caller's scope is 404.

    ``replied`` requires the reply text: the status is what the inbox shows,
    the reply is what the enquirer actually receives, and one without the
    other would be a status with nothing behind it.
    """
    scope = _scope(session, current)
    updated = EnquiryService(session).set_status(
        enquiry_id,
        status=payload.status,
        property_ids=scope,
        actor_user_id=current.user_id,
        reply=payload.reply,
    )
    return {"data": updated}


# ---------------------------------------------------------------------------
# Performance
# ---------------------------------------------------------------------------


@router.get("/performance")
def provider_performance(session: DbSession, current: ProviderUser) -> dict:
    """Listing and enquiry figures over the caller's own managed properties.

    Engagement metrics that SiteWise does not collect are returned as
    ``tracked: false`` with their reason; they are never reported as zero.
    """
    scope = _scope(session, current)
    return {
        "data": ProviderPerformanceService(session).report(
            property_ids=scope, is_agent=is_agent_role(current.role)
        )
    }


# ---------------------------------------------------------------------------
# Provider (account) verification
# ---------------------------------------------------------------------------


@router.get("/verification")
def provider_verification_status(
    session: DbSession, current: ProviderUser
) -> dict:
    """The caller's own account verification. Never a fabricated decision.

    An agent whose official invitation was accepted and whose account is
    active is verified from that evidence — this reconciles agents who
    completed onboarding before verification was synchronised with the
    invitation lifecycle. Everyone else sees exactly what the records say,
    and the reconciliation can only ever approve the caller's own row.
    """
    service = ProviderVerificationService(session)
    status = service.status_for(user_id=current.user_id, role=current.role)
    if (
        status["status"] in ("unsubmitted", "pending")
        and provider_role_for(current.role) == "agent"
    ):
        try:
            if invitation_accepted_for(_admin_service(), current.email):
                status = service.verify_from_invitation(
                    user_id=current.user_id,
                    role=current.role,
                    full_name=current.profile.full_name or "",
                    contact_phone=current.profile.phone_number or "",
                )
        except Exception:  # noqa: BLE001 - reconciliation must never void the read
            logger.exception(
                "invitation verification reconciliation failed user=%s",
                current.user_id,
            )
    return {
        "data": {
            **status,
            "requirements": [dict(item) for item in REQUIREMENTS],
        }
    }


class ProviderVerificationRequest(BaseModel):
    business_name: str = Field(min_length=2, max_length=160)
    contact_phone: str = Field(min_length=7, max_length=20)
    registration_no: str | None = Field(default=None, max_length=60)
    submission_note: str | None = Field(default=None, max_length=2000)


@router.post("/verification", status_code=201)
def submit_provider_verification(
    payload: ProviderVerificationRequest,
    session: DbSession,
    current: ProviderUser,
) -> dict:
    """Submit (or re-submit after a rejection) for administrator review.

    The resulting status is always ``pending``. No client value can approve an
    account, and re-submitting an already-approved or in-review account is
    refused with 409.
    """
    service = ProviderVerificationService(session)
    service.submit(
        user_id=current.user_id,
        role=current.role,
        business_name=payload.business_name,
        contact_phone=payload.contact_phone,
        registration_no=payload.registration_no,
        submission_note=payload.submission_note,
    )
    return {
        "data": {
            **service.status_for(user_id=current.user_id, role=current.role),
            "requirements": [dict(item) for item in REQUIREMENTS],
        }
    }


# ---------------------------------------------------------------------------
# Administrator surface (aal2 enforced by the dependency)
# ---------------------------------------------------------------------------


@staff_router.get("/verification")
def verification_queue(
    session: DbSession,
    admin: AdminUser,
    status: str | None = None,
    limit: int = 100,
    offset: int = 0,
) -> dict:
    """Provider verification submissions awaiting (or past) a decision."""
    return ProviderVerificationService(session).queue(
        status=status, limit=limit, offset=offset
    )


class VerificationDecisionRequest(BaseModel):
    decision: Literal["approve", "reject"]
    note: str | None = Field(default=None, max_length=2000)


@staff_router.post("/{user_id}/verification/decision")
def decide_verification(
    user_id: str,
    payload: VerificationDecisionRequest,
    session: DbSession,
    admin: AdminUser,
) -> dict:
    """Approve or reject ONE submission. Requires administrator + ``aal2``."""
    import uuid as _uuid

    try:
        subject = _uuid.UUID(user_id)
    except ValueError as exc:
        raise HTTPException(
            status_code=422, detail="user_id must be a UUID."
        ) from exc
    updated = ProviderVerificationService(session).decide(
        user_id=subject,
        decision=payload.decision,
        note=payload.note,
        admin_user_id=admin.user_id,
    )
    return {"data": updated}


# ---------------------------------------------------------------------------
# Enquiry creation — by the prospective tenant, not the provider
# ---------------------------------------------------------------------------


class EnquiryRequest(BaseModel):
    message: str = Field(min_length=10, max_length=2000)
    contact_name: str | None = Field(default=None, max_length=160)
    contact_email: str | None = Field(default=None, max_length=255)


@enquirer_router.post("/listings/{property_id}/enquiries", status_code=201)
def create_enquiry(
    property_id: int,
    payload: EnquiryRequest,
    session: DbSession,
    current: EnquirerUser,
) -> dict:
    """Ask a question about one published listing.

    The enquirer's identity is the verified session; name and email default to
    the account profile and may be overridden per enquiry so a tenant can be
    reachable at a different address. Unpublished listings are 404 — the same
    answer as a listing that does not exist.
    """
    profile = current.profile
    fallback_name = (profile.full_name or "").strip() or profile.email.split("@")[0]
    created = EnquiryService(session).create(
        property_id=property_id,
        enquirer_user_id=current.user_id,
        enquirer_name=(payload.contact_name or "").strip() or fallback_name,
        enquirer_email=(payload.contact_email or "").strip() or profile.email,
        message=payload.message,
    )
    return {
        "data": {
            "id": created.get("id"),
            "property_id": property_id,
            "status": created.get("status", "new"),
        }
    }
