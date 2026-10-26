import uuid
from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class VirtualTour(SQLModel, table=True):
    __tablename__ = "virtual_tour"

    tour_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    property_id: int = Field(foreign_key="property.property_id")
    url: str
    status: str = Field(default="pending", max_length=50)
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)
