"""Normalized address records — canonical `fyp.addresses`.

Contract adopted from the Supabase `public.addresses` table (the only copy
holding real data — 916 normalized catalogue addresses), renamed into the
`fyp` schema by database standardization migration 0014. The previous local
`public.address` shape (street/city/state/zip/country) was an unused model
artifact and is retired; property rows carry `address_id` provenance pointing
at `fyp.addresses.address_uuid`.
"""

import uuid
from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class Address(SQLModel, table=True):
    __tablename__ = "addresses"
    __table_args__ = {"schema": "fyp", "info": {"externally_managed": True}}

    id: Optional[int] = Field(default=None, primary_key=True)
    address_uuid: Optional[uuid.UUID] = Field(default=None, unique=True)
    source_property_id: Optional[int] = Field(
        default=None, foreign_key="fyp.rental_properties.id"
    )
    address_line1: Optional[str] = Field(default=None, max_length=255)
    address_line2: Optional[str] = Field(default=None, max_length=255)
    district: Optional[str] = Field(default=None, max_length=120)
    city: Optional[str] = Field(default=None, max_length=120)
    state: Optional[str] = Field(default=None, max_length=120)
    postcode: Optional[str] = Field(default=None, max_length=12)
    country_code: Optional[str] = Field(default=None, max_length=4)
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    formatted_address: Optional[str] = None
    coordinate_status: Optional[str] = Field(default=None, max_length=40)
    review_required: bool = Field(default=False)
    source_url: Optional[str] = None
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None
