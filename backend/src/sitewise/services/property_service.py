from typing import Optional

from sqlmodel import Session

from sitewise.db.models.rental_property import RentalProperty
from sitewise.repositories.property_repository import PropertyRepository


class PropertyService:
    def __init__(self, session: Session):
        self.repo = PropertyRepository(session)

    def create_property(self, prop: RentalProperty) -> RentalProperty:
        return self.repo.create(prop)

    def get_property(self, property_id: int) -> Optional[RentalProperty]:
        return self.repo.get_by_id(property_id)

    def list_properties(self, offset: int = 0, limit: int = 100) -> list[RentalProperty]:
        return self.repo.get_all(offset, limit)

    def update_property(self, property_id: int, data: dict) -> Optional[RentalProperty]:
        return self.repo.update(property_id, data)

    def delete_property(self, property_id: int) -> bool:
        return self.repo.delete(property_id)

    def get_by_user(self, user_id) -> list[RentalProperty]:
        return self.repo.get_by_user_id(user_id)

    def get_by_district(self, district_id: str) -> list[RentalProperty]:
        return self.repo.get_by_district_id(district_id)
