"""Explicit Agent→listing assignment table (replaces the absent Supabase table).

Revision ID: 0010_agent_listing_assignments
Revises: 0008_recommendation_persistence
Create Date: 2026-11-11

Why this exists
---------------
The Agent workflow assumed a Supabase ``public.listing`` table carrying
``listing_id`` + ``agent_id``. That table does **not** exist in the live
Supabase project (PostgREST returns ``PGRST205``), and no local table stores
the assignment either, so every assignment lookup failed and no Agent could
load an assigned property.

The operational property system of record is the local PostgreSQL
``fyp.rental_properties`` table. The smallest correct mapping is therefore a
local assignment row keyed by the REAL property primary key:

* ``listing_id BIGINT PRIMARY KEY REFERENCES fyp.rental_properties(id)
  ON DELETE CASCADE`` - the foreign key is the identity guarantee. Two rows
  can never be "the same property because their numbers match"; the row
  cannot exist without the property, and deleting the property removes the
  assignment.
* ``agent_id INTEGER NOT NULL`` - the Supabase ``agent.agent_id`` value
  (identity profiles stay in Supabase; only the assignment lives here).
* ``assigned_by_user_id UUID NULL`` - the administrator who assigned it.
* ``created_at`` / ``updated_at`` timestamps.

Additive only: one new table, no changes to existing tables. Applied through
``scripts/apply_agent_listing_assignments_migration.py`` (the repo's
out-of-band apply-script convention; ``alembic_version`` lags in this DB).
"""

from __future__ import annotations

import sqlalchemy as sa

from alembic import op

revision = "0010_agent_listing_assignments"
# Chained to the COMMITTED head so a clean checkout stays valid. A concurrent
# uncommitted 0009_geo_refresh_state migration may exist in the working tree;
# if both are kept, resolve with `alembic merge` (this file is applied through
# the apply script below in this deployment).
down_revision = "0008_recommendation_persistence"
branch_labels = None
depends_on = None

_TABLE = "agent_listing_assignment"


def upgrade() -> None:
    bind = op.get_bind()
    if sa.inspect(bind).has_table(_TABLE):
        return
    op.create_table(
        _TABLE,
        sa.Column("listing_id", sa.BigInteger(), primary_key=True, nullable=False),
        sa.Column("agent_id", sa.Integer(), nullable=False),
        sa.Column("assigned_by_user_id", sa.UUID(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.ForeignKeyConstraint(
            ["listing_id"],
            ["fyp.rental_properties.id"],
            name="agent_listing_assignment_listing_id_fkey",
            ondelete="CASCADE",
        ),
    )
    op.create_index(
        "ix_agent_listing_assignment_agent",
        _TABLE,
        ["agent_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("ix_agent_listing_assignment_agent", table_name=_TABLE)
    op.drop_table(_TABLE)
