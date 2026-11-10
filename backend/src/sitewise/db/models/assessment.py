"""Web decision-support assessment record.

Additive table: it references the imported catalogue by its text id
(``EP-01051``) rather than the legacy integer ``property`` table, and it is
owned by exactly one authenticated user. The unique ``(user_id, property_id)``
pair is what makes "open the workspace" resume an existing assessment instead
of creating a duplicate.

The Flutter mobile data-collection workflow does not read or write this table;
it keeps its own session store. Nothing here changes a mobile contract.
"""

import uuid
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import UniqueConstraint
from sqlmodel import Field, SQLModel


def _now() -> datetime:
    return datetime.now(timezone.utc)


class Assessment(SQLModel, table=True):
    __tablename__ = "assessment"
    __table_args__ = (
        UniqueConstraint("user_id", "property_id", name="uq_assessment_user_property"),
    )

    assessment_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    user_id: uuid.UUID = Field(foreign_key="users.user_id", index=True)
    # Catalogue ids are text, and the catalogue lives in the analytics schema
    # which SQLModel does not manage - so this is a validated reference, not a
    # foreign key. Existence is checked against the catalogue before insert.
    property_id: str = Field(max_length=64, index=True)

    status: str = Field(default="in_progress", max_length=20)

    # Stage confirmations. A timestamp is the persisted proof that the stage's
    # operation actually happened; NULL means the stage is not complete.
    property_selected_at: Optional[datetime] = None
    requirements_saved_at: Optional[datetime] = None
    evidence_reviewed_at: Optional[datetime] = None
    explanation_reviewed_at: Optional[datetime] = None
    report_generated_at: Optional[datetime] = None

    # Business requirements captured for this assessment, stored as JSON text
    # (the same convention as entrepreneur_preferences.preferences).
    requirements: Optional[str] = None

    created_at: datetime = Field(default_factory=_now)
    updated_at: datetime = Field(default_factory=_now, index=True)
