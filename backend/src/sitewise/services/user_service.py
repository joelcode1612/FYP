import uuid
from typing import Optional

from sqlmodel import Session

from sitewise.core.exceptions import ConflictError, ForbiddenActionError
from sitewise.db.models.user import User
from sitewise.domain import rbac
from sitewise.repositories.user_repository import UserRepository


class UserService:
    def __init__(self, session: Session):
        self.repo = UserRepository(session)

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
    ) -> User:
        """Load the local profile for a verified Supabase identity, creating
        it on first sign-in and syncing the verification flag.

        The authoritative role/status always come from this local row - never
        from token metadata, which the client could influence at signup.
        """
        # The Supabase UUID is the identity key. An email collision with a
        # different local UUID must be reconciled by a trusted administrator,
        # not silently re-keyed or promoted on sign-in.
        collision = self.repo.get_by_email(email)
        if collision is not None and collision.user_id != user_id:
            raise ConflictError(
                "This identity conflicts with an existing profile. "
                "Contact an administrator for verified reconciliation."
            )
        user, created = self.repo.get_or_create_from_supabase(
            user_id=user_id,
            email=email,
            full_name=full_name,
            email_verified=email_verified,
        )
        if not created and email_verified is not None and user.email_verified != email_verified:
            # Verification status is owned by Supabase; mirror it, never the
            # other way around.
            user.email_verified = email_verified
            self.repo.update(user.user_id, {"email_verified": email_verified})
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
