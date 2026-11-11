"""Additive per-category enrichment state for the two-phase workflow.

Revision ID: 0010_property_enrichment
Revises: 0009_geo_refresh_state
Create Date: 2026-11-12

Creates ``fyp.property_enrichment_category`` (one row per property and
category, carrying the lifecycle state, the measurement and its provenance)
and adds the parking / transit / provenance columns the new categories need to
``fyp.property_geospatial_features``.

Only additive DDL: no existing row is rewritten, and the 482 already-calculated
feature rows keep their values. The same statements are exposed through
``sitewise.services.enrichment_schema.ensure_schema()``, which is the supported
path on this deployment because revisions 0004-0009 were applied out-of-band.
"""

from __future__ import annotations

import sqlalchemy as sa

from alembic import op

revision = "0010_property_enrichment"
down_revision = "0009_geo_refresh_state"
branch_labels = None
depends_on = None


def upgrade() -> None:
    from sitewise.services.enrichment_schema import (
        DDL_STATEMENTS,
        feature_column_ddl,
    )

    bind = op.get_bind()
    for ddl in DDL_STATEMENTS:
        bind.execute(sa.text(ddl))
    for ddl in feature_column_ddl():
        bind.execute(sa.text(ddl))


def downgrade() -> None:
    bind = op.get_bind()
    for ddl in (
        "DROP INDEX IF EXISTS fyp.idx_pec_category_status",
        "DROP INDEX IF EXISTS fyp.idx_pec_status",
        "DROP INDEX IF EXISTS fyp.idx_pec_property",
        "DROP TABLE IF EXISTS fyp.property_enrichment_category",
        # The measurement columns are intentionally NOT dropped: they hold
        # calculated values that other readers may already depend on, and
        # dropping them would destroy data on a downgrade.
    ):
        bind.execute(sa.text(ddl))
