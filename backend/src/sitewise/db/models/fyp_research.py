"""ORM read models for the ``fyp`` research/operational schema.

These classes mirror the LIVE ``fyp`` schema (verified against the deployed
PostgreSQL database, 2026-11-09) and the supplied ERD contract
(``456.pgerd`` → ``SiteWise_PostgreSQL_ORM_Models_From_ERD``). They exist so
application queries can go through typed session.execute(select(...)) where
practical and so ``create_all`` recognises the tables as already present —
**no table here is ever created, altered or dropped by the application.**

Key semantics established by live inspection (do not re-derive):

* ``fyp.rental_properties`` is the primary operational property table
  (bigserial ``id``). 1,182 rows live: 227 ``approved``+published,
  955 ``pending``+unpublished (the unlabeled research candidates).
* ``owner_id`` → ``fyp.users.id`` (legacy bigserial identity). These ids are
  NOT Supabase ``auth.users``/``public.users`` uuids and must never be mixed.
* ``fyp.property_subject_links`` maps a rental property to a
  ``sitewise_analytics.subject_features`` row (all 955 live links are
  ``match_verified``). The 955 linked subjects are class ``U``; the 894
  class ``P`` rows are PU training outlets with no rental_properties row.
* ``sitewise_analytics.subject_features`` stores *features only* — there is
  no verified success-probability column. Never present one as such.
* ``fyp.property_photos`` exists but is EMPTY live (the 5,979 image URLs of
  the brief were never imported). Reads must treat image absence as a normal
  state, not an error.
* ``fyp.recommendation_results.user_id`` → ``fyp.users.id`` — personalised
  rows cannot be keyed to Supabase identities without a mapping that does
  not exist yet. The table is empty live.
"""

from datetime import datetime
from decimal import Decimal
from typing import Optional

from sqlalchemy import Column
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel

_FYP_SCHEMA = {"schema": "fyp"}


class FypRentalProperty(SQLModel, table=True):
    """``fyp.rental_properties`` — the primary operational property table."""

    __tablename__ = "rental_properties"
    __table_args__ = _FYP_SCHEMA

    id: Optional[int] = Field(default=None, primary_key=True)
    owner_id: Optional[int] = Field(default=None, foreign_key="fyp.users.id")
    listing_id: Optional[str] = Field(default=None, max_length=120)
    name: str = Field(max_length=255)
    property_type: str = Field(max_length=255)
    description: Optional[str] = None
    address: Optional[str] = None
    city: Optional[str] = Field(default=None, max_length=120)
    state: Optional[str] = Field(default=None, max_length=255)
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    # PostGIS geometry column: never selected into the ORM (use the plain
    # lat/long mirrors); raw SQL casts it when spatial predicates are needed.
    rental_price: Optional[Decimal] = None
    size_sqft: Optional[Decimal] = None
    psf: Optional[Decimal] = None
    bathrooms: Optional[Decimal] = None
    floor_level: Optional[Decimal] = None
    frontage_ft: Optional[Decimal] = None
    depth_ft: Optional[Decimal] = None
    land_area_sqft: Optional[Decimal] = None
    built_up_sqft: Optional[Decimal] = None
    tenure: Optional[str] = Field(default=None, max_length=255)
    furnishing: Optional[str] = Field(default=None, max_length=255)
    availability: Optional[str] = Field(default=None, max_length=255)
    is_corner_lot: int = 0
    has_parking: int = 0
    is_freehold: int = 0
    is_fnb_suitable: int = 0
    verification_status: str = Field(default="pending", max_length=20)
    rejection_reason: Optional[str] = None
    is_published: bool = False
    floor_description: Optional[str] = None
    unit_position: Optional[str] = None
    facing_direction: Optional[str] = None
    availability_verified_at: Optional[datetime] = None
    published_at: Optional[datetime] = None
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None


class FypPropertyPhoto(SQLModel, table=True):
    """``fyp.property_photos`` — EMPTY live; reads must tolerate absence."""

    __tablename__ = "property_photos"
    __table_args__ = _FYP_SCHEMA

    id: Optional[int] = Field(default=None, primary_key=True)
    property_id: int = Field(foreign_key="fyp.rental_properties.id")
    url: str
    caption: Optional[str] = Field(default=None, max_length=255)
    is_primary: bool = False
    created_at: Optional[datetime] = None


