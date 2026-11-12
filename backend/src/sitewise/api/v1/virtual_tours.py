import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import ForbiddenError
from sitewise.db.models.virtual_tour import VirtualTour
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, require_property_owner
from sitewise.domain import rbac
from sitewise.services.virtual_tour_service import VirtualTourService

router = APIRouter()

_MUTABLE_TOUR_FIELDS = frozenset({"url", "status"})
DbSession = Annotated[Session, Depends(get_db)]
OwnerUser = Annotated[AuthenticatedUser, Depends(require_property_owner)]


def _require_owned_listing(
    session: Session, property_id: int, current: AuthenticatedUser
) -> None:
    """Require access to the current listing represented by a tour's id.

    ``virtual_tour.property_id`` is a legacy, unbound integer after the
    retirement of ``public.property``. New tour reads must therefore resolve
    that integer against the canonical operational listing table before a
    tour is returned. Missing or unlinked legacy rows fail closed instead of
    becoming readable by any authenticated user.
    """
    row = session.execute(
        text("SELECT owner_user_id FROM fyp.rental_properties WHERE id = :pid"),
        {"pid": property_id},
    ).first()
    if row is None:
        raise HTTPException(status_code=404, detail="Property not found.")
    if rbac.can_administer_users(current.role):
        return
    if row[0] is None or str(row[0]) != str(current.user_id):
        raise ForbiddenError("You can only access tours for your own property listings.")


def _owned_tour_or_error(
    service: VirtualTourService,
    session: Session,
    tour_id: uuid.UUID,
    current: AuthenticatedUser,
) -> VirtualTour:
    """Resolve a tour and enforce ownership before any mutation."""
    tour = service.get(tour_id)
    if not tour:
        raise HTTPException(status_code=404, detail="Tour not found")
    _require_owned_listing(session, tour.property_id, current)
    return tour


def _validated_update(data: dict) -> dict:
    """Accept only the two lifecycle fields that can safely change in place.

    A virtual tour must never be reassigned to another listing through PATCH:
    that could turn a legitimate owner update into a cross-property record
    move. Keeping this allow-list next to the endpoint also prevents clients
    from setting primary keys or audit timestamps through the raw dict body.
    """
    unknown = set(data) - _MUTABLE_TOUR_FIELDS
    if unknown:
        fields = ", ".join(sorted(unknown))
        raise HTTPException(
            status_code=422,
            detail=f"Only url and status may be updated (unexpected: {fields}).",
        )
    return {key: data[key] for key in _MUTABLE_TOUR_FIELDS if key in data}


@router.get("/property/{property_id}")
def list_tours_by_property(
    property_id: int,
    session: DbSession,
    current: OwnerUser,
):
    _require_owned_listing(session, property_id, current)
    return VirtualTourService(session).get_by_property(property_id)


@router.get("/{tour_id}")
def get_tour(
    tour_id: uuid.UUID,
    session: DbSession,
    current: OwnerUser,
):
    service = VirtualTourService(session)
    return _owned_tour_or_error(service, session, tour_id, current)


@router.post("/", status_code=201)
def create_tour(
    tour: VirtualTour,
    session: DbSession,
    current: OwnerUser,
):
    _require_owned_listing(session, tour.property_id, current)
    return VirtualTourService(session).create(tour)


@router.patch("/{tour_id}")
def update_tour(
    tour_id: uuid.UUID,
    data: dict,
    session: DbSession,
    current: OwnerUser,
):
    service = VirtualTourService(session)
    _owned_tour_or_error(service, session, tour_id, current)
    return service.update(tour_id, _validated_update(data))


@router.delete("/{tour_id}", status_code=204, response_model=None)
def delete_tour(
    tour_id: uuid.UUID,
    session: DbSession,
    current: OwnerUser,
):
    service = VirtualTourService(session)
    _owned_tour_or_error(service, session, tour_id, current)
    # The authorized lookup above makes a second missing-row result a benign
    # race (for example a concurrent admin cleanup), not an authorization
    # bypass.
    service.delete(tour_id)
