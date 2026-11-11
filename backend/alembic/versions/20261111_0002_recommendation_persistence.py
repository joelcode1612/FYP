"""Durable recommendation persistence on the existing table.

Revision ID: 0008_recommendation_persistence
Revises: 0007_listing_change_requests
Create Date: 2026-11-11

``recommendation_result`` was an INTEGER-keyed legacy table: ``property_id``
referenced ``public.property``, retired by migration 0005 (the FK constraint
is already gone; only the dead integer column remained), and the table held
zero rows. Generated recommendation batches were therefore process-local.

This migration retypes the empty ``property_id`` to TEXT so it carries the
catalogue's canonical ids (``EP-01877``, ``MD-00510``) - text ids are never
forced through an integer key - and adds the columns the three-layer pipeline
needs: ``batch_id``, typed PU/preference scores, scoring/model versions, the
full result ``payload`` and the attached ``shap`` explanation, both JSONB.

The ``users`` foreign key is recreated ON DELETE CASCADE so deleting a user
removes their generated results with them (no orphaned personalisation data).

No data is rewritten: the table is empty. Idempotent, like 0002/0006: every
step is skipped when the database already reflects it. On this deployment
revisions 0004-0007 were applied out-of-band and ``alembic_version`` still
says 0003, so use ``scripts/apply_recommendation_persistence_migration.py``
instead of ``alembic upgrade head``.
"""

from __future__ import annotations

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

from alembic import op

revision = "0008_recommendation_persistence"
down_revision = "0007_listing_change_requests"
branch_labels = None
depends_on = None

_TABLE = "recommendation_result"
_USER_FK = "recommendation_result_user_id_fkey"

_ADDED_COLUMNS = [
    ("batch_id", sa.UUID()),
    ("pu_association_score", sa.Numeric(8, 6)),
    ("preference_match_score", sa.Numeric(8, 6)),
    ("scoring_version", sa.String(64)),
    ("model_name", sa.String(64)),
    ("payload", JSONB),
    ("shap", JSONB),
]


def _columns() -> dict:
    bind = op.get_bind()
    return {col["name"]: col for col in sa.inspect(bind).get_columns(_TABLE)}


def _fk_names() -> set[str]:
    bind = op.get_bind()
    return {fk["name"] for fk in sa.inspect(bind).get_foreign_keys(_TABLE)}


def upgrade() -> None:
    columns = _columns()
    if not columns:
        return

    property_col = columns.get("property_id")
    if property_col is not None and str(property_col["type"]).upper().startswith("INTEGER"):
        bind = op.get_bind()
        rows = bind.execute(sa.text(f"SELECT COUNT(*) FROM {_TABLE}")).scalar_one()
        if int(rows) != 0:
            raise RuntimeError(
                f"{_TABLE} is not empty; refusing to retype property_id automatically"
            )
        op.alter_column(
            _TABLE,
            "property_id",
            existing_type=sa.Integer(),
            type_=sa.Text(),
            existing_nullable=False,
        )

    existing = set(columns)
    for name, col_type in _ADDED_COLUMNS:
        if name not in existing:
            op.add_column(_TABLE, sa.Column(name, col_type, nullable=True))

    if _USER_FK in _fk_names():
        op.drop_constraint(_USER_FK, _TABLE, type_="foreignkey")
    op.create_foreign_key(
        _USER_FK, _TABLE, "users", ["user_id"], ["user_id"], ondelete="CASCADE"
    )

    op.create_index(
        "ix_recommendation_result_user_batch",
        _TABLE,
        ["user_id", "batch_id"],
        unique=False,
    )
    op.create_index(
        "ix_recommendation_result_batch", _TABLE, ["batch_id"], unique=False
    )


def downgrade() -> None:
    # Downgrade would require converting text ids back to integers, which no
    # guarantee of int-shapeness supports; this deployment stores none.
    pass
