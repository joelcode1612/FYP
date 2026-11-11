"""Owner-listing verification rebind + draft status.

Revision ID: 0004_owner_listing_verification
Revises: 0003_property_verification
Create Date: 2026-11-10

Two changes, both reviewed for data-loss risk:

1. ``fyp.rental_properties.verification_status`` gains the ``'draft'`` value
   so owner Add-Property drafts can persist unpublished without entering the
   admin queue (existing values ``pending``/``approved``/``rejected`` are
   unchanged; the CHECK is replaced, never dropped without a replacement).

2. The property-verification tables are REBOUND from ``public.property`` to
   ``fyp.rental_properties`` — the canonical owner-created listings table.
   The old FKs pointed at a table owner submissions never write, so a submit
   for a real listing was impossible (identity mismatch). Both tables were
   EMPTY at migration time (0 verification rows, 0 documents, 0 audit rows),
   so the rebind is zero-data-loss; the upgrade asserts emptiness first and
   aborts otherwise, because rebinding a populated legacy table WOULD strand
   its rows.
"""

from __future__ import annotations

import sqlalchemy as sa

from alembic import op

revision = "0004_owner_listing_verification"
down_revision = "0003_property_verification"
branch_labels = None
depends_on = None

_NEW_STATUS_CHECK = (
    "((verification_status::text = ANY (ARRAY['draft'::character varying, "
    "'pending'::character varying, 'approved'::character varying, "
    "'rejected'::character varying]::text[])))"
)

_REBIND_TABLES = (
    "property_verification",
    "verification_document",
    "verification_audit",
)


def _count(bind, table: str) -> int:
    return int(bind.execute(sa.text(f"SELECT count(*) FROM {table}")).scalar_one())


def upgrade() -> None:
    bind = op.get_bind()

    # -- 1. draft status on fyp.rental_properties ---------------------------
    bind.execute(
        sa.text(
            "ALTER TABLE fyp.rental_properties "
            "DROP CONSTRAINT rental_properties_verification_status_check"
        )
    )
    bind.execute(
        sa.text(
            "ALTER TABLE fyp.rental_properties "
            "ADD CONSTRAINT rental_properties_verification_status_check "
            f"CHECK {_NEW_STATUS_CHECK}"
        )
    )

    # -- 2. rebind the verification tables (empty-table guard) --------------
    for table in _REBIND_TABLES:
        if _count(bind, table) > 0:
            raise RuntimeError(
                f"Table {table} is not empty; re-binding its property_id FK "
                "to fyp.rental_properties would strand legacy rows. Back up "
                "and migrate those rows first."
            )
        name = f"{table}_property_id_fkey"
        bind.execute(sa.text(f"ALTER TABLE {table} DROP CONSTRAINT {name}"))
        bind.execute(
            sa.text(f"ALTER TABLE {table} ALTER COLUMN property_id TYPE BIGINT")
        )
        bind.execute(
            sa.text(
                f"ALTER TABLE {table} ADD CONSTRAINT {name} "
                "FOREIGN KEY (property_id) REFERENCES fyp.rental_properties(id)"
            )
        )


def downgrade() -> None:
    bind = op.get_bind()
    for table in _REBIND_TABLES:
        if _count(bind, table) > 0:
            raise RuntimeError(
                f"Table {table} is not empty; cannot restore the legacy "
                "public.property FK without stranding rows."
            )
        name = f"{table}_property_id_fkey"
        bind.execute(sa.text(f"ALTER TABLE {table} DROP CONSTRAINT {name}"))
        bind.execute(
            sa.text(f"ALTER TABLE {table} ALTER COLUMN property_id TYPE INTEGER")
        )
        bind.execute(
            sa.text(
                f"ALTER TABLE {table} ADD CONSTRAINT {name} "
                "FOREIGN KEY (property_id) REFERENCES property(property_id)"
            )
        )
    bind.execute(
        sa.text(
            "ALTER TABLE fyp.rental_properties "
            "DROP CONSTRAINT rental_properties_verification_status_check"
        )
    )
    bind.execute(
        sa.text(
            "ALTER TABLE fyp.rental_properties "
            "ADD CONSTRAINT rental_properties_verification_status_check "
            "CHECK (((verification_status)::text = ANY ((ARRAY['pending'::character "
            "varying, 'approved'::character varying, 'rejected'::character "
            "varying])::text[])))"
        )
    )
