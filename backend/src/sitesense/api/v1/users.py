import uuid

from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session

from sitesense.db.session import get_db
from sitesense.db.models.user import User
from sitesense.services.user_service import UserService

router = APIRouter()


@router.get("/")
def list_users(offset: int = 0, limit: int = 100, session: Session = Depends(get_db)):
    return UserService(session).list_users(offset, limit)


@router.get("/{user_id}")
def get_user(user_id: uuid.UUID, session: Session = Depends(get_db)):
    user = UserService(session).get_user(user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return user


@router.post("/", status_code=201)
def create_user(user: User, session: Session = Depends(get_db)):
    return UserService(session).create_user(user)


@router.patch("/{user_id}")
def update_user(user_id: uuid.UUID, data: dict, session: Session = Depends(get_db)):
    result = UserService(session).update_user(user_id, data)
    if not result:
        raise HTTPException(status_code=404, detail="User not found")
    return result


@router.delete("/{user_id}", status_code=204)
def delete_user(user_id: uuid.UUID, session: Session = Depends(get_db)):
    ok = UserService(session).delete_user(user_id)
    if not ok:
        raise HTTPException(status_code=404, detail="User not found")
    return None
