from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session

from sitesense.db.session import get_db
from sitesense.db.models.rental_property import RentalProperty
from sitesense.services.property_service import PropertyService

router = APIRouter()


@router.get("/")
def list_properties(offset: int = 0, limit: int = 100, session: Session = Depends(get_db)):
    return PropertyService(session).list_properties(offset, limit)


@router.get("/{property_id}")
def get_property(property_id: int, session: Session = Depends(get_db)):
    prop = PropertyService(session).get_property(property_id)
    if not prop:
        raise HTTPException(status_code=404, detail="Property not found")
    return prop


@router.post("/", status_code=201)
def create_property(prop: RentalProperty, session: Session = Depends(get_db)):
    return PropertyService(session).create_property(prop)


@router.patch("/{property_id}")
def update_property(property_id: int, data: dict, session: Session = Depends(get_db)):
    result = PropertyService(session).update_property(property_id, data)
    if not result:
        raise HTTPException(status_code=404, detail="Property not found")
    return result


@router.delete("/{property_id}", status_code=204)
def delete_property(property_id: int, session: Session = Depends(get_db)):
    ok = PropertyService(session).delete_property(property_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Property not found")
    return None
