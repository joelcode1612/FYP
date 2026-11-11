"""Additive refresh-state schema (source snapshots, runs, freshness, staging).

Revision ID: 0009_geo_refresh_state
Revises: 0008_recommendation_persistence
Create Date: 2026-11-11

Only NEW tables/indexes/sequence are created. No research table, column or
row is altered, and the PU model artifacts are untouched. The DDL is shared
with ``run_data_refresh.py --ensure-schema`` (idempotent CREATE IF NOT EXISTS),
which is the supported path on this deployment because revisions 0004-0008
were applied out-of-band.
"""

from __future__ import annotations

import sqlalchemy as sa

from alembic import op

revision = "0009_geo_refresh_state"
down_revision = "0008_recommendation_persistence"
branch_labels = None
depends_on = None


def upgrade() -> None:
    from sitewise.ingestion.schema import DDL_STATEMENTS

    bind = op.get_bind()
    for ddl in DDL_STATEMENTS:
        bind.execute(sa.text(ddl))


def downgrade() -> None:
    bind = op.get_bind()
    for ddl in (
        "DROP INDEX IF EXISTS fnb_a.idx_duplicate_review_incoming",
        "DROP INDEX IF EXISTS fnb_a.idx_fnb_outlet_stage_coords",
        "DROP INDEX IF EXISTS fnb_a.idx_fnb_outlet_natural_key",
        "DROP INDEX IF EXISTS fnb_a.idx_refresh_run_started",
        "DROP TABLE IF EXISTS fyp.property_feature_freshness",
        "DROP TABLE IF EXISTS fnb_a.fnb_outlet_stage",
        "DROP TABLE IF EXISTS fnb_a.source_absence",
        "DROP TABLE IF EXISTS fnb_a.duplicate_review",
        "DROP TABLE IF EXISTS fnb_a.refresh_run",
        "DROP TABLE IF EXISTS fnb_a.source_snapshot",
        "DROP SEQUENCE IF EXISTS fnb_a.fnb_outlet_refresh_key_seq",
    ):
        bind.execute(sa.text(ddl))
