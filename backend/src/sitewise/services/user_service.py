import logging
import uuid
from typing import Any, Optional

from sitewise.core.exceptions import ConflictError, ForbiddenActionError
from sitewise.db.models.user import User
from sitewise.domain import rbac
from sitewise.services.ports.user_repository_port import UserRepositoryPort


logger = logging.getLogger(__name__)


class UserService:
    """Identity/profile use-cases over a persistence port.

    The repository is injected rather than constructed here so the rules that
    decide role and account-status reconciliation are exercisable without a
    database (see ``tests/test_architecture.py``).
    """

    def __init__(self, repo: UserRepositoryPort):
        self.repo = repo

    def create_user(self, user: User) -> User:
        return self.repo.create(user)

    def get_user(self, user_id: uuid.UUID) -> Optional[User]:
        return self.repo.get_by_id(user_id)

    def get_user_by_email(self, email: str) -> Optional[User]:
        return self.repo.get_by_email(email)

    def list_users(self, offset: int = 0, limit: int = 100) -> list[User]:
        return self.repo.get_all(offset, limit)

    def update_user(self, user_id: uuid.UUID, data: dict) -> Optional[User]:
        return self.repo.update(user_id, data)

    def delete_user(self, user_id: uuid.UUID) -> bool:
        return self.repo.delete(user_id)

    def listing_counts_by_owner(self) -> dict[uuid.UUID, int]:
        return self.repo.listing_counts_by_owner()

    def listing_count_for(self, owner_user_id: uuid.UUID) -> int:
        return self.repo.listing_count_for(owner_user_id)

    # ------------------------------------------------------------------
    # Supabase-backed identity handling
    # ------------------------------------------------------------------

    def get_or_sync_current(
        self,
        *,
        user_id: uuid.UUID,
        email: str,
        full_name: str | None = None,
        email_verified: bool | None = None,
        identity_profile: dict[str, Any] | None = None,
        identity_required: bool = False,
    ) -> User:
        """Load the local mirror for a verified Supabase identity.

        When an authoritative Supabase ``public.users`` row is supplied, its
        UUID, email, role and account status are the only accepted source for
        those fields. The local mirror is reconciled to that row; token
        metadata may supply a display name only. When no authoritative row is
        available the legacy token-claim path is retained for development and
        tests only, and ``identity_required=True`` fails closed instead of
        minting a default-privilege profile.
        """
        authoritative = identity_profile or {}
        profile_email = str(authoritative.get("email") or email).strip().lower()
        raw_role = authoritative.get("role")
        raw_status = authoritative.get("account_status")

        if identity_required and not authoritative:
            raise ConflictError(
                "The authoritative identity profile is unavailable. Sign in "
                "again or ask an administrator to reconcile this account."
            )

        if authoritative:
            try:
                role = rbac.canonical_role(str(raw_role))
                status = str(raw_status)
                if role is None or not rbac.is_valid_role(role):
                    raise ValueError("invalid authoritative role")
            except Exception as exc:  # defensive: bad authoritative row
                raise ConflictError(
                    "The authoritative identity profile is invalid. Contact an "
                    "administrator for verified reconciliation."
                ) from exc
            if not rbac.is_valid_status(status):
                raise ConflictError(
                    "The authoritative account status is invalid. Contact an "
                    "administrator for verified reconciliation."
                )
            claimed_uid = str(authoritative.get("user_id") or user_id)
            if claimed_uid != str(user_id):
                raise ConflictError(
                    "The authenticated identity and profile UUID differ. "
                    "Contact an administrator for verified reconciliation."
                )
        else:
            # Compatibility path: no authoritative row was read (local tests,
            # or a deployment that has not provisioned Supabase profiles).
            role = rbac.ROLE_ENTREPRENEUR
            status = rbac.STATUS_ACTIVE

        # The UUID is the identity key. An email collision with a different
        # local UUID must be reconciled by a trusted administrator, not
        # silently re-keyed or promoted on sign-in.
        collision = self.repo.get_by_email(profile_email)
        if collision is not None and collision.user_id != user_id:
            raise ConflictError(
                "This identity conflicts with an existing profile. "
                "Contact an administrator for verified reconciliation."
            )
        user, created = self.repo.get_or_create_from_supabase(
            user_id=user_id,
            email=profile_email,
            full_name=full_name,
            email_verified=email_verified,
            role=role,
            account_status=status,
        )
        changes: dict[str, Any] = {}
        if user.email.lower() != profile_email:
            changes["email"] = profile_email
        if authoritative:
            if user.role != role:
                logger.warning(
                    "Reconciled stale local role for authenticated identity %s",
                    user_id,
                )
                changes["role"] = role
            if user.account_status != status:
                logger.warning(
                    "Reconciled stale local account status for authenticated identity %s",
                    user_id,
                )
                changes["account_status"] = status
            profile_name = authoritative.get("full_name")
            if profile_name is not None and user.full_name != profile_name:
                changes["full_name"] = profile_name
            profile_phone = authoritative.get("phone_number")
            if profile_phone is not None and user.phone_number != profile_phone:
                changes["phone_number"] = profile_phone
            authoritative_verified = authoritative.get("email_verified")
            if authoritative_verified is not None:
                verified = bool(authoritative_verified)
            else:
                verified = email_verified
            if verified is not None and user.email_verified != verified:
                changes["email_verified"] = verified
        elif email_verified is not None and user.email_verified != email_verified:
            changes["email_verified"] = email_verified
        if changes:
            self.repo.update(user.user_id, changes)
            user = self.repo.get_by_id(user_id) or user
        return user

    def update_own_profile(self, user_id: uuid.UUID, data: dict) -> Optional[User]:
        """Update the caller's own profile with domain-enforced field rules.

        Attempts to touch protected fields (role, account status, email
        verification, identity columns) raise ``ForbiddenActionError`` - a
        403, never a silent ignore - so clients learn the payload is wrong.
        """
        editable, attempted_protected = rbac.filter_self_editable(data)
        if attempted_protected:
            raise ForbiddenActionError(
                "These profile fields cannot be changed: " + ", ".join(sorted(attempted_protected))
            )
        return self.repo.update(user_id, editable)

    def ensure_staff_profile(
        self,
        *,
        user_id: uuid.UUID,
        email: str,
        full_name: str | None,
        phone_number: str | None,
        role: str,
        account_status: str,
    ) -> User:
        """Create-or-update the local enforcement mirror for a provisioned
        staff account (trusted backend operation, never client-driven).

        The authoritative role/status live in the Supabase identity row; this
        mirror is what the auth dependencies read on every request.

        Identity collisions are NEVER resolved automatically using an email
        match. A staff account with a different Supabase UUID must be reviewed
        through an explicit, audited administrator recovery workflow.
        """
        role = rbac.canonical_role(role)
        if role not in rbac.STAFF_ROLES or not rbac.is_valid_status(account_status):
            raise ValueError("Invalid staff role or account status")
        existing = self.repo.get_by_id(user_id)
        collision = self.repo.get_by_email(email)
        if collision is not None and collision.user_id != user_id:
            raise ConflictError(
                "A different local identity already uses this email. "
                "Staff provisioning requires explicit identity reconciliation."
            )
        data = {
            "role": role,
            "account_status": account_status,
        }
        if full_name is not None:
            data["full_name"] = full_name
        if phone_number is not None:
            data["phone_number"] = phone_number
        if existing is not None:
            updated = self.repo.update(user_id, data)
            assert updated is not None
            return updated
        user = User(
            user_id=user_id,
            email=email,
            full_name=full_name,
            phone_number=phone_number,
            role=data["role"],
            account_status=account_status,
            email_verified=False,
        )
        return self.repo.create(user)
