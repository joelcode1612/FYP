"""Panorama administrative review and publication metadata.

Revision ID: 0013_panorama_review
Revises: 0012_capture_authorization
Create Date: 2026-11-22

``fyp.panoramas`` already carries ``verification_status`` ('pending' /
'approved' / 'rejected') and ``published_at``, but nothing recorded WHO
decided, WHEN, or WHY — so an administrator could not audit a review
decision, and a rejection reason could not travel back to the capture
owner. This revision adds three nullable, additive review columns. No
existing row, constraint or permission is touched; statements are
idempotent like revision 0012.

Publication state stays ``published_at``: non-NULL means published,
NULL means not published. ``unpublished_at`` is deliberately NOT added —
an unpublish resets ``published_at`` to NULL and the update timestamp
already records when that happened.
"""

from __future__ import annotations

import sqlalchemy as sa

from alembic import op

revision = "0013_panorama_review"
down_revision = "0012_capture_authorization"
branch_labels = None
depends_on = None

_DDL = (
    """
    ALTER TABLE fyp.panoramas
        ADD COLUMN IF NOT EXISTS reviewed_by uuid
    """,
    """
    ALTER TABLE fyp.panoramas
        ADD COLUMN IF NOT EXISTS reviewed_at timestamptz
    """,
    """
    ALTER TABLE fyp.panoramas
        ADD COLUMN IF NOT EXISTS review_reason text
    """,
)


def upgrade() -> None:
    for statement in _DDL:
        op.execute(sa.text(statement))


def downgrade() -> None:
    for column in ("review_reason", "reviewed_at", "reviewed_by"):
        op.execute(
            sa.text(f"ALTER TABLE fyp.panoramas DROP COLUMN IF EXISTS {column}")
        )
