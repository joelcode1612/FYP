import uuid
from datetime import datetime

from sqlalchemy import UniqueConstraint
from sqlmodel import Field, SQLModel


class FavouriteProperty(SQLModel, table=True):
    """One saved catalogue property for one account.

    ``property_id`` holds the catalogue's text id (``EP-01051``, ...). It is a
    soft reference validated at write time — the catalogue schema belongs to
    the import pipeline, so the database does not enforce a foreign key into
    it — and a saved id that later leaves the catalogue is reported as
    unresolved on read rather than silently dropped.
    """

    __tablename__ = "favorite_property"
    __table_args__ = (
        UniqueConstraint("user_id", "property_id", name="uq_favorite_property_user_property"),
    )

    favorite_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    user_id: uuid.UUID = Field(foreign_key="users.user_id")
    property_id: str = Field(nullable=False, max_length=64)
    created_at: datetime = Field(default_factory=datetime.utcnow)
