"""User profile routes.

Self-service endpoints (``/users/me*``) operate on the authenticated identity;
administrative endpoints operate on any user but require the administrator
role. Registration is NOT exposed here: identities are created in Supabase
Auth (the frontend uses the Supabase SDK) and local profiles are provisioned
on the first authenticated request.
"""

import logging
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlmodel import Session

from sitewise.api.v1.staff import _record_audit
from sitewise.core.exceptions import ForbiddenActionError
from sitewise.core.supabase_admin import SupabaseAdminError, get_admin_service
from sitewise.db.session import get_db
from sitewise.dependencies import (
    ActiveUser,
    AuthenticatedUser,
    CurrentUser,
    require_admin_mfa,
)
from sitewise.domain import rbac
from sitewise.services.user_service import UserService

router = APIRouter()

logger = logging.getLogger("sitewise.users")


def _profile_payload(user, listing_count: int | None = None) -> dict:
    payload = {
        "user_id": str(user.user_id),
        "email": user.email,
        "full_name": user.full_name,
        "phone_number": user.phone_number,
        "profile_picture_url": user.profile_picture_url,
        "role": user.role,
        "account_status": user.account_status,
        "email_verified": user.email_verified,
        "last_login": user.last_login.isoformat() if user.last_login else None,
        "created_at": user.created_at.isoformat() if user.created_at else None,
        "updated_at": user.updated_at.isoformat() if user.updated_at else None,
    }
    # Absent means "not computed", which the UI renders as unknown. A computed
    # zero is a real answer and is always sent.
    if listing_count is not None:
        payload["listing_count"] = listing_count
    return payload


# ---------------------------------------------------------------------------
# Self-service (authenticated identity)
# ---------------------------------------------------------------------------


@router.get("/me")
def get_own_profile(user: CurrentUser) -> dict:
    return _profile_payload(user.profile)


@router.get("/me/status")
def get_own_status(user: ActiveUser) -> dict:
    """Authoritative account status and role for the authenticated caller."""
    return {
        "user_id": str(user.user_id),
        "role": user.role,
        "account_status": user.account_status,
        "email_verified": user.profile.email_verified,
    }


@router.patch("/me")
def update_own_profile(
    data: dict,
    user: CurrentUser,
    session: Session = Depends(get_db),
) -> dict:
    """Update permitted personal fields.

    Role, account status, email verification and identity columns are
    authoritative server-side values; attempting to change them returns 403
    rather than being silently ignored.
    """
    try:
        updated = UserService(session).update_own_profile(user.user_id, data)
    except ForbiddenActionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    if updated is None:
        raise HTTPException(status_code=404, detail="User not found")
    return _profile_payload(updated)


# ---------------------------------------------------------------------------
# Administration (administrator role required)
# ---------------------------------------------------------------------------


@router.get("/")
def list_users(
    offset: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=200),
    session: Session = Depends(get_db),
    _: AuthenticatedUser = Depends(require_admin_mfa),
) -> list[dict]:
    service = UserService(session)
    # One grouped query for the whole page, never one query per account.
    counts = service.listing_counts_by_owner()
    return [
        _profile_payload(u, counts.get(u.user_id, 0))
        for u in service.list_users(offset, limit)
    ]


@router.get("/{user_id}")
def get_user(
    user_id: uuid.UUID,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_admin_mfa),
) -> dict:
    service = UserService(session)
    target = service.get_user(user_id)
    if not target:
        raise HTTPException(status_code=404, detail="User not found")
    return _profile_payload(target, service.listing_count_for(user_id))


