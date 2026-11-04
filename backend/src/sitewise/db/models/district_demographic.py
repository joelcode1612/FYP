from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class DistrictDemographic(SQLModel, table=True):
    __tablename__ = "district_demographic"

    district_id: str = Field(primary_key=True, max_length=50)
    district_name: str = Field(max_length=255)
    population: Optional[int] = None
    avg_income: Optional[float] = None
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)
