import uuid
from datetime import UTC, datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class AiExplanation(SQLModel, table=True):
    __tablename__ = "ai_explanation"

    explanation_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    property_id: Optional[int] = Field(default=None)  # legacy FK to public.property retired by migration 0005
    user_id: Optional[uuid.UUID] = Field(default=None, foreign_key="users.user_id")
    content: str
    created_at: datetime = Field(default_factory=lambda: datetime.now(UTC))
