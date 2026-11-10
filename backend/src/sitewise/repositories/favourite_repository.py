import uuid

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

    def delete_by_user_and_property(self, user_id: uuid.UUID, property_id: int) -> bool:
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
