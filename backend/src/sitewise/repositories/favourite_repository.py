import uuid

from sqlalchemy.dialects.postgresql import insert
from sqlmodel import Session, select

from sitewise.db.models.favourite_property import FavouriteProperty


class FavouriteRepository:
    def __init__(self, session: Session):
        self.session = session

    def create(self, fav: FavouriteProperty) -> FavouriteProperty:
        self.session.add(fav)
        self.session.commit()
        self.session.refresh(fav)
        return fav

    def create_or_get(self, fav: FavouriteProperty) -> tuple[FavouriteProperty, bool]:
        statement = (
            insert(FavouriteProperty)
            .values(**fav.model_dump())
            .on_conflict_do_nothing(index_elements=["user_id", "property_id"])
            .returning(FavouriteProperty)
        )
        while True:
            created = self.session.execute(statement).scalar_one_or_none()
            if created is not None:
                self.session.commit()
                self.session.refresh(created)
                return created, True
            existing = self.get_by_user_and_property(fav.user_id, fav.property_id)
            if existing is not None:
                return existing, False
            # A concurrent unsave removed the conflicting row before our read.

    def get_by_id(self, favorite_id: uuid.UUID) -> FavouriteProperty | None:
        return self.session.get(FavouriteProperty, favorite_id)

    def get_by_user_id(self, user_id: uuid.UUID) -> list[FavouriteProperty]:
        statement = select(FavouriteProperty).where(FavouriteProperty.user_id == user_id)
        return list(self.session.exec(statement).all())

    def get_by_property_id(self, property_id: str) -> list[FavouriteProperty]:
        statement = select(FavouriteProperty).where(FavouriteProperty.property_id == property_id)
        return list(self.session.exec(statement).all())

    def get_by_user_and_property(
        self, user_id: uuid.UUID, property_id: str
    ) -> FavouriteProperty | None:
        statement = select(FavouriteProperty).where(
            FavouriteProperty.user_id == user_id,
            FavouriteProperty.property_id == property_id,
        )
        return self.session.exec(statement).first()

    def delete(self, favorite_id: uuid.UUID) -> bool:
        fav = self.get_by_id(favorite_id)
        if not fav:
            return False
        self.session.delete(fav)
        self.session.commit()
        return True

    def delete_by_user_and_property(self, user_id: uuid.UUID, property_id: str) -> bool:
        statement = select(FavouriteProperty).where(
            FavouriteProperty.user_id == user_id,
            FavouriteProperty.property_id == property_id,
        )
        fav = self.session.exec(statement).first()
        if not fav:
            return False
        self.session.delete(fav)
        self.session.commit()
        return True
