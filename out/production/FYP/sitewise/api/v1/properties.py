from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session

from sitewise.core.exceptions import ForbiddenError
from sitewise.db.models.rental_property import RentalProperty
from sitewise.db.session import get_db
from sitewise.dependencies import ActiveUser, AuthenticatedUser, require_property_owner
from sitewise.domain import rbac
from sitewise.services.property_service import PropertyService

router = APIRouter()


def _assert_can_mutate(prop: RentalProperty, current: AuthenticatedUser) -> None:
    """Ownership rule: a listing may be mutated by its owner or an administrator.

    Agents manage listings only through separately authorized flows, never by
    writing arbitrary property rows (see domain/rbac.py).
    """
    if prop.user_id is None:
        # Legacy row without an owning identity: only administrators may touch it.
        if not rbac.can_administer_users(current.role):
            raise ForbiddenError("This listing has no owner assigned; it is admin-managed.")
        return
    if prop.user_id != current.user_id and not rbac.can_administer_users(current.role):
        raise ForbiddenError("You can only manage your own property listings.")


@router.get("/")
def list_properties(offset: int = 0, limit: int = 100, session: Session = Depends(get_db)):
    """Public catalogue read (browse is unauthenticated by design)."""
    return PropertyService(session).list_properties(offset, limit)


@router.get("/mine")
def list_own_properties(
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """The authenticated owner's own listings."""
    from sqlmodel import select

    rows = session.exec(
        select(RentalProperty).where(RentalProperty.user_id == current.user_id)
    ).all()
    return rows


@router.get("/{property_id}")
def get_property(property_id: int, session: Session = Depends(get_db)):
    prop = PropertyService(session).get_property(property_id)
    if not prop:
        raise HTTPException(status_code=404, detail="Property not found")
    return prop


@router.post("/", status_code=201)
def create_property(
    prop: RentalProperty,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    """Create a listing. Ownership is stamped from the verified identity."""
    prop.user_id = current.user_id
    return PropertyService(session).create_property(prop)


@router.patch("/{property_id}")
def update_property(
    property_id: int,
    data: dict,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    prop = PropertyService(session).get_property(property_id)
    if not prop:
        raise HTTPException(status_code=404, detail="Property not found")
    _assert_can_mutate(prop, current)
    # Ownership is identity-controlled; a client cannot transfer a listing.
    data.pop("user_id", None)
    result = PropertyService(session).update_property(property_id, data)
    if not result:
        raise HTTPException(status_code=404, detail="Property not found")
    return result


@router.delete("/{property_id}", status_code=204)
def delete_property(
    property_id: int,
    session: Session = Depends(get_db),
    current: AuthenticatedUser = Depends(require_property_owner),
):
    prop = PropertyService(session).get_property(property_id)
    if not prop:
        raise HTTPException(status_code=404, detail="Property not found")
    _assert_can_mutate(prop, current)
    PropertyService(session).delete_property(property_id)
    return None