@router.patch("/{user_id}")
def admin_update_user(
    user_id: uuid.UUID,
    data: dict,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_admin_mfa),
) -> dict:
    """Administrative update (role / account status management).

    Administrator-submitted changes skip the self-service field filter but
    are still validated against the domain role/status vocabularies.

    The authoritative Supabase ``public.users`` row and the local enforcement
    mirror live in two databases, so the write cannot be atomic. The order is
    therefore fixed and the failure modes are explicit:

    1. Authoritative row first. If it fails, nothing local is touched and the
       request fails closed - a role change that only half-exists would let an
       account keep privileges the administrator just removed.
    2. Local mirror second. If this fails after step 1 succeeded, the response
       is an explicit partial result naming both states. Recovery is to retry
       the same change: the write is idempotent, so retrying converges without
       overwriting or deleting anybody's record.
    3. Audit last. A failed audit write never masks the applied change, and is
       reported as ``audit_recorded: false`` rather than silently claimed.
       ``null`` means no role/status change happened, so no event was due.
    """
    if "role" in data and not rbac.is_valid_role(data["role"]):
        raise HTTPException(status_code=422, detail="Unknown role value.")
    if "account_status" in data and not rbac.is_valid_status(data["account_status"]):
        raise HTTPException(status_code=422, detail="Unknown account status value.")

    service = UserService(session)
    target = service.get_user(user_id)
    if not target:
        raise HTTPException(status_code=404, detail="User not found")
    previous_role = rbac.canonical_role(target.role)
    previous_status = target.account_status
    email = target.email

    # Canonicalise any legacy role value before writing (new rows never use
    # legacy values).
    write_data = dict(data)
    if "role" in write_data:
        write_data["role"] = rbac.canonical_role(write_data["role"])

    admin = get_admin_service()  # AuthUnavailableError -> 503, nothing applied.
    try:
        admin.update_identity_profile(user_id, write_data)
    except SupabaseAdminError as exc:
        raise HTTPException(
            status_code=502,
            detail=(
                "The identity service rejected this change, so no change was "
                f"applied to the account. Reason: {exc}"
            ),
        ) from exc

    try:
        updated = service.update_user(user_id, write_data)
    except Exception as exc:
        logger.exception("local mirror update failed after identity sync for %s", user_id)
        updated = None
        mirror_error = str(exc)
    else:
        mirror_error = None if updated else "The local account row no longer exists."

    if updated is None:
        # The authoritative row already carries the new values. Say so, and
        # record the partial application instead of pretending it did not happen.
        partial_role = write_data.get("role", previous_role)
        partial_status = write_data.get("account_status", previous_status)
        if partial_role != previous_role or partial_status != previous_status:
            _record_audit(
                admin,
                affected_user_id=user_id,
                affected_email=email,
                performed_by_user_id=current.user_id,
                performed_by_email=current.email,
                action="role.changed" if partial_role != previous_role else "status.changed",
                previous_role=previous_role,
                new_role=partial_role,
                previous_status=previous_status,
                new_status=partial_status,
                details={
                    "identity_synced": True,
                    "local_mirror_updated": False,
                    "consistency": "partial",
                },
            )
        raise HTTPException(
            status_code=502,
            detail=(
                "Partially applied: the authoritative identity record was "
                "updated, but the local access-control record was not "
                f"({mirror_error}). The account may still be enforced under its "
                "previous role or status. Submit the same change again to "
                "finish it - no data was deleted or overwritten."
            ),
        )

    new_role = rbac.canonical_role(updated.role)
    new_status = updated.account_status
    audit_recorded: bool | None = None
    if new_role != previous_role or new_status != previous_status:
        audit_recorded = _record_audit(
            admin,
            affected_user_id=user_id,
            affected_email=updated.email,
            performed_by_user_id=current.user_id,
            performed_by_email=current.email,
            action="role.changed" if new_role != previous_role else "status.changed",
            previous_role=previous_role,
            new_role=new_role,
            previous_status=previous_status,
            new_status=new_status,
            details={"identity_synced": True, "local_mirror_updated": True},
        )

    return {
        **_profile_payload(updated, service.listing_count_for(user_id)),
        "identity_synced": True,
        "audit_recorded": audit_recorded,
    }


@router.delete("/{user_id}", status_code=204, response_model=None)
def delete_user(
    user_id: uuid.UUID,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_admin_mfa),
) -> None:
    if user_id == current.user_id:
        raise HTTPException(status_code=422, detail="Administrators cannot delete themselves.")
    if not UserService(session).delete_user(user_id):
        raise HTTPException(status_code=404, detail="User not found")
    return None


@router.post("/", status_code=201, include_in_schema=False)
def create_user_deprecated() -> dict:
    """Disabled: identity creation belongs to Supabase Auth.

    Kept as an explicit 410 so stale clients get a clear signal instead of a
    404/405, and so the open user-creation hole from the previous revision is
    closed rather than merely hidden.
    """
    raise HTTPException(
        status_code=410,
        detail=(
            "Direct user creation is disabled. Register through Supabase Auth; "
            "the local profile is provisioned on first authenticated request."
        ),
    )
