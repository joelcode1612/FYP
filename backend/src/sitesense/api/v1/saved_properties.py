import uuid

from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session

from sitesense.db.session import get_db
from sitesense.db.models.favourite_property import FavouriteProperty
from sitesense.repositories.favourite_repository import FavouriteRepository

router = APIRouter()


@router.get("/user/{user_id}")
def list_saved(user_id: uuid.UUID, session: Session = Depends(get_db)):
    return FavouriteRepository(session).get_by_user_id(user_id)


@router.post("/", status_code=201)
def save_property(fav: FavouriteProperty, session: Session = Depends(get_db)):
    return FavouriteRepository(session).create(fav)


@router.delete("/{favorite_id}", status_code=204)
def unsave_property(favorite_id: uuid.UUID, session: Session = Depends(get_db)):
    ok = FavouriteRepository(session).delete(favorite_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Saved property not found")
    return None
