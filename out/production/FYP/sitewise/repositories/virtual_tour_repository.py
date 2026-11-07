import uuid
from typing import Optional

from sqlmodel import Session, select

from sitewise.db.models.virtual_tour import VirtualTour


class VirtualTourRepository:
    def __init__(self, session: Session):
        self.session = session

    def create(self, tour: VirtualTour) -> VirtualTour:
        self.session.add(tour)
        self.session.commit()
        self.session.refresh(tour)
        return tour

    def get_by_id(self, tour_id: uuid.UUID) -> Optional[VirtualTour]:
        return self.session.get(VirtualTour, tour_id)

    def get_by_property_id(self, property_id: int) -> list[VirtualTour]:
        statement = select(VirtualTour).where(VirtualTour.property_id == property_id)
        return list(self.session.exec(statement).all())

    def get_all(self, offset: int = 0, limit: int = 100) -> list[VirtualTour]:
        statement = select(VirtualTour).offset(offset).limit(limit)
        return list(self.session.exec(statement).all())

    def update(self, tour_id: uuid.UUID, data: dict) -> Optional[VirtualTour]:
        tour = self.get_by_id(tour_id)
        if not tour:
            return None
        for key, value in data.items():
            setattr(tour, key, value)
        self.session.add(tour)
        self.session.commit()
        self.session.refresh(tour)
        return tour

    def delete(self, tour_id: uuid.UUID) -> bool:
        tour = self.get_by_id(tour_id)
        if not tour:
            return False
        self.session.delete(tour)
        self.session.commit()
        return True
