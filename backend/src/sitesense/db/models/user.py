import uuid
from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class User(SQLModel, table=True):
    __tablename__ = "users"

    user_id: uuid.UUID = Field(primary_key=True)
    full_name: Optional[str] = None
    email: str = Field(index=True, unique=True, max_length=255)
    phone_number: Optional[str] = Field(default=None, max_length=20)
    role: str = Field(default="user", max_length=20)
    profile_picture_url: Optional[str] = None
    account_status: str = Field(default="pending", max_length=20)
    email_verified: bool = Field(default=False)
    last_login: Optional[datetime] = None
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)
