"""Reconcile enrichment schema before running the API with restricted grants."""

from alembic import op
from sqlmodel import Session

from sitewise.services.enrichment_schema import DDL_STATEMENTS, _migrate_constraints, feature_column_ddl
from sqlalchemy import text

revision = "0015_enrichment_schema"
down_revision = "0014_canonical_fyp_schema"
branch_labels = None
depends_on = None


def upgrade() -> None:
    bind = op.get_bind()
    for statement in (*DDL_STATEMENTS, *feature_column_ddl()):
        bind.execute(text(statement))
    with Session(bind=bind) as session:
        _migrate_constraints(session)

    bind.execute(text("""
        ALTER TABLE fyp.rental_properties ADD COLUMN IF NOT EXISTS draft_request_key uuid
    """))
    bind.execute(text("""
        CREATE UNIQUE INDEX IF NOT EXISTS uq_rental_properties_draft_request_key
        ON fyp.rental_properties (draft_request_key) WHERE draft_request_key IS NOT NULL
    """))


def downgrade() -> None:
    # Keep measurement data and the widened constraints for older clients.
    pass
