import uuid
from datetime import UTC, datetime

from sqlmodel import Field, SQLModel


class VirtualTour(SQLModel, table=True):
    __tablename__ = "virtual_tour"

    tour_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    # The database constraint is added separately from this model because the
    # legacy table predates the operational listing schema. API authorization
    # treats this as an fyp.rental_properties id today.
    property_id: int = Field()
    url: str
    status: str = Field(default="pending", max_length=50)
    # The deployed column is timezone-aware; naive utcnow() values make direct
    # API creates fail under SQLAlchemy/PostgreSQL's strict comparison rules.
    created_at: datetime = Field(default_factory=lambda: datetime.now(UTC))
    updated_at: datetime = Field(default_factory=lambda: datetime.now(UTC))
