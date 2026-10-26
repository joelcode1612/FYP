import uuid
from typing import Optional

from sqlmodel import Session, select

from sitesense.db.models.property_photo import PropertyPhoto


class PropertyPhotoRepository:
    def __init__(self, session: Session):
        self.session = session

    def create(self, photo: PropertyPhoto) -> PropertyPhoto:
        self.session.add(photo)
        self.session.commit()
        self.session.refresh(photo)
        return photo

    def get_by_id(self, photo_id: uuid.UUID) -> Optional[PropertyPhoto]:
        return self.session.get(PropertyPhoto, photo_id)

    def get_by_property_id(self, property_id: int) -> list[PropertyPhoto]:
        statement = select(PropertyPhoto).where(PropertyPhoto.property_id == property_id)
        return list(self.session.exec(statement).all())

    def get_all(self, offset: int = 0, limit: int = 100) -> list[PropertyPhoto]:
        statement = select(PropertyPhoto).offset(offset).limit(limit)
        return list(self.session.exec(statement).all())

    def update(self, photo_id: uuid.UUID, data: dict) -> Optional[PropertyPhoto]:
        photo = self.get_by_id(photo_id)
        if not photo:
            return None
        for key, value in data.items():
            setattr(photo, key, value)
        self.session.add(photo)
        self.session.commit()
        self.session.refresh(photo)
        return photo

    def delete(self, photo_id: uuid.UUID) -> bool:
        photo = self.get_by_id(photo_id)
        if not photo:
            return False
        self.session.delete(photo)
        self.session.commit()
        return True
