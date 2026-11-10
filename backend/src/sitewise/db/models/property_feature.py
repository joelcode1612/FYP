import uuid
from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class PropertyFeature(SQLModel, table=True):
    __tablename__ = "property_feature"

    feature_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    property_id: int = Field()  # legacy FK to public.property retired by migration 0005
    feature_name: str = Field(max_length=255)
    feature_value: Optional[str] = None
    created_at: datetime = Field(default_factory=datetime.utcnow)
