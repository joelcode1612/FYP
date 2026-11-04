import uuid
from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class FavouriteProperty(SQLModel, table=True):
    __tablename__ = "favorite_property"

    favorite_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    user_id: uuid.UUID = Field(foreign_key="users.user_id")
    property_id: int = Field(foreign_key="property.property_id")
    created_at: datetime = Field(default_factory=datetime.utcnow)