class FypPropertySubjectLink(SQLModel, table=True):
    """``fyp.property_subject_links`` — verified research linkage.

    ``subject_id`` joins ``sitewise_analytics.subject_features``;
    ``sitewise_property_id`` holds the workbook id (``MD-xxxxx`` /
    ``EP-xxxxx``) when one exists.
    """

    __tablename__ = "property_subject_links"
    __table_args__ = _FYP_SCHEMA

    property_id: int = Field(primary_key=True, foreign_key="fyp.rental_properties.id")
    subject_id: Optional[str] = Field(default=None, max_length=50)
    sitewise_property_id: Optional[str] = None
    match_method: Optional[str] = None
    match_evidence: Optional[str] = None
    match_verified: bool = False
    linked_at: Optional[datetime] = None
    verified_at: Optional[datetime] = None


class FypPropertyGeospatialFeature(SQLModel, table=True):
    """``fyp.property_geospatial_features`` — precomputed per-property stats.

    Covers 481/1,182 rows live. Competitor/population values here are
    *precomputed research counts* — prefer them over on-the-fly PostGIS in
    list requests (N+1 avoidance, task §10).
    """

    __tablename__ = "property_geospatial_features"
    __table_args__ = _FYP_SCHEMA

    id: Optional[int] = Field(default=None, primary_key=True)
    property_id: int = Field(foreign_key="fyp.rental_properties.id")
    population_500m: Optional[float] = None
    population_1km: Optional[float] = None
    population_level: Optional[str] = Field(default=None, max_length=20)
    competitor_count_500m: Optional[int] = None
    competitor_count_1km: Optional[int] = None
    demand_generator_count_500m: Optional[int] = None
    demand_generator_count_1km: Optional[int] = None
    accessibility_road_km_1km: Optional[float] = None
    accessibility_score: Optional[float] = None
    nearest_major_road_m: Optional[float] = None
    district_name: Optional[str] = Field(default=None, max_length=120)
    state_name: Optional[str] = Field(default=None, max_length=120)
    income_median: Optional[Decimal] = None
    income_mean: Optional[Decimal] = None
    market_segment: Optional[str] = Field(default=None, max_length=40)
    overall_location_score: Optional[float] = None
    last_calculated_at: Optional[datetime] = None


class FypPropertyFeature(SQLModel, table=True):
    """``fyp.property_features`` — amenities/landmark JSON per property."""

    __tablename__ = "property_features"
    __table_args__ = _FYP_SCHEMA

    id: Optional[int] = Field(default=None, primary_key=True)
    property_id: int = Field(foreign_key="fyp.rental_properties.id")
    suitable_for: Optional[str] = None
    nearby_landmarks: Optional[str] = None
    # Live column type is jsonb; the repository reads it through raw SQL, so
    # this mirror only needs the mapping to be precise, never written.
    amenities: Optional[dict] = Field(default=None, sa_column=Column(JSONB))
    remarks: Optional[str] = None
    created_at: Optional[datetime] = None


class FypRecommendationResult(SQLModel, table=True):
    """``fyp.recommendation_results`` — EMPTY live.

    ``user_id`` references ``fyp.users`` (legacy bigserial), NOT the Supabase
    identity used by the application. Until a mapping exists, personalised
    reads honestly report "no model results" rather than guessing.
    """

    __tablename__ = "recommendation_results"
    __table_args__ = _FYP_SCHEMA

    id: Optional[int] = Field(default=None, primary_key=True)
    batch_id: Optional[str] = None
    user_id: Optional[int] = Field(default=None, foreign_key="fyp.users.id")
    property_id: int = Field(foreign_key="fyp.rental_properties.id")
    suitability_score: Optional[float] = None
    ranking: Optional[int] = None
    preference_snapshot: Optional[dict] = Field(
        default=None, sa_column=Column(JSONB)
    )
    feature_snapshot: Optional[dict] = Field(default=None, sa_column=Column(JSONB))
    created_at: Optional[datetime] = None
