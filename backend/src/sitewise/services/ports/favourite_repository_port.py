"""Contract the saved-property use-cases are written against.

``FavouriteRepository`` satisfies it implicitly. Only the operations
:class:`~sitewise.services.saved_property_service.SavedPropertyService` needs
are declared, so the router stops owning row access (it built two repositories
and ran a ``select`` itself) without the service learning about SQLModel.

Rows are typed ``Any`` on purpose: the persistence model is the adapter's
business, and a saved list is answered with whatever the repository returns,
exactly as the other read-model ports do.
"""

from __future__ import annotations

import uuid
from typing import Any, Protocol


class FavouriteRepositoryPort(Protocol):
    """Row access for one account's saved catalogue properties."""

    def create_or_get(self, fav: Any) -> tuple[Any, bool]: ...

    def get_by_id(self, favorite_id: uuid.UUID) -> Any | None: ...

    def get_by_user_id(self, user_id: uuid.UUID) -> list[Any]: ...

    def get_by_user_and_property(
        self, user_id: uuid.UUID, property_id: str
    ) -> Any | None: ...

    def delete(self, favorite_id: uuid.UUID) -> bool: ...

    def delete_by_user_and_property(self, user_id: uuid.UUID, property_id: str) -> bool: ...
