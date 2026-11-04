import uuid
from datetime import datetime
from decimal import Decimal
from typing import Optional

from sqlmodel import Field, SQLModel


class RentalProperty(SQLModel, table=True):
    __tablename__ = "property"

    property_id: Optional[int] = Field(default=None, primary_key=True)
    address_id: Optional[uuid.UUID] = Field(default=None, foreign_key="address.address_id")
    district_id: Optional[str] = Field(default=None, foreign_key="district_demographic.district_id", max_length=50)
    user_id: Optional[uuid.UUID] = Field(default=None, foreign_key="users.user_id")
    company_name: Optional[str] = Field(default=None, max_length=255)
    normalized_address: Optional[str] = None
    property_type_normalized: Optional[str] = Field(default=None, max_length=100)
    tenure: Optional[str] = Field(default=None, max_length=50)
    floor_level: Optional[str] = Field(default=None, max_length=50)
    unit_position: Optional[str] = Field(default=None, max_length=50)
    built_up_area_sqft: Optional[Decimal] = None
    land_area_sqft: Optional[Decimal] = None
    frontage_ft: Optional[Decimal] = None
    depth_ft: Optional[Decimal] = None
    facing_direction: Optional[str] = Field(default=None, max_length=50)
    bathroom_count: Optional[int] = None
    parking_spaces: Optional[int] = None
    title: Optional[str] = Field(default=None, max_length=255)
    description: Optional[str] = None
    status: Optional[str] = Field(default=None, max_length=50)
    price: Optional[Decimal] = None
    bedrooms: Optional[int] = None
    year_built: Optional[int] = None
