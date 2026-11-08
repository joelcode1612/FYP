import uuid

from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session, select

from sitewise.db.models.favourite_property import FavouriteProperty
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, get_active_user
from sitewise.domain import rbac
from sitewise.repositories.favourite_repository import FavouriteRepository
from sitewise.repositories.property_repository import PropertyRepository

router = APIRouter()


@router.get("/user/{user_id}")
def list_saved(
    user_id: uuid.UUID,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(get_active_user),
):
    """List a user's saved properties.

    Ownership-scoped: users may read only their own list; administrators may
    read any list. Another user's list returns 403 (404 would leak nothing
    here since the user id is the path key, but 403 states the rule clearly).
    """
    if user_id != current.user_id and not rbac.can_read_any_user_data(current.role):
        raise HTTPException(status_code=403, detail="You can only view your own saved properties.")
    return FavouriteRepository(session).get_by_user_id(user_id)


@router.get("/me")
def list_own_saved(
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(get_active_user),
):
    """Convenience alias: the authenticated user's own saved properties."""
    return FavouriteRepository(session).get_by_user_id(current.user_id)


@router.post("/", status_code=201)
def save_property(
    fav: FavouriteProperty,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(get_active_user),
):
    """Save a property for the authenticated user.

    The owning user_id is taken from the verified identity - a client cannot
    save into someone else's list by submitting a foreign user_id.
    """
    fav.user_id = current.user_id
    # Fail early (404) when the referenced property does not exist, instead of
    # letting the FK violation surface as a 500.
    if PropertyRepository(session).get_by_id(fav.property_id) is None:
        raise HTTPException(status_code=404, detail="Property not found")
    return FavouriteRepository(session).create(fav)


@router.delete("/{favorite_id}", status_code=204)
def unsave_property(
    favorite_id: uuid.UUID,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(get_active_user),
):
    """Remove a saved property. Only the owner or an administrator may do this."""
    existing = session.exec(
        select(FavouriteProperty).where(FavouriteProperty.favorite_id == favorite_id)
    ).first()
    if existing is None:
        raise HTTPException(status_code=404, detail="Saved property not found")
    if existing.user_id != current.user_id and not rbac.can_read_any_user_data(current.role):
        raise HTTPException(
            status_code=403, detail="You can only remove properties from your own list."
        )
    if not FavouriteRepository(session).delete(favorite_id):
        raise HTTPException(status_code=404, detail="Saved property not found")
    return None
