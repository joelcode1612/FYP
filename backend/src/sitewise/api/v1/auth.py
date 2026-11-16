"""Identity endpoints for Supabase-authenticated users.

Registration and login are performed by the frontend through the Supabase
SDK - this router deliberately does NOT duplicate them (the frontend obtains
its access token from Supabase and sends it as a bearer token). ``/auth/me``
is the bridge: it verifies the token, provisions the local profile on first
sign-in, and reports the authoritative role and account status.

``/auth/register`` is the one exception, and it is NOT a login endpoint. The
live project keeps ``mailer_autoconfirm = false`` globally, so a normal
``/auth/v1/signup`` gives a new Entrepreneur no session at all and waits for
an emailed link. Rather than disable confirmation project-wide (which would
also change staff invitations and OAuth), the trusted backend creates the
self-service identity already email-confirmed through the documented GoTrue
admin API and returns NO session. The client then performs a real
``signInWithPassword`` and ``/auth/me`` provisions the profile from the
verified bearer token. See ``core/config.py::public_registration_autoconfirm``
for the kill switch that keeps the project policy fully in force.
"""

import re
import time
import uuid
from collections import defaultdict
from threading import Lock

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, ConfigDict, Field

from sitewise.core.config import settings
from sitewise.core.exceptions import (
    AuthUnavailableError,
    ConflictError,
    ValidationError,
)
from sitewise.core.supabase_admin import SupabaseAdminService, get_admin_service
from sitewise.dependencies import ActiveUser, AuthenticatedUser, CurrentUser
from sitewise.domain import rbac

router = APIRouter()

_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_LETTER_RE = re.compile(r"[A-Za-z]")
_DIGIT_RE = re.compile(r"[0-9]")

# The two non-authoritative onboarding preferences the mobile funnel offers.
# Anything else is dropped, never stored and never interpreted as a role.
_ACCOUNT_PURPOSES = frozenset({"entrepreneur", "listing_provider"})


def _identity_payload(user: AuthenticatedUser) -> dict:
    profile = user.profile
    return {
        "user_id": str(profile.user_id),
        "email": profile.email,
        "full_name": profile.full_name,
        "phone_number": profile.phone_number,
        "profile_picture_url": profile.profile_picture_url,
        # Canonical four-role model (legacy aliases normalised on read) so the
        # client never has to special-case ``administrator`` / ``property_owner``.
        # ``property_owner`` now resolves to ``owner``, not ``entrepreneur``: an
        # owner folded into an entrepreneur would reach the client with no
        # property authority at all.
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
        "assurance_level": user.assurance_level,
    }


# ---------------------------------------------------------------------------
# Public self-service registration
# ---------------------------------------------------------------------------

class EntrepreneurRegistration(BaseModel):
    """The ONLY self-service registration shape. Extra fields are forbidden.

    A client cannot smuggle ``role``, ``account_status``, ``email_verified``
    or any privilege into this request: the authoritative profile is created
    by ``UserService.get_or_sync_current`` from the verified token on
    ``/auth/me``, where the role is always ``entrepreneur``.
    """

    model_config = ConfigDict(extra="forbid")

    email: str = Field(max_length=254)
    password: str = Field(max_length=128)
    full_name: str | None = Field(default=None, max_length=120)
    account_purpose: str | None = Field(default=None, max_length=40)
    accept_terms: bool = False


def _validate_registration(payload: EntrepreneurRegistration) -> tuple[str, str, str | None, str | None]:
    email = payload.email.strip().lower()
    if not _EMAIL_RE.match(email):
        raise ValidationError("Please enter a valid email address.")
    # Mirrors the mobile SignupPasswordPolicy exactly (8 chars + letter +
    # number) so the on-screen indicators can never disagree with the server.
    password = payload.password
    if (
        len(password) < 8
        or len(password) > 128
        or not _LETTER_RE.search(password)
        or not _DIGIT_RE.search(password)
    ):
        raise ValidationError(
            "Your password must be at least 8 characters and include a letter "
            "and a number."
        )
    name: str | None = None
    if payload.full_name is not None:
        candidate = payload.full_name.strip()
        if candidate and len(candidate) < 2:
            raise ValidationError("Please enter your full name.")
        name = candidate or None
    if not payload.accept_terms:
        raise ValidationError(
            "Please agree to the Terms of Service and Privacy Policy."
        )
    purpose = payload.account_purpose
    if purpose not in _ACCOUNT_PURPOSES:
        purpose = None
    return email, password, name, purpose


# A small in-process guard for a PUBLIC endpoint that holds the service key.
# Supabase's own /signup has project-level rate limiting; this endpoint must
# not become a cheaper way around it. Bounded to one process - deploy behind
# the platform's edge limit as well. Exposed for tests.
_RATE_WINDOW_SECONDS = 60.0
_RATE_MAX_ATTEMPTS = 10
_rate_lock = Lock()
_rate_attempts: dict[str, list[float]] = defaultdict(list)


def reset_registration_throttle() -> None:
    """Test seam: clear the in-process registration rate-limit counters."""
    with _rate_lock:
        _rate_attempts.clear()


def _throttle(key: str) -> None:
    now = time.monotonic()
    with _rate_lock:
        recent = [t for t in _rate_attempts[key] if now - t < _RATE_WINDOW_SECONDS]
        if len(recent) >= _RATE_MAX_ATTEMPTS:
            raise ConflictError(
                "Too many registration attempts. Please try again in a minute."
            )
        recent.append(now)
        _rate_attempts[key] = recent
        if len(_rate_attempts) > 512:
            for stale in [
                k for k, times in _rate_attempts.items()
                if not times or now - times[-1] >= _RATE_WINDOW_SECONDS
            ]:
                _rate_attempts.pop(stale, None)


@router.post("/register", status_code=201)
def register_entrepreneur(
    payload: EntrepreneurRegistration,
    request: Request,
    admin: SupabaseAdminService = Depends(get_admin_service),
) -> dict:
    """Create a confirmed public identity; issue NO session and NO role.

    The response deliberately contains no token. The client must perform a
    real password sign-in afterwards, and the canonical ``entrepreneur`` role
    is assigned by the trusted ``/auth/me`` profile provisioning - never here.
    """
    if not settings.public_registration_autoconfirm:
        # Fail closed when the deployment chooses to keep global email
        # confirmation in force. The client reports this as a configuration
        # dependency instead of pretending the account is authenticated.
        raise AuthUnavailableError(
            "Email confirmation is required by this project's authentication "
            "policy. Enable auto-confirmation for public registration or "
            "contact SiteWise support."
        )
    email, password, name, purpose = _validate_registration(payload)
    client_host = request.client.host if request.client else "unknown"
    _throttle(f"{client_host}|{email}")
    created = admin.create_confirmed_entrepreneur(
        email=email,
        password=password,
        full_name=name,
        account_purpose=purpose,
    )
    # No local profile is written from an unauthenticated request. The first
    # verified ``/auth/me`` creates it exactly once, keyed by this Supabase
    # UUID, with role=entrepreneur and account_status=active.
    return {
        "registered": True,
        "user_id": created["id"],
        "email": email,
        "session_issued": False,
    }
