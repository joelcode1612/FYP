from typing import Optional

from sqlmodel import Session, select

from sitewise.db.models.rental_property import RentalProperty


class PropertyRepository:
    def __init__(self, session: Session):
        self.session = session

    def create(self, prop: RentalProperty) -> RentalProperty:
        self.session.add(prop)
        self.session.commit()
        self.session.refresh(prop)
        return prop

    def get_by_id(self, property_id: int) -> Optional[RentalProperty]:
        return self.session.get(RentalProperty, property_id)

    def get_all(self, offset: int = 0, limit: int = 100) -> list[RentalProperty]:
        statement = select(RentalProperty).offset(offset).limit(limit)
        return list(self.session.exec(statement).all())

    def update(self, property_id: int, data: dict) -> Optional[RentalProperty]:
        prop = self.get_by_id(property_id)
        if not prop:
            return None
        for key, value in data.items():
            setattr(prop, key, value)
        self.session.add(prop)
        self.session.commit()
        self.session.refresh(prop)
        return prop

    def delete(self, property_id: int) -> bool:
        prop = self.get_by_id(property_id)
        if not prop:
            return False
        self.session.delete(prop)
        self.session.commit()
        return True

    def get_by_user_id(self, user_id) -> list[RentalProperty]:
        statement = select(RentalProperty).where(RentalProperty.user_id == user_id)
        return list(self.session.exec(statement).all())

    def get_by_district_id(self, district_id: str) -> list[RentalProperty]:
        statement = select(RentalProperty).where(RentalProperty.district_id == district_id)
        return list(self.session.exec(statement).all())
