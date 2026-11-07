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
from sitewise.domain import rbac

router = APIRouter()


def _identity_payload(user: AuthenticatedUser) -> dict:
    profile = user.profile
    return {
        "user_id": str(profile.user_id),
        "email": profile.email,
        "full_name": profile.full_name,
        "phone_number": profile.phone_number,
        "profile_picture_url": profile.profile_picture_url,
        # Canonical three-role model (legacy aliases normalised on read) so the
        # client never has to special-case ``administrator`` / ``property_owner``.
        "role": rbac.canonical_role(profile.role) or profile.role,
        "account_status": profile.account_status,
        "email_verified": profile.email_verified,
        # Server-verified assurance level off the signed token's ``aal`` claim.
        # Surfaced read-only so the frontend can route to the MFA screens; it is
        # never an authorization input - protected staff routes re-check ``aal2``
        # server-side from the token, not from this echoed value.
        "assurance_level": user.assurance_level,
        "created_at": profile.created_at.isoformat() if profile.created_at else None,
        "token_subject": user.token.subject,
        "token_session_id": user.token.session_id,
    }


@router.get("/me")
def whoami(user: CurrentUser) -> dict:
    """Verified identity + authoritative local profile (provisions on first call).

    Reachable with a password-only session (``aal1``): a signed-in user may
    always read their OWN profile and ``account_status`` so the client can show
    the right screen (pending / suspended / staff MFA). This is F7 Option A -
    status visibility is allowed, but the payload is strictly the caller's own
    profile and carries no privileged or cross-user data. Any *staff* action
    still requires ``aal2`` enforced by the ``require_*_mfa`` dependencies, so
    reading your own status here never authorizes a protected operation.
    """
    return _identity_payload(user)


@router.get("/session")
def session_info(user: ActiveUser) -> dict:
    """Lightweight liveness/role probe used by the frontend after OAuth redirects."""
    return {
        "authenticated": True,
        "user_id": str(uuid.UUID(str(user.user_id))),
        "role": rbac.canonical_role(user.role) or user.role,
        "account_status": user.account_status,
    }
