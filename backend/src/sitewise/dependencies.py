"""Authentication and authorization dependencies (presentation bridge).

Flow on every protected request:

1. ``bearer_token`` extracts the ``Authorization: Bearer <jwt>`` header
   (401 when missing or malformed).
2. The verifier validates signature / algorithm / issuer / audience / expiry
   locally against the project JWKS (401 on any failure, 503 when the key
   service is unreachable).
3. ``get_current_user`` loads - or, on first sign-in, safely provisions - the
   local application profile keyed by the verified Supabase UUID, and returns
   an :class:`AuthenticatedUser` bundling the claims and the authoritative
   local role / account status.
4. ``get_active_user`` rejects suspended accounts (403).
5. ``require_roles(...)`` factories enforce the RBAC matrices from
   :mod:`sitewise.domain.rbac` (403).

The role and account status are ALWAYS read from the local database row -
never from token metadata, which the client can influence at signup time.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Annotated, Any, Protocol

from fastapi import Depends, HTTPException, Request
from sqlmodel import Session

from sitewise.core.config import settings
from sitewise.core.exceptions import AuthError, AuthUnavailableError, ForbiddenError
from sitewise.core.security import SupabaseJWTVerifier, SupabaseUserinfoVerifier, VerifiedToken
from sitewise.db.models.user import User
from sitewise.db.session import get_db
from sitewise.domain import rbac
from sitewise.services.user_service import UserService


class TokenVerifier(Protocol):
    """Structural interface both verification adapters satisfy."""

    def verify(self, token: str) -> VerifiedToken: ...


_verifier: TokenVerifier | None = None


def get_jwt_verifier() -> TokenVerifier:
    """Build (once) the token verifier from configuration.

    Primary path: local verification against the project JWKS (asymmetric
    ES256 on the verified project). Fallback path: ``/auth/v1/user`` - used
    only when the project publishes no JWKS keys (legacy symmetric signing).
    """
    global _verifier
    if _verifier is None:
        if settings.supabase_jwks_url:
            _verifier = SupabaseJWTVerifier(
                jwks_url=settings.supabase_jwks_url,
                issuer=settings.supabase_issuer,
                audiences=settings.jwt_audience_list,
                cache_seconds=settings.supabase_jwks_cache_seconds,
                leeway=settings.supabase_jwt_leeway,
            )
        elif settings.supabase_url and settings.supabase_publishable_key:
            # Legacy symmetric signing: validate via the auth server itself.
            _verifier = SupabaseUserinfoVerifier(
                base_url=settings.supabase_url,
                publishable_key=settings.supabase_publishable_key,
            )
        else:
            raise AuthUnavailableError(
                "Supabase authentication is not configured (missing JWKS URL or "
                "project credentials)."
            )
    return _verifier


def bearer_token(request: Request) -> str:
    """Extract the bearer token from the Authorization header (401 if absent)."""
    header = request.headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise AuthError("Sign in to continue.")
    return token.strip()


@dataclass
class AuthenticatedUser:
    """The verified Supabase identity plus its authoritative local profile."""

    token: VerifiedToken
    profile: User

    @property
    def user_id(self) -> uuid.UUID:
        return self.profile.user_id

    @property
    def role(self) -> str:
        return self.profile.role

    @property
    def account_status(self) -> str:
        return self.profile.account_status

    @property
    def email(self) -> str:
        return self.profile.email

    @property
    def assurance_level(self) -> str | None:
        """Verified authentication assurance level from the ``aal`` claim.

        Supabase issues ``aal1`` for password-only sessions and ``aal2``
        once a verified MFA factor has been used in this session. This is a
        server-verified claim on the signed token - never a frontend flag.
        """
        value = self.token.claims.get("aal")
        return str(value) if value else None

    @property
    def amr(self) -> list[Any]:
        """Authentication method references for the current session."""
        value = self.token.claims.get("amr")
        return value if isinstance(value, list) else []


def get_current_user(
    token: Annotated[str, Depends(bearer_token)],
    session: Annotated[Session, Depends(get_db)],
) -> AuthenticatedUser:
    verifier = get_jwt_verifier()
    verified = verifier.verify(token)
    if not verified.email:
        raise AuthError("The token does not carry an email identity.")
    try:
        subject = uuid.UUID(verified.subject)
    except ValueError as exc:
        raise AuthError("The token subject is not a valid identity.") from exc
    service = UserService(session)
    profile = service.get_or_sync_current(
        user_id=subject,
        email=verified.email,
        full_name=(verified.claims.get("user_metadata") or {}).get("full_name"),
        email_verified=verified.email_verified,
    )
    return AuthenticatedUser(token=verified, profile=profile)


def get_active_user(
    user: Annotated[AuthenticatedUser, Depends(get_current_user)],
) -> AuthenticatedUser:
    if user.account_status == rbac.STATUS_SUSPENDED:
        raise ForbiddenError("This account is suspended.")
    if user.account_status != rbac.STATUS_ACTIVE:
        # "pending" or any future non-active state: not yet usable.
        raise ForbiddenError("This account is not active yet.")
    return user


def require_roles(*allowed):
    """Dependency factory enforcing the domain RBAC matrices.

    Accepts either a flat sequence of role names (the common case) or nested
    tuples, which are flattened, so both ``require_roles("a", "b")`` and
    ``require_roles(("a", "b"))`` work. Legacy role aliases stored in existing
    records are normalised before the check.
    """

    flat: list[str] = []
    for item in allowed:
        if isinstance(item, str):
            flat.append(item)
        else:
            flat.extend(item)

    def dependency(
        user: Annotated[AuthenticatedUser, Depends(get_active_user)],
    ) -> AuthenticatedUser:
        if not rbac.has_role(user.role, tuple(flat)):
            raise ForbiddenError("You do not have permission to perform this action.")
        # An administrator acting through a broadly scoped dependency still
        # requires the same signed AAL2 assurance as an admin-only endpoint.
        if (rbac.canonical_role(user.role) == rbac.ROLE_ADMIN
                and user.assurance_level != rbac.REQUIRED_STAFF_AAL):
            raise _staff_mfa_required()
        return user

    return dependency


def _staff_mfa_required() -> HTTPException:
    """Structured 403 the frontend can branch on for the MFA screens."""
    return HTTPException(
        status_code=403,
        detail={
            "code": "staff_mfa_required",
            "message": (
                "Staff access requires completed multi-factor authentication "
                "(aal2). Sign in again and complete the TOTP challenge or "
                "enrollment."
            ),
        },
    )


def get_staff_user(
    user: Annotated[AuthenticatedUser, Depends(get_active_user)],
) -> AuthenticatedUser:
    """Staff portal authorization: active account + staff role + ``aal2``.

    Enforced server-side from the signed token's verified claims - a plain
    password session (``aal1``, or a token without an ``aal`` claim) never
    passes, and frontend flags are never consulted.
    """
    if not rbac.is_staff(user.role):
        raise ForbiddenError("Staff access requires an agent or administrator account.")
    if user.assurance_level != rbac.REQUIRED_STAFF_AAL:
        raise _staff_mfa_required()
    return user


def require_agent_mfa(
    user: Annotated[AuthenticatedUser, Depends(get_staff_user)],
) -> AuthenticatedUser:
    """Agent-scoped staff action (administrators may also act here)."""
    if not rbac.has_role(user.role, (rbac.ROLE_AGENT, rbac.ROLE_ADMIN)):
        raise ForbiddenError("This action requires an agent account.")
    return user


def require_admin_mfa(
    user: Annotated[AuthenticatedUser, Depends(get_staff_user)],
) -> AuthenticatedUser:
    """Administrator-scoped staff action (role change administration)."""
    if not rbac.can_administer_users(user.role):
        raise ForbiddenError("This action requires an administrator account.")
    return user


def require_entrepreneur(
    user: Annotated[AuthenticatedUser, Depends(get_active_user)],
) -> AuthenticatedUser:
    if not rbac.has_role(user.role, (rbac.ROLE_ENTREPRENEUR, rbac.ROLE_ADMIN)):
        raise ForbiddenError("This action requires an entrepreneur account.")
    if (rbac.canonical_role(user.role) == rbac.ROLE_ADMIN
            and user.assurance_level != rbac.REQUIRED_STAFF_AAL):
        raise _staff_mfa_required()
    return user


def require_property_owner(
    user: Annotated[AuthenticatedUser, Depends(get_active_user)],
) -> AuthenticatedUser:
    """Property management. Ownership is a relationship on the property row,
    so entrepreneurs manage the properties they own; administrators act
    administratively. (The legacy ``property_owner`` role folded into
    ``entrepreneur``.)"""
    if not rbac.can_manage_properties(user.role):
        raise ForbiddenError("This action requires an entrepreneur (property owner) account.")
    if (rbac.canonical_role(user.role) == rbac.ROLE_ADMIN
            and user.assurance_level != rbac.REQUIRED_STAFF_AAL):
        raise _staff_mfa_required()
    return user


from sitewise.db.session import get_db
from sitewise.repositories.m2_repository import (
    SqlModelM2Repository,
)
from sitewise.services.m2_service import M2Service
from sitewise.services.bdj_service import BDJService
from sitewise.services.confirmation_service import ConfirmationService
from sitewise.db.analytics_session import get_analytics_db
from sitewise.services.assessment_service import AssessmentService
from sitewise.services.project1_read_service import Project1ReadService


def get_m2_service(
    session: Annotated[Session, Depends(get_db)],
) -> M2Service:
    repository = SqlModelM2Repository(session)
    return M2Service(repository=repository)


def get_bdj_service(
    session: Annotated[Session, Depends(get_db)],
) -> BDJService:
    return BDJService(repository=SqlModelM2Repository(session))


def get_confirmation_service(
    session: Annotated[Session, Depends(get_db)],
) -> ConfirmationService:
    return ConfirmationService(repository=SqlModelM2Repository(session))


def get_project1_read_service(
    session: Annotated[Session, Depends(get_db)],
    analytics: Annotated[Session, Depends(get_analytics_db)],
) -> Project1ReadService:
    return Project1ReadService(AssessmentService(session, analytics))

# Convenience aliases for router signatures.
CurrentUser = Annotated[AuthenticatedUser, Depends(get_current_user)]
ActiveUser = Annotated[AuthenticatedUser, Depends(get_active_user)]
StaffUser = Annotated[AuthenticatedUser, Depends(get_staff_user)]
AgentMfaUser = Annotated[AuthenticatedUser, Depends(require_agent_mfa)]
AdminMfaUser = Annotated[AuthenticatedUser, Depends(require_admin_mfa)]
