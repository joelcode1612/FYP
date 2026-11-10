import uuid
from datetime import datetime
from decimal import Decimal
from typing import Optional

from sqlmodel import Field, SQLModel


class NearbyCompetitor(SQLModel, table=True):
    __tablename__ = "nearby_competitor"

    competitor_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    property_id: int = Field()  # legacy FK to public.property retired by migration 0005
    name: str = Field(max_length=255)
    address: Optional[str] = None
    distance: Optional[Decimal] = None
    price_range: Optional[str] = Field(default=None, max_length=50)
    rating: Optional[Decimal] = None
    created_at: datetime = Field(default_factory=datetime.utcnow)
