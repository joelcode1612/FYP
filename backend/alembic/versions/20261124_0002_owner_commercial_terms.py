"""Add owner-declared commercial property terms."""

from pathlib import Path

from alembic import op

revision = "0016_owner_commercial_terms"
# The repository currently has a legacy parallel head for agent assignments.
# Reconcile both heads here so `alembic upgrade head` includes this schema
# change on a database that has followed either existing migration branch.
down_revision = ("0015_enrichment_schema", "0010_agent_listing_assignments")
branch_labels = None
depends_on = None

_SQL_PATH = (
    Path(__file__).resolve().parents[2]
    / "database_standardization"
    / "migrations"
    / "06_owner_commercial_terms.sql"
)


def upgrade() -> None:
    sql = _SQL_PATH.read_text(encoding="utf-8")
    # Alembic owns the transaction; remove psql-compatible boundaries.
    statements = [
        line for line in sql.splitlines()
        if line.strip() not in ("BEGIN;", "COMMIT;")
    ]
    op.execute("\n".join(statements))


def downgrade() -> None:
    # Keep collected data and preserve additive-schema compatibility.
    pass
