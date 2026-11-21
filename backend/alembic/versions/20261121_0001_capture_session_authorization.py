"""Authoritative 360° capture: additive canonical metadata for the port.

Revision ID: 0012_capture_authorization
Revises: 0011_canonical_property_master
Create Date: 2026-11-21

The backend becomes the authoritative panorama processor. The capture tables
already exist in ``fyp`` (created out-of-band before any code referenced
them, empty, with working foreign keys and status vocabulary), so this
revision only EXTENDS them in place and adds the one missing canonical
record — ``fyp.panoramas`` — instead of creating parallel tables:

1. ``fyp.capture_sessions`` gains ``capture_mode`` (device-38 sensor capture,
   ARCore 26-target, ARCore 30-node tour — the three modes that must never be
   merged) and ``capture_plan_version``.
2. ``fyp.capture_frames`` gains the canonical manifest fields the stitcher
   needs to reconstruct the capture: image dimensions, the recorded camera
   pose (jsonb, [x, y, z, w]), ``captured_at`` and the upload lifecycle
   ``upload_status``.
3. ``fyp.panorama_jobs`` gains worker fields: ``progress`` (0-100),
   ``processing_stage``, ``retry_count``, ``started_at``/``completed_at``,
   plus a claim lease (``claimed_at``/``claimed_by``) so a worker crash or
   backend restart can reclaim a stalled job without a second worker
   double-processing it. A partial unique index allows only one live job per
   session.
4. ``fyp.panoramas`` is the canonical panorama record: one per session
   (UNIQUE), property-scoped, carrying the storage object PATH (never an
   expiring URL) and the 2:1 geometry.

Applied out-of-band like revisions 0004-0011; every statement is idempotent
and additive — no existing row, constraint or permission is touched.
"""

from __future__ import annotations

import sqlalchemy as sa

from alembic import op

revision = "0012_capture_authorization"
down_revision = "0011_canonical_property_master"
branch_labels = None
depends_on = None

_DDL = (
    # 1. Session capture plan provenance.
    """
    ALTER TABLE fyp.capture_sessions
        ADD COLUMN IF NOT EXISTS capture_mode text NOT NULL DEFAULT 'device_38'
    """,
    """
    ALTER TABLE fyp.capture_sessions
        ADD COLUMN IF NOT EXISTS capture_plan_version text NOT NULL DEFAULT '1'
    """,
    # 2. Frame manifest fields.
    """
    ALTER TABLE fyp.capture_frames
        ADD COLUMN IF NOT EXISTS image_width integer
            CHECK (image_width IS NULL OR image_width > 0)
    """,
    """
    ALTER TABLE fyp.capture_frames
        ADD COLUMN IF NOT EXISTS image_height integer
            CHECK (image_height IS NULL OR image_height > 0)
    """,
    """
    ALTER TABLE fyp.capture_frames
        ADD COLUMN IF NOT EXISTS capture_pose jsonb
    """,
    """
    ALTER TABLE fyp.capture_frames
        ADD COLUMN IF NOT EXISTS captured_at timestamptz
    """,
    """
    ALTER TABLE fyp.capture_frames
        ADD COLUMN IF NOT EXISTS upload_status text NOT NULL DEFAULT 'confirmed'
    """,
    # 3. Worker fields on the job table.
    """
    ALTER TABLE fyp.panorama_jobs
        ADD COLUMN IF NOT EXISTS progress smallint NOT NULL DEFAULT 0
            CHECK (progress BETWEEN 0 AND 100)
    """,
    """
    ALTER TABLE fyp.panorama_jobs
        ADD COLUMN IF NOT EXISTS processing_stage text
    """,
    """
    ALTER TABLE fyp.panorama_jobs
        ADD COLUMN IF NOT EXISTS retry_count integer NOT NULL DEFAULT 0
    """,
    """
    ALTER TABLE fyp.panorama_jobs
        ADD COLUMN IF NOT EXISTS started_at timestamptz
    """,
    """
    ALTER TABLE fyp.panorama_jobs
        ADD COLUMN IF NOT EXISTS completed_at timestamptz
    """,
    """
    ALTER TABLE fyp.panorama_jobs
        ADD COLUMN IF NOT EXISTS claimed_at timestamptz
    """,
    """
    ALTER TABLE fyp.panorama_jobs
        ADD COLUMN IF NOT EXISTS claimed_by text
    """,
    """
    CREATE UNIQUE INDEX IF NOT EXISTS uq_panorama_jobs_session_live
        ON fyp.panorama_jobs (session_id)
        WHERE status IN ('queued', 'processing')
    """,
    # 4. The canonical panorama record — exactly one per capture session.
    """
    CREATE TABLE IF NOT EXISTS fyp.panoramas (
        panorama_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        session_id uuid NOT NULL UNIQUE
            REFERENCES fyp.capture_sessions(id) ON DELETE CASCADE,
        property_id text NOT NULL,
        storage_path text NOT NULL,
        format text NOT NULL DEFAULT 'equirectangular_2_1',
        width integer NOT NULL CHECK (width > 0),
        height integer NOT NULL CHECK (height > 0),
        verification_status text NOT NULL DEFAULT 'pending'
            CHECK (verification_status IN ('pending', 'approved', 'rejected')),
        published_at timestamptz,
        coverage_report jsonb,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_panoramas_property
        ON fyp.panoramas (property_id)
    """,
)


def upgrade() -> None:
    for statement in _DDL:
        op.execute(sa.text(statement))


def downgrade() -> None:
    op.execute(sa.text("DROP INDEX IF EXISTS fyp.idx_panoramas_property"))
    op.execute(sa.text("DROP TABLE IF EXISTS fyp.panoramas"))
    op.execute(sa.text("DROP INDEX IF EXISTS fyp.uq_panorama_jobs_session_live"))
    for column in (
        "claimed_by",
        "claimed_at",
        "completed_at",
        "started_at",
        "retry_count",
        "processing_stage",
        "progress",
    ):
        op.execute(
            sa.text(f"ALTER TABLE fyp.panorama_jobs DROP COLUMN IF EXISTS {column}")
        )
    for column in (
        "upload_status",
        "captured_at",
        "capture_pose",
        "image_height",
        "image_width",
    ):
        op.execute(
            sa.text(f"ALTER TABLE fyp.capture_frames DROP COLUMN IF EXISTS {column}")
        )
    for column in ("capture_plan_version", "capture_mode"):
        op.execute(
            sa.text(f"ALTER TABLE fyp.capture_sessions DROP COLUMN IF EXISTS {column}")
        )
