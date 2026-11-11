"""Unified property verification (listing + ownership dimensions).

One workflow per owner-submitted property (``fyp.rental_properties.id``): the
listing-accuracy dimension and the ownership/authority dimension are reviewed
independently, and the property becomes publication-eligible only when BOTH
are ``verified`` (``publication_eligible`` is recomputed on every decision).

The Supabase-side agent finding mechanism (``staff.py`` ``listing_verification``
records on assigned listings) is a separate, pre-existing subsystem and is
untouched by these tables.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

from sqlalchemy import CheckConstraint, UniqueConstraint
from sqlmodel import Field, SQLModel

LISTING_STATUSES = (
    "not_submitted",
    "pending",
    "under_review",
    "verified",
    "rejected",
    "information_requested",
)
OWNERSHIP_STATUSES = LISTING_STATUSES
VERIFICATION_TYPES = ("listing", "ownership")

# Dimensions that may move when the submitter (re)submits the property.
_RESUBMITTABLE = ("not_submitted", "rejected", "information_requested")


def can_resubmit(listing_status: str, ownership_status: str) -> bool:
    """A submission is possible while at least one dimension awaits input."""
    return listing_status in _RESUBMITTABLE or ownership_status in _RESUBMITTABLE


class PropertyVerification(SQLModel, table=True):
    __tablename__ = "property_verification"
    __table_args__ = (
        UniqueConstraint("property_id", name="uq_property_verification_property"),
        CheckConstraint(
            "listing_status IN ('not_submitted','pending','under_review',"
            "'verified','rejected','information_requested')",
            name="ck_property_verification_listing_status",
        ),
        CheckConstraint(
            "ownership_status IN ('not_submitted','pending','under_review',"
            "'verified','rejected','information_requested')",
            name="ck_property_verification_ownership_status",
        ),
    )

    verification_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    property_id: int = Field(foreign_key="fyp.rental_properties.id", nullable=False, index=True)
    listing_status: str = Field(default="not_submitted", max_length=32, nullable=False)
    ownership_status: str = Field(default="not_submitted", max_length=32, nullable=False)
    submitted_by: uuid.UUID = Field(foreign_key="users.user_id", nullable=False, index=True)
    reviewed_by: uuid.UUID | None = Field(default=None, foreign_key="users.user_id")
    publication_eligible: bool = Field(default=False, nullable=False)
    latest_note: str | None = Field(default=None, max_length=2000)
    version: int = Field(default=1, nullable=False)
    created_at: datetime = Field(default_factory=lambda: datetime.now(UTC), nullable=False)
    updated_at: datetime = Field(default_factory=lambda: datetime.now(UTC), nullable=False)


class VerificationDocument(SQLModel, table=True):
    __tablename__ = "verification_document"
    __table_args__ = (
        CheckConstraint(
            "verification_type IN ('listing','ownership')",
            name="ck_verification_document_type",
        ),
    )

    document_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    verification_id: uuid.UUID = Field(
        foreign_key="property_verification.verification_id", nullable=False, index=True
    )
    property_id: int = Field(foreign_key="fyp.rental_properties.id", nullable=False, index=True)
    verification_type: str = Field(max_length=16, nullable=False)
    document_type: str = Field(max_length=60, nullable=False)
    original_filename: str = Field(max_length=255, nullable=False)
    storage_key: str = Field(max_length=120, nullable=False, unique=True)
    mime_type: str = Field(max_length=100, nullable=False)
    file_size: int = Field(nullable=False)
    uploaded_by: uuid.UUID = Field(foreign_key="users.user_id", nullable=False)
    uploaded_at: datetime = Field(default_factory=lambda: datetime.now(UTC), nullable=False)
    status: str = Field(default="active", max_length=20, nullable=False)


class VerificationAudit(SQLModel, table=True):
    __tablename__ = "verification_audit"

    audit_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    property_id: int = Field(foreign_key="fyp.rental_properties.id", nullable=False, index=True)
    verification_id: uuid.UUID | None = Field(
        default=None, foreign_key="property_verification.verification_id", index=True
    )
    verification_type: str | None = Field(default=None, max_length=16)
    previous_status: str | None = Field(default=None, max_length=32)
    new_status: str | None = Field(default=None, max_length=32)
    action: str = Field(max_length=60, nullable=False)
    # The acting administrator for decision rows; NULL for submitter-side rows
    # (submission / evidence upload), which carry the actor in ``note`` context.
    admin_user_id: uuid.UUID | None = Field(default=None, foreign_key="users.user_id")
    reason: str | None = Field(default=None, max_length=2000)
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC), nullable=False, index=True
    )
