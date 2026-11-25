"""Allow the Operational25 durable enrichment job category.

No new table or column: Operational25 reuses
``fyp.property_enrichment_category`` for queue state and
``fyp.property_geospatial_features`` JSONB columns for measurements and scores.
Only the existing category CHECK constraint is widened by one value.
"""
from alembic import op

revision = "0018_operational25_category"
down_revision = "0017_merge_heads"
branch_labels = None
depends_on = None

CATEGORIES = (
    "fnb_competitors", "demand_generators", "roads_transport", "parking",
    "population", "age_population", "expanded64_population", "expanded64_age",
    "expanded64_residential", "expanded64_demand", "expanded64_competition",
    "expanded64_transit", "expanded64_network", "expanded64_parking",
)


def upgrade() -> None:
    values = ", ".join(f"'{name}'::text" for name in (*CATEGORIES, "operational25"))
    op.execute("ALTER TABLE fyp.property_enrichment_category DROP CONSTRAINT IF EXISTS ck_pec_category")
    op.execute(
        "ALTER TABLE fyp.property_enrichment_category ADD CONSTRAINT ck_pec_category "
        f"CHECK (category = ANY (ARRAY[{values}]))"
    )


def downgrade() -> None:
    values = ", ".join(f"'{name}'::text" for name in CATEGORIES)
    op.execute("ALTER TABLE fyp.property_enrichment_category DROP CONSTRAINT IF EXISTS ck_pec_category")
    op.execute(
        "ALTER TABLE fyp.property_enrichment_category ADD CONSTRAINT ck_pec_category "
        f"CHECK (category = ANY (ARRAY[{values}]))"
    )
