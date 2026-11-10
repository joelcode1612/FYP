"""Additive: web Location Assessment Workspace record.

Revision ID: 0001_assessment
Revises: None
Create Date: 2026-11-09

This is the first revision in the repository. The existing schema is created by
``SQLModel.metadata.create_all`` at application startup, so this migration only
adds the new ``assessment`` table and is written to be idempotent: running it
against a database where startup already created the table is a no-op rather
than an error. It deliberately does not touch any existing table.

The table is web-only. Flutter mobile assessment keeps its own in-session data
collection store and has no dependency on this schema.
"""

from __future__ import annotations

import sqlalchemy as sa
import sqlmodel

from alembic import op

revision = "0001_assessment"
down_revision = None
branch_labels = None
depends_on = None

_TABLE = "assessment"


def _has_table() -> bool:
    bind = op.get_bind()
    return sa.inspect(bind).has_table(_TABLE)


def upgrade() -> None:
    if _has_table():
        return
    op.create_table(
        _TABLE,
        sa.Column("assessment_id", sa.Uuid(), primary_key=True),
        sa.Column(
            "user_id",
            sa.Uuid(),
            sa.ForeignKey("users.user_id"),
            nullable=False,
        ),
        sa.Column("property_id", sqlmodel.sql.sqltypes.AutoString(length=64), nullable=False),
        sa.Column("status", sqlmodel.sql.sqltypes.AutoString(length=20), nullable=False),
        sa.Column("property_selected_at", sa.DateTime(), nullable=True),
        sa.Column("requirements_saved_at", sa.DateTime(), nullable=True),
        sa.Column("evidence_reviewed_at", sa.DateTime(), nullable=True),
        sa.Column("explanation_reviewed_at", sa.DateTime(), nullable=True),
        sa.Column("report_generated_at", sa.DateTime(), nullable=True),
        sa.Column("requirements", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.UniqueConstraint("user_id", "property_id", name="uq_assessment_user_property"),
    )
    op.create_index("ix_assessment_user_id", _TABLE, ["user_id"])
    op.create_index("ix_assessment_property_id", _TABLE, ["property_id"])
    op.create_index("ix_assessment_updated_at", _TABLE, ["updated_at"])


def downgrade() -> None:
    if not _has_table():
        return
    op.drop_index("ix_assessment_updated_at", table_name=_TABLE)
    op.drop_index("ix_assessment_property_id", table_name=_TABLE)
    op.drop_index("ix_assessment_user_id", table_name=_TABLE)
    op.drop_table(_TABLE)
