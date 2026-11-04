"""Identity endpoints for Supabase-authenticated users.

Registration and login are performed by the frontend through the Supabase
SDK - this router deliberately does NOT duplicate them (the frontend obtains
its access token from Supabase and sends it as a bearer token). ``/auth/me``
is the bridge: it verifies the token, provisions the local profile on first
sign-in, and reports the authoritative role and account status.
"""

import uuid

from fastapi import APIRouter

from sitewise.dependencies import ActiveUser, AuthenticatedUser, CurrentUser

router = APIRouter()


def _identity_payload(user: AuthenticatedUser) -> dict:
    profile = user.profile
    return {
        "user_id": str(profile.user_id),
        "email": profile.email,
        "full_name": profile.full_name,
        "phone_number": profile.phone_number,
        "profile_picture_url": profile.profile_picture_url,
        "role": profile.role,
        "account_status": profile.account_status,
        "email_verified": profile.email_verified,
        "created_at": profile.created_at.isoformat() if profile.created_at else None,
        "token_subject": user.token.subject,
        "token_session_id": user.token.session_id,
    }


@router.get("/me")
def whoami(user: CurrentUser) -> dict:
    """Verified identity + authoritative local profile (provisions on first call)."""
    return _identity_payload(user)


@router.get("/session")
def session_info(user: ActiveUser) -> dict:
    """Lightweight liveness/role probe used by the frontend after OAuth redirects."""
    return {
        "authenticated": True,
        "user_id": str(uuid.UUID(str(user.user_id))),
        "role": user.role,
        "account_status": user.account_status,
    }
