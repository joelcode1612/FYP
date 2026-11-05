import uuid
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy.exc import IntegrityError
from sqlalchemy import update as sa_update
from sqlmodel import Session, select

from sitewise.db.models.user import User
from sitewise.domain import rbac


class UserRepository:
    def __init__(self, session: Session):
        self.session = session

    def create(self, user: User) -> User:
        self.session.add(user)
        self.session.commit()
        self.session.refresh(user)
        return user

    def get_by_id(self, user_id: uuid.UUID) -> Optional[User]:
        return self.session.get(User, user_id)

    def get_by_email(self, email: str) -> Optional[User]:
        statement = select(User).where(User.email == email)
        return self.session.exec(statement).first()

    def get_all(self, offset: int = 0, limit: int = 100) -> list[User]:
        statement = select(User).offset(offset).limit(limit)
        return list(self.session.exec(statement).all())

    def update(self, user_id: uuid.UUID, data: dict) -> Optional[User]:
        user = self.get_by_id(user_id)
        if not user:
            return None
        for key, value in data.items():
            setattr(user, key, value)
        self.session.add(user)
        self.session.commit()
        self.session.refresh(user)
        return user

    def delete(self, user_id: uuid.UUID) -> bool:
        user = self.get_by_id(user_id)
        if not user:
            return False
        self.session.delete(user)
        self.session.commit()
        return True

    def rekey(self, old_user_id: uuid.UUID, new_user_id: uuid.UUID) -> None:
        """Re-key an orphaned mirror row to a new Supabase UUID.

        Used when the identity was deleted and re-created in Supabase with
        the same email: the local row keeps its history but its primary key
        follows the authoritative identity. Referencing child rows (favourites
        etc.) follow automatically via the FK.
        """
        user = self.get_by_id(old_user_id)
        if not user:
            return
        self.session.execute(
            sa_update(User).where(User.user_id == old_user_id).values(user_id=new_user_id)
        )
        self.session.commit()

    def get_or_create_from_supabase(
        self,
        *,
        user_id: uuid.UUID,
        email: str,
        full_name: str | None = None,
        email_verified: bool | None = None,
    ) -> tuple[User, bool]:
        """Return the local application user for a verified Supabase identity,
        creating it on first sight.

        The Supabase user UUID is the primary key, so identity mapping is
        1:1 by construction and duplicate profiles are impossible for the
        same identity. No password, token or refresh material is stored.
        """
        existing = self.get_by_id(user_id)
        if existing:
            return existing, False
        user = User(
            user_id=user_id,
            email=email,
            full_name=full_name,
            role=rbac.ROLE_ENTREPRENEUR,
            account_status=rbac.STATUS_ACTIVE,
            email_verified=bool(email_verified),
            last_login=datetime.now(timezone.utc),
        )
        self.session.add(user)
        try:
            self.session.commit()
        except IntegrityError:
            # A concurrent request created the same identity first: the
            # unique email / PK constraint caught it. Re-read and return.
            self.session.rollback()
            existing = self.get_by_id(user_id)
            if existing is None:
                raise
            return existing, False
        self.session.refresh(user)
        return user, True
