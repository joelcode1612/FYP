"""Adaptive capture plan persistence and the incremental matching graph.

Revision ID: 0019_capture_alignment
Revises: 0018_operational25_category
Create Date: 2026-11-26

The five-ring capture plan is generated per camera, so the target geometry can
no longer be inferred from a fixed count: a session resumed after a restart, or
stitched weeks later, must know the exact directions its photographs were
planned for. Two additive JSONB columns on ``fyp.capture_sessions`` carry that
plan and the intrinsics that produced it.

Incremental matching needs somewhere to record what has already been verified.
``fyp.capture_frame_matches`` stores one row per attempted pair. It is additive
and append-only in normal use: a re-match updates the row in place (same
primary key), so a session cannot accumulate contradictory edges.

Three nullable columns on ``fyp.capture_frames`` carry the per-photograph
matching verdict and its coverage contribution, which is what the capture
screen and the admin coverage panel read.

Nothing existing is altered, dropped or backfilled. Historical sessions keep
``plan_geometry = NULL`` and remain readable: their geometry comes from the
``capture_plan_version`` they were recorded with, exactly as before.
"""

from __future__ import annotations

import sqlalchemy as sa

from alembic import op

revision = "0019_capture_alignment"
down_revision = "0018_operational25_category"
branch_labels = None
depends_on = None

_DDL = (
    """
    ALTER TABLE fyp.capture_sessions
        ADD COLUMN IF NOT EXISTS plan_geometry jsonb
    """,
    """
    ALTER TABLE fyp.capture_sessions
        ADD COLUMN IF NOT EXISTS plan_intrinsics jsonb
    """,
    """
    ALTER TABLE fyp.capture_sessions
        ADD COLUMN IF NOT EXISTS alignment_summary jsonb
    """,
    """
    ALTER TABLE fyp.capture_frames
        ADD COLUMN IF NOT EXISTS matching_status text
    """,
    """
    ALTER TABLE fyp.capture_frames
        ADD COLUMN IF NOT EXISTS matching_confidence double precision
    """,
    """
    ALTER TABLE fyp.capture_frames
        ADD COLUMN IF NOT EXISTS coverage_contribution double precision
    """,
    """
    CREATE TABLE IF NOT EXISTS fyp.capture_frame_matches (
        session_id uuid NOT NULL
            REFERENCES fyp.capture_sessions(id) ON DELETE CASCADE,
        target_a integer NOT NULL,
        target_b integer NOT NULL,
        state text NOT NULL,
        inliers integer NOT NULL DEFAULT 0,
        candidates integer NOT NULL DEFAULT 0,
        inlier_ratio double precision NOT NULL DEFAULT 0,
        median_error_px double precision NOT NULL DEFAULT 0,
        p95_error_px double precision NOT NULL DEFAULT 0,
        spread_cells integer NOT NULL DEFAULT 0,
        azimuth_sectors integer NOT NULL DEFAULT 0,
        confidence double precision NOT NULL DEFAULT 0,
        reason text,
        updated_at timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (session_id, target_a, target_b),
        CONSTRAINT capture_frame_matches_ordered CHECK (target_a < target_b)
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS capture_frame_matches_session_state_idx
        ON fyp.capture_frame_matches (session_id, state)
    """,
)

_DROP = (
    "DROP TABLE IF EXISTS fyp.capture_frame_matches",
    "ALTER TABLE fyp.capture_frames DROP COLUMN IF EXISTS coverage_contribution",
    "ALTER TABLE fyp.capture_frames DROP COLUMN IF EXISTS matching_confidence",
    "ALTER TABLE fyp.capture_frames DROP COLUMN IF EXISTS matching_status",
    "ALTER TABLE fyp.capture_sessions DROP COLUMN IF EXISTS alignment_summary",
    "ALTER TABLE fyp.capture_sessions DROP COLUMN IF EXISTS plan_intrinsics",
    "ALTER TABLE fyp.capture_sessions DROP COLUMN IF EXISTS plan_geometry",
)


def upgrade() -> None:
    for statement in _DDL:
        op.execute(sa.text(statement))


def downgrade() -> None:
    for statement in _DROP:
        op.execute(sa.text(statement))
