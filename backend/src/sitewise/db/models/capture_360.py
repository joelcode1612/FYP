"""Canonical 360° capture metadata models (``fyp`` schema).

The backend is the authoritative panorama processor; these four tables are
its only canonical records. ``fyp.capture_sessions``/``capture_frames``/
``panorama_jobs`` predate this module (created out-of-band, empty until the
capture API went live) — the models document the EXTENDED shape after
revision ``0012_capture_session_authorization`` rather than recreating them.
``fyp.panoramas`` is new: exactly one per completed capture session.

``property_id`` columns hold the ``fyp.rental_properties.id`` as text —
an application-level reference, resolved through
``sitewise.services.provider_scope`` before any row is readable, because the
legacy tables typed it as text and the property master's integer id must
never be confused with a Supabase auth UUID.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

from sqlmodel import JSON, Column, Field, SQLModel

_FYP_SCHEMA = {"schema": "fyp", "info": {"externally_managed": True}}


def _utcnow() -> datetime:
    return datetime.now(UTC)


class CaptureSession(SQLModel, table=True):
    __tablename__ = "capture_sessions"
    __table_args__ = _FYP_SCHEMA

    id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    property_id: str = Field(index=True)
    owner_id: uuid.UUID = Field()
    status: str = Field(default="capturing")
    expected_frames: int = Field(default=38)
    capture_mode: str = Field(default="device_38")
    capture_plan_version: str = Field(default="1")
    created_at: datetime = Field(default_factory=_utcnow)
    updated_at: datetime = Field(default_factory=_utcnow)


class CaptureFrame(SQLModel, table=True):
    __tablename__ = "capture_frames"
    __table_args__ = _FYP_SCHEMA

    id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    session_id: uuid.UUID = Field(foreign_key="fyp.capture_sessions.id")
    target_index: int = Field()
    storage_path: str = Field()
    checksum_sha256: str | None = Field(default=None)
    image_width: int | None = Field(default=None)
    image_height: int | None = Field(default=None)
    # The recorded camera orientation [x, y, z, w] exactly as the manifest
    # writes it, so the stitcher reconstructs the capture without re-deriving.
    capture_pose: dict[str, Any] | list[Any] | None = Field(
        default=None, sa_column=Column(JSON)
    )
    captured_at: datetime | None = Field(default=None)
    upload_status: str = Field(default="confirmed")
    uploaded_at: datetime = Field(default_factory=_utcnow)


class PanoramaJob(SQLModel, table=True):
    __tablename__ = "panorama_jobs"
    __table_args__ = _FYP_SCHEMA

    id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    session_id: uuid.UUID = Field(foreign_key="fyp.capture_sessions.id")
    status: str = Field(default="queued")
    output_storage_path: str | None = Field(default=None)
    error_message: str | None = Field(default=None)
    progress: int = Field(default=0)
    processing_stage: str | None = Field(default=None)
    retry_count: int = Field(default=0)
    # Claim lease for the durable worker: a stale claim (worker crash, backend
    # restart) is reclaimed; the lease columns make the recovery observable.
    claimed_at: datetime | None = Field(default=None)
    claimed_by: str | None = Field(default=None)
    started_at: datetime | None = Field(default=None)
    completed_at: datetime | None = Field(default=None)
    created_at: datetime = Field(default_factory=_utcnow)
    updated_at: datetime = Field(default_factory=_utcnow)


class Panorama(SQLModel, table=True):
    __tablename__ = "panoramas"
    __table_args__ = _FYP_SCHEMA

    panorama_id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    session_id: uuid.UUID = Field(
        foreign_key="fyp.capture_sessions.id", unique=True
    )
    property_id: str = Field(index=True)
    # The Storage object path, never an expiring signed URL.
    storage_path: str = Field()
    format: str = Field(default="equirectangular_2_1")
    width: int = Field()
    height: int = Field()
    verification_status: str = Field(default="pending")
    published_at: datetime | None = Field(default=None)
    # Administrative review evidence (revision 0013_panorama_review): who
    # decided, when, and the rejection reason. Publication remains
    # ``published_at``; review metadata never implies publication.
    reviewed_by: uuid.UUID | None = Field(default=None)
    reviewed_at: datetime | None = Field(default=None)
    review_reason: str | None = Field(default=None)
    coverage_report: dict[str, Any] | None = Field(
        default=None, sa_column=Column(JSON)
    )
    created_at: datetime = Field(default_factory=_utcnow)
    updated_at: datetime = Field(default_factory=_utcnow)
