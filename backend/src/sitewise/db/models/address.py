import uuid
from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class Address(SQLModel, table=True):
    __tablename__ = "address"

    address_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    street: Optional[str] = Field(default=None, max_length=255)
    city: Optional[str] = Field(default=None, max_length=100)
    state: Optional[str] = Field(default=None, max_length=100)
    zip: Optional[str] = Field(default=None, max_length=20)
    country: Optional[str] = Field(default=None, max_length=100)
    latitude: Optional[float] = None
    longitude: Optional[float] = None
