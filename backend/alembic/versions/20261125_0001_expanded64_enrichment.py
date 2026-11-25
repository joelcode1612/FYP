"""Add canonical Expanded64 category snapshots and durable job keys."""
from alembic import op
from sqlalchemy import text

from sitewise.services.expanded64_enrichment import JOB_KEYS
from sitewise.services.enrichment_schema import CATEGORIES

revision = "0016_expanded64_enrichment"
down_revision = "0015_enrichment_schema"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(text("""
        ALTER TABLE fyp.property_geospatial_features
            ADD COLUMN IF NOT EXISTS expanded64_measurements JSONB
    """))
    literals = ", ".join(f"'{key}'" for key in (*CATEGORIES, *JOB_KEYS))
    op.execute(text(f"""
        ALTER TABLE fyp.property_enrichment_category
            DROP CONSTRAINT IF EXISTS ck_pec_category,
            ADD CONSTRAINT ck_pec_category CHECK (category IN ({literals}))
    """))


def downgrade() -> None:
    # Preserve measurement history and queued work.
    pass
