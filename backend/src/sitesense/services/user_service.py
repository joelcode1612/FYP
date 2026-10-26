import uuid
from typing import Optional

from sqlmodel import Session

from sitesense.db.models.user import User
from sitesense.repositories.user_repository import UserRepository


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
