import uuid
from typing import Optional

from sqlmodel import Session

from sitewise.core.exceptions import ForbiddenActionError
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
