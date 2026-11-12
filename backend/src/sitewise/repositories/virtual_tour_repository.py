import uuid
from datetime import UTC, datetime

from sqlmodel import Session, select

from sitewise.db.models.virtual_tour import VirtualTour


class VirtualTourRepository:
    _MUTABLE_FIELDS = frozenset({"url", "status"})

    def __init__(self, session: Session):
        self.session = session

    def create(self, tour: VirtualTour) -> VirtualTour:
        self.session.add(tour)
        self.session.commit()
        self.session.refresh(tour)
        return tour

    def get_by_id(self, tour_id: uuid.UUID) -> VirtualTour | None:
        return self.session.get(VirtualTour, tour_id)

    def get_by_property_id(self, property_id: int) -> list[VirtualTour]:
        statement = select(VirtualTour).where(VirtualTour.property_id == property_id)
        return list(self.session.exec(statement).all())

    def get_all(self, offset: int = 0, limit: int = 100) -> list[VirtualTour]:
        statement = select(VirtualTour).offset(offset).limit(limit)
        return list(self.session.exec(statement).all())

    def update(self, tour_id: uuid.UUID, data: dict) -> VirtualTour | None:
        tour = self.get_by_id(tour_id)
        if not tour:
            return None
        for key, value in data.items():
            if key in self._MUTABLE_FIELDS:
                setattr(tour, key, value)
        tour.updated_at = datetime.now(UTC)
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
