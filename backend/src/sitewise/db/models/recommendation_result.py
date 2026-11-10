import uuid
from datetime import datetime
from decimal import Decimal
from typing import Optional

from sqlmodel import Field, SQLModel


class RecommendationResult(SQLModel, table=True):
    __tablename__ = "recommendation_result"

    result_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    user_id: uuid.UUID = Field(foreign_key="users.user_id")
    property_id: int = Field()  # legacy FK to public.property retired by migration 0005
    score: Decimal = Field(max_digits=8, decimal_places=5)
    ranking: Optional[int] = None
    created_at: datetime = Field(default_factory=datetime.utcnow)
