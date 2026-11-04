import uuid
from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class UserTokens(SQLModel, table=True):
    __tablename__ = "user_tokens"

    token_id: str = Field(primary_key=True, max_length=12)
    user_id: uuid.UUID = Field(foreign_key="users.user_id")
    token_type: str = Field(max_length=30)
    token_hash: str = Field(unique=True, max_length=255)
    expires_at: datetime
    used_at: Optional[datetime] = None
    last_activity: Optional[datetime] = None
    ip_address: Optional[str] = Field(default=None, max_length=45)
    user_agent: Optional[str] = None
    is_revoked: bool = Field(default=False)
    revoked_at: Optional[datetime] = None
    created_at: datetime = Field(default_factory=datetime.utcnow)
