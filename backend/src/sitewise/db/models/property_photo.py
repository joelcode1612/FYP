import uuid
from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class PropertyPhoto(SQLModel, table=True):
    __tablename__ = "property_photo"

    photo_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    property_id: int = Field()  # legacy FK to public.property retired by migration 0005
    url: str
    caption: Optional[str] = Field(default=None, max_length=255)
    is_primary: bool = Field(default=False)
    created_at: datetime = Field(default_factory=datetime.utcnow)
