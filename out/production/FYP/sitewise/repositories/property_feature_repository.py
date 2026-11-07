import uuid
from typing import Optional

from sqlmodel import Session, select

from sitewise.db.models.property_feature import PropertyFeature


class PropertyFeatureRepository:
    def __init__(self, session: Session):
        self.session = session

    def create(self, feature: PropertyFeature) -> PropertyFeature:
        self.session.add(feature)
        self.session.commit()
        self.session.refresh(feature)
        return feature

    def get_by_id(self, feature_id: uuid.UUID) -> Optional[PropertyFeature]:
        return self.session.get(PropertyFeature, feature_id)

    def get_by_property_id(self, property_id: int) -> list[PropertyFeature]:
        statement = select(PropertyFeature).where(PropertyFeature.property_id == property_id)
        return list(self.session.exec(statement).all())

    def get_all(self, offset: int = 0, limit: int = 100) -> list[PropertyFeature]:
        statement = select(PropertyFeature).offset(offset).limit(limit)
        return list(self.session.exec(statement).all())

    def update(self, feature_id: uuid.UUID, data: dict) -> Optional[PropertyFeature]:
        feature = self.get_by_id(feature_id)
        if not feature:
            return None
        for key, value in data.items():
            setattr(feature, key, value)
        self.session.add(feature)
        self.session.commit()
        self.session.refresh(feature)
        return feature

    def delete(self, feature_id: uuid.UUID) -> bool:
        feature = self.get_by_id(feature_id)
        if not feature:
            return False
        self.session.delete(feature)
        self.session.commit()
        return True
