"""User profile routes.

Self-service endpoints (``/users/me*``) operate on the authenticated identity;
administrative endpoints operate on any user but require the administrator
role. Registration is NOT exposed here: identities are created in Supabase
Auth (the frontend uses the Supabase SDK) and local profiles are provisioned
on the first authenticated request.
"""

import uuid

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlmodel import Session

from sitewise.core.exceptions import ForbiddenActionError
from sitewise.db.session import get_db
from sitewise.dependencies import (
    ActiveUser,
    AuthenticatedUser,
    CurrentUser,
    require_admin,
)
from sitewise.services.user_service import UserService

router = APIRouter()


def _profile_payload(user) -> dict:
    return {
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
    _: AuthenticatedUser = Depends(require_admin),
) -> list[dict]:
    return [_profile_payload(u) for u in UserService(session).list_users(offset, limit)]


@router.get("/{user_id}")
def get_user(
    user_id: uuid.UUID,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_admin),
) -> dict:
    target = UserService(session).get_user(user_id)
    if not target:
        raise HTTPException(status_code=404, detail="User not found")
    return _profile_payload(target)


@router.patch("/{user_id}")
def admin_update_user(
    user_id: uuid.UUID,
    data: dict,
    session: Session = Depends(get_db),
    _: AuthenticatedUser = Depends(require_admin),
) -> dict:
    """Administrative update (role / account status management).

    Administrator-submitted changes skip the self-service field filter but
    are still validated against the domain role/status vocabularies.
    """
    from sitewise.domain import rbac

    if "role" in data and not rbac.is_valid_role(data["role"]):
        raise HTTPException(status_code=422, detail="Unknown role value.")
    if "account_status" in data and not rbac.is_valid_status(data["account_status"]):
        raise HTTPException(status_code=422, detail="Unknown account status value.")
    updated = UserService(session).update_user(user_id, data)
    if not updated:
        raise HTTPException(status_code=404, detail="User not found")
    return _profile_payload(updated)


@router.delete("/{user_id}", status_code=204)
def delete_user(
    user_id: uuid.UUID,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_admin),
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
