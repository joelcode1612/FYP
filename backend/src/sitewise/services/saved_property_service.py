"""Saved (favourite) properties for one account.

The router used to build :class:`FavouriteRepository` and
:class:`CatalogRepository` itself and run a ``select`` for the delete-by-id
ownership check. All of that is here instead, over a
:class:`~sitewise.services.ports.favourite_repository_port.FavouriteRepositoryPort`
plus the catalogue-existence callable the composition root binds to the live
catalogue.

Behaviour is unchanged, including the two rules the UI depends on:

* saving is idempotent - an already-saved id returns the existing row and the
  handler answers 200 instead of creating a duplicate;
* a saved id that no longer matches any catalogue row is reported as
  ``unresolved``, never silently pruned, because a GET must not delete data a
  temporary import glitch made look missing.

Status codes stay with the transport layer: this class reports what it found,
not what HTTP should say about it.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Any

from sitewise.db.models.favourite_property import FavouriteProperty
from sitewise.services.ports.favourite_repository_port import (
    FavouriteRepositoryPort,
)


class SavedPropertyService:
    def __init__(
        self,
        favourites: FavouriteRepositoryPort,
        catalogue_exists: Callable[[str], bool],
    ):
        self.favourites = favourites
        self.catalogue_exists = catalogue_exists

    def exists_in_catalogue(self, property_ref: str) -> bool:
        return self.catalogue_exists(property_ref)

    def list_for_user(self, user_id: uuid.UUID) -> list[Any]:
        return self.favourites.get_by_user_id(user_id)

    def unresolved_refs(self, rows: list[Any]) -> list[str]:
        """Saved ids with no current catalogue row, in the stored order."""
        return [
            row.property_id for row in rows if not self.catalogue_exists(row.property_id)
        ]

    def save(self, user_id: uuid.UUID, property_ref: str) -> tuple[Any, bool]:
        """Return ``(row, created)`` - ``created`` is False for a repeat save."""
        existing = self.favourites.get_by_user_and_property(user_id, property_ref)
        if existing is not None:
            return existing, False
        return (
            self.favourites.create(
                FavouriteProperty(
                    user_id=user_id,
                    property_id=property_ref,
                    created_at=datetime.now(UTC),
                )
            ),
            True,
        )

    def find(self, favorite_id: uuid.UUID) -> Any | None:
        """One row by id, so the caller can check ownership before deleting."""
        return self.favourites.get_by_id(favorite_id)

    def remove_by_id(self, favorite_id: uuid.UUID) -> bool:
        return self.favourites.delete(favorite_id)

    def remove_by_user_and_property(self, user_id: uuid.UUID, property_ref: str) -> bool:
        return self.favourites.delete_by_user_and_property(user_id, property_ref)
