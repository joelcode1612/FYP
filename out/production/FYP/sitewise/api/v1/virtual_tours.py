import uuid

from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session

from sitewise.db.session import get_db
from sitewise.db.models.virtual_tour import VirtualTour
from sitewise.dependencies import AuthenticatedUser, require_property_owner
from sitewise.services.virtual_tour_service import VirtualTourService

router = APIRouter()


@router.get("/property/{property_id}")
def list_tours_by_property(property_id: int, session: Session = Depends(get_db)):
    return VirtualTourService(session).get_by_property(property_id)


@router.get("/{tour_id}")
def get_tour(tour_id: uuid.UUID, session: Session = Depends(get_db)):
    tour = VirtualTourService(session).get(tour_id)
    if not tour:
        raise HTTPException(status_code=404, detail="Tour not found")
    return tour


@router.post("/", status_code=201)
def create_tour(
    tour: VirtualTour,
    session: Session = Depends(get_db),
    _: AuthenticatedUser = Depends(require_property_owner),
):
    return VirtualTourService(session).create(tour)


@router.patch("/{tour_id}")
def update_tour(
    tour_id: uuid.UUID,
    data: dict,
    session: Session = Depends(get_db),
    _: AuthenticatedUser = Depends(require_property_owner),
):
    result = VirtualTourService(session).update(tour_id, data)
    if not result:
        raise HTTPException(status_code=404, detail="Tour not found")
    return result


@router.delete("/{tour_id}", status_code=204)
def delete_tour(
    tour_id: uuid.UUID,
    session: Session = Depends(get_db),
    _: AuthenticatedUser = Depends(require_property_owner),
):
    ok = VirtualTourService(session).delete(tour_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Tour not found")
    return None
