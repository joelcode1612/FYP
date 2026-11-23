"""Canonical fyp schema migration (local PostgreSQL).

Revision ID: 0014_canonical_fyp_schema
Revises: 0013_panorama_review
Create Date: 2026-11-22

Executes database_standardization/migrations/02_local_schema_migration.sql
(single source of truth; this revision never re-states the SQL to avoid
drift). Statements are idempotent; the SQL file guards the target database.

Applied out-of-band like revisions 0004-0013:

    cd backend
    .venv/Scripts/python.exe -m alembic upgrade head
    # or: execute the SQL file directly (see MIGRATION_INSTRUCTIONS.md)
"""

from __future__ import annotations

from pathlib import Path

from alembic import op

revision = "0014_canonical_fyp_schema"
down_revision = "0013_panorama_review"
branch_labels = None
depends_on = None

_SQL_PATH = (
    Path(__file__)
    .resolve()
    .parents[2]
    / "database_standardization"
    / "migrations"
    / "02_local_schema_migration.sql"
)


def upgrade() -> None:
    sql = _SQL_PATH.read_text(encoding="utf-8")
    # Alembic already wraps the migration in a transaction; the file's own
    # BEGIN/COMMIT (for psql-style direct application) must not terminate it.
    lines = [
        ln for ln in sql.splitlines()
        if ln.strip() not in ("BEGIN;", "COMMIT;")
    ]
    op.execute("\n".join(lines))


def downgrade() -> None:
    # Deliberate no-op: the standardization renames/moves are additive and
    # reversible only with a data-bearing rollback (see rollback/). Reverting
    # would recreate retired legacy duplicates with no data; not supported.
    pass
