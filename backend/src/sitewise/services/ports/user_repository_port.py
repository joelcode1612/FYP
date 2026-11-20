"""Persistence contract the user/identity service is written against.

``UserService`` orchestrates the security-critical identity reconciliation
(token subject vs. authoritative profile row vs. the local mirror) and the
self-edit field rules. Keeping it bound to a concrete SQLModel session — as it
was while its constructor built ``UserRepository(session)`` itself — meant the
one class that decides who may hold which role could only be exercised against
a database. This port is the seam: the composition root in
``sitewise.dependencies`` binds the SQL adapter to it, and tests hand it any
object with these methods.

Deliberately a structural ``Protocol`` (like ``M2RepositoryPort``): the SQL
adapter is unchanged and satisfies it implicitly, so no behaviour moves here.
"""

from __future__ import annotations

import uuid
from typing import Protocol

from sitewise.db.models.user import User


class UserRepositoryPort(Protocol):
    """Row-level persistence for the local identity mirror."""

    def create(self, user: User) -> User: ...

    def get_by_id(self, user_id: uuid.UUID) -> User | None: ...

    def get_by_email(self, email: str) -> User | None: ...

    def get_all(self, offset: int = 0, limit: int = 100) -> list[User]: ...

    def update(self, user_id: uuid.UUID, data: dict) -> User | None: ...

    def delete(self, user_id: uuid.UUID) -> bool: ...

    def listing_counts_by_owner(self) -> dict[uuid.UUID, int]: ...

    def listing_count_for(self, owner_user_id: uuid.UUID) -> int: ...

    def get_or_create_from_supabase(
        self,
        *,
        user_id: uuid.UUID,
        email: str,
        full_name: str | None = None,
        email_verified: bool | None = None,
        role: str | None = None,
        account_status: str | None = None,
    ) -> tuple[User, bool]: ...
