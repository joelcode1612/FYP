import uuid
from datetime import datetime
from decimal import Decimal
from typing import Optional

from sqlmodel import Field, SQLModel


class PropertyGeospatialFeature(SQLModel, table=True):
    __tablename__ = "property_geospatial_feature"

    geo_feature_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    property_id: int = Field(foreign_key="property.property_id")
    population_500m: Optional[int] = None
    population_1km: Optional[int] = None
    competitor_count_1km: Optional[int] = None
    demand_generator_count_1km: Optional[int] = None
    accessibility_score: Optional[Decimal] = None
    competitor_score: Optional[Decimal] = None
    demand_generator_score: Optional[Decimal] = None
    socioeconomic_score: Optional[Decimal] = None
    overall_location_score: Optional[Decimal] = None
    last_calculated_date: datetime = Field(default_factory=datetime.utcnow)
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)
