import uuid
from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class PropertyFootTraffic(SQLModel, table=True):
    __tablename__ = "property_foot_traffic"

    traffic_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    property_id: int = Field()  # legacy FK to public.property retired by migration 0005
    traffic_level: Optional[str] = Field(default=None, max_length=50)
    estimated_daily_visitors: Optional[int] = None
    peak_traffic_hours: Optional[str] = Field(default=None, max_length=100)
    weekday_vs_weekend: Optional[str] = Field(default=None, max_length=100)
    last_updated: datetime = Field(default_factory=datetime.utcnow)
