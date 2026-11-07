import uuid
from typing import Optional

from sqlmodel import Session

from sitewise.db.models.virtual_tour import VirtualTour
from sitewise.repositories.virtual_tour_repository import VirtualTourRepository


class VirtualTourService:
    def __init__(self, session: Session):
        self.repo = VirtualTourRepository(session)

    def create(self, tour: VirtualTour) -> VirtualTour:
        return self.repo.create(tour)

    def get(self, tour_id: uuid.UUID) -> Optional[VirtualTour]:
        return self.repo.get_by_id(tour_id)

    def get_by_property(self, property_id: int) -> list[VirtualTour]:
        return self.repo.get_by_property_id(property_id)

    def list_all(self, offset: int = 0, limit: int = 100) -> list[VirtualTour]:
        return self.repo.get_all(offset, limit)

    def update(self, tour_id: uuid.UUID, data: dict) -> Optional[VirtualTour]:
        return self.repo.update(tour_id, data)

    def delete(self, tour_id: uuid.UUID) -> bool:
        return self.repo.delete(tour_id)
