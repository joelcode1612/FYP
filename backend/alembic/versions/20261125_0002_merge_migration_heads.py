"""Merge the two parallel 0016 migration heads.

``0016_owner_commercial_terms`` (which reconciles the legacy
``0010_agent_listing_assignments`` branch) and ``0016_expanded64_enrichment``
both descend from ``0015_enrichment_schema``. Without this merge revision
Alembic reports multiple heads and ``upgrade head`` is ambiguous.

This revision performs no DDL. Environments whose schema was built by the
standalone ``database_standardization/migrations`` SQL and stamped only
``0016_expanded64_enrichment`` must be stamped to
``0016_owner_commercial_terms`` by an operator before upgrading; the SQL
migration is idempotent (``ADD COLUMN IF NOT EXISTS``), but the legacy agent
assignment revision must not be replayed against an existing table.
"""

revision = "0017_merge_heads"
down_revision = ("0016_owner_commercial_terms", "0016_expanded64_enrichment")
branch_labels = None
depends_on = None


def upgrade() -> None:
    """No schema change: this revision only unifies the revision graph."""


def downgrade() -> None:
    """No schema change: keep all additive columns and snapshots."""
