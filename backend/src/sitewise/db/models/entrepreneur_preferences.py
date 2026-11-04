import uuid
from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class EntrepreneurPreferences(SQLModel, table=True):
    __tablename__ = "entrepreneur_preferences"

    preference_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    user_id: uuid.UUID = Field(foreign_key="users.user_id")
    preferences: Optional[str] = None
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)
