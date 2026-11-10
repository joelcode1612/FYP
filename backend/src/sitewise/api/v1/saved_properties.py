"""Saved (favourite) catalogue properties for the authenticated account.

``property_id`` is the catalogue's text id, validated against the live import
at write time. Saves are idempotent: saving the same property twice keeps one
row, because the ``(user_id, property_id)`` unique constraint backs the rule
the UI also follows.

Ownership comes from the verified token everywhere: a client cannot read or
change another account's list, and the only cross-account read is the
administrator route below.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel
from sqlmodel import Session, select

from sitewise.db.models.favourite_property import FavouriteProperty
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, get_active_user
from sitewise.domain import rbac
from sitewise.repositories.catalog_repository import CatalogRepository
from sitewise.repositories.favourite_repository import FavouriteRepository

router = APIRouter()

AppSession = Annotated[Session, Depends(get_db)]
ActiveIdentity = Annotated[AuthenticatedUser, Depends(get_active_user)]


class SavePropertyRequest(BaseModel):
    """The catalogue id to save, e.g. ``EP-01051``."""

    property_ref: str


def _catalogue_exists(session: Session, property_ref: str) -> bool:
    return CatalogRepository(session).get_property(property_ref) is not None


@router.get("/me")
def list_own_saved(session: AppSession, current: ActiveIdentity) -> dict:
    """The caller's saved list, split by what still exists in the catalogue.

    ``unresolved`` lists saved ids that no longer match any catalogue row —
    properties delisted by a later import. They are reported, not deleted and
    not hidden: removal is the user's own action (and a silent prune on a GET
    would destroy data a temporary import glitch made look missing).
    """
    rows = FavouriteRepository(session).get_by_user_id(current.user_id)
    unresolved = [
        row.property_id for row in rows if not _catalogue_exists(session, row.property_id)
    ]
    return {
        "saved": [
            {
                "favorite_id": str(row.favorite_id),
                "property_ref": row.property_id,
                "created_at": row.created_at.isoformat() if row.created_at else None,
            }
            for row in rows
        ],
        "unresolved": unresolved,
    }


@router.post("/", status_code=201)
def save_property(
    body: SavePropertyRequest,
    response: Response,
    session: AppSession,
    current: ActiveIdentity,
) -> dict:
    """Save a catalogue property for the authenticated account.

    The owning user_id comes from the verified token, never the body. An id
    that is not in the catalogue is refused with 404 and writes nothing.
    Saving an already-saved id returns the existing row with 200 rather than
    creating a duplicate, so a double tap cannot create two rows.
    """
    property_ref = body.property_ref.strip()
    if not property_ref or len(property_ref) > 64:
        raise HTTPException(status_code=422, detail="A catalogue property id is required.")
    if not _catalogue_exists(session, property_ref):
        raise HTTPException(status_code=404, detail="Property not found in the catalogue.")

    def _row(row: FavouriteProperty) -> dict:
        return {
            "favorite_id": str(row.favorite_id),
            "property_ref": row.property_id,
            "created_at": row.created_at.isoformat() if row.created_at else None,
        }

    repo = FavouriteRepository(session)
    existing = repo.get_by_user_and_property(current.user_id, property_ref)
    if existing is not None:
        response.status_code = 200
        return _row(existing)
    return _row(
        repo.create(
            FavouriteProperty(
                user_id=current.user_id,
                property_id=property_ref,
                created_at=datetime.now(UTC),
            )
        )
    )


@router.delete("/me/{property_ref}", status_code=204)
def unsave_own_property(
    property_ref: str,
    session: AppSession,
    current: ActiveIdentity,
) -> None:
    """Remove one catalogue id from the caller's list.

    The lookup is scoped to the token's own user_id, so there is no path by
    which one account removes another's saved property.
    """
    deleted = FavouriteRepository(session).delete_by_user_and_property(
        current.user_id, property_ref
    )
    if not deleted:
        raise HTTPException(status_code=404, detail="Saved property not found")


@router.get("/user/{user_id}")
def list_saved(
    user_id: uuid.UUID,
    session: AppSession,
    current: ActiveIdentity,
) -> list[FavouriteProperty]:
    """Administrator read of any account's saved list.

    Ownership-scoped: another account's list returns 403 (404 would leak
    nothing here since the user id is the path key, but 403 states the rule
    clearly). Administrators may read any list.
    """
    if user_id != current.user_id and not rbac.can_read_any_user_data(current.role):
        raise HTTPException(
            status_code=403,
            detail="You can only view your own saved properties.",
        )
    return FavouriteRepository(session).get_by_user_id(user_id)


@router.delete("/{favorite_id}", status_code=204)
def unsave_property(
    favorite_id: uuid.UUID,
    session: AppSession,
    current: ActiveIdentity,
) -> None:
    """Remove a saved row by its row id. Only the owner or an administrator may do this."""
    existing = session.exec(
        select(FavouriteProperty).where(FavouriteProperty.favorite_id == favorite_id)
    ).first()
    if existing is None:
        raise HTTPException(status_code=404, detail="Saved property not found")
    if existing.user_id != current.user_id and not rbac.can_read_any_user_data(current.role):
        raise HTTPException(
            status_code=403,
            detail="You can only remove properties from your own list.",
        )
    if not FavouriteRepository(session).delete(favorite_id):
        raise HTTPException(status_code=404, detail="Saved property not found")
