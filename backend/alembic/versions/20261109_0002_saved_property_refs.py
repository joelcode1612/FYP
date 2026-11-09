"""Retype saved-property references to the catalogue's text ids.

Revision ID: 0002_saved_property_refs
Revises: 0001_assessment
Create Date: 2026-11-09

``favorite_property.property_id`` was an integer foreign key into the legacy
``property`` table, which has zero rows in this deployment — the real catalogue
is the imported ``sitewise_app.properties`` (2,126 rows) whose ``id`` is text
(``EP-01051``, ...). With the int key the save endpoint could never accept a
catalogue id, so no consumer exists and the table is empty. Retyping the empty
column loses no data and gives the existing table and API one working surface
instead of a second parallel one.

The column deliberately does NOT gain a foreign key into ``sitewise_app``:
that schema is owned by the import pipeline, not this application, and a
hard reference would couple the app schema to an external table. Writes are
validated against the catalogue instead, and reads report references that no
longer resolve (delisted properties) rather than hiding them.

Idempotent like 0001: every step is skipped when the database already reflects
it. The Flutter mobile app has no saved-property feature and no dependency on
this table.
"""

from __future__ import annotations

import sqlalchemy as sa

from alembic import op

revision = "0002_saved_property_refs"
down_revision = "0001_assessment"
branch_labels = None
depends_on = None

_TABLE = "favorite_property"
_INT_FK = "favorite_property_property_id_fkey"
_UNIQUE = "uq_favorite_property_user_property"


def _columns() -> dict:
    bind = op.get_bind()
    return {col["name"]: col for col in sa.inspect(bind).get_columns(_TABLE)}


def _constraints() -> set[str]:
    bind = op.get_bind()
    return {c["name"] for c in sa.inspect(bind).get_unique_constraints(_TABLE)} | {
        c["name"] for c in sa.inspect(bind).get_foreign_keys(_TABLE)
    }


def upgrade() -> None:
    columns = _columns()
    if not columns:
        return
    if _INT_FK in _constraints():
        op.drop_constraint(_INT_FK, _TABLE, type_="foreignkey")
    column = columns.get("property_id")
    if column is not None and str(column["type"]).upper().startswith("INTEGER"):
        op.alter_column(
            _TABLE,
            "property_id",
            existing_type=sa.Integer(),
            type_=sa.Text(),
            existing_nullable=False,
        )
    if _UNIQUE not in _constraints():
        op.create_unique_constraint(_UNIQUE, _TABLE, ["user_id", "property_id"])


def downgrade() -> None:
    # Downgrade to ints is only meaningful when every stored reference is an
    # int-shaped id, which cannot be guaranteed; this deployment stores none.
    pass
