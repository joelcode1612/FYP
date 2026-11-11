"""Listing postcode + server-attested address-validation evidence.

Revision ID: 0006_listing_address_fields
Revises: 0005_drop_legacy_property
Create Date: 2026-11-10

Additive, nullable, reversible. No row is rewritten, no column is dropped and
no existing value is reinterpreted:

* ``postcode`` — the five-digit Malaysian postcode the Add Property form now
  collects. Stored as text so leading zeros (Perlis ``01000``) survive.
* ``address_validation_status`` — the verdict returned by Google Address
  Validation when the SERVER validated the listing address. Nullable: drafts
  and imported research rows legitimately have no verdict.
* ``address_formatted`` — Google's normalised single-line address.
* ``address_validated_at`` — when that verdict was obtained.

The columns are written only by the backend (``POST /listings`` and the
verification submit path); a client cannot claim a verdict of its own.
"""

from __future__ import annotations

import sqlalchemy as sa

from alembic import op

revision = "0006_listing_address_fields"
down_revision = "0005_drop_legacy_property"
branch_labels = None
depends_on = None

_ALLOWED = "('validated', 'partially_validated', 'unconfirmed')"


def upgrade() -> None:
    bind = op.get_bind()
    bind.execute(
        sa.text(
            "ALTER TABLE fyp.rental_properties "
            "ADD COLUMN IF NOT EXISTS postcode varchar(5)"
        )
    )
    bind.execute(
        sa.text(
            "ALTER TABLE fyp.rental_properties "
            "ADD COLUMN IF NOT EXISTS address_validation_status varchar(24)"
        )
    )
    bind.execute(
        sa.text(
            "ALTER TABLE fyp.rental_properties "
            "ADD COLUMN IF NOT EXISTS address_formatted text"
        )
    )
    bind.execute(
        sa.text(
            "ALTER TABLE fyp.rental_properties "
            "ADD COLUMN IF NOT EXISTS address_validated_at "
            "timestamp with time zone"
        )
    )
    bind.execute(
        sa.text(
            "CREATE INDEX IF NOT EXISTS ix_rental_properties_postcode "
            "ON fyp.rental_properties (postcode)"
        )
    )
    # Constraint creation is guarded: a re-run after a partial failure must not
    # abort the whole migration.
    bind.execute(
        sa.text(
            "DO $$ BEGIN "
            "IF NOT EXISTS ("
            "  SELECT 1 FROM pg_constraint "
            "  WHERE conname = 'rental_properties_address_validation_status_check'"
            ") THEN "
            "  ALTER TABLE fyp.rental_properties "
            "  ADD CONSTRAINT rental_properties_address_validation_status_check "
            f"  CHECK (address_validation_status IS NULL OR "
            f"         address_validation_status IN {_ALLOWED}); "
            "END IF; "
            "END $$;"
        )
    )


def downgrade() -> None:
    bind = op.get_bind()
    bind.execute(
        sa.text(
            "ALTER TABLE fyp.rental_properties "
            "DROP CONSTRAINT IF EXISTS "
            "rental_properties_address_validation_status_check"
        )
    )
    bind.execute(
        sa.text("DROP INDEX IF EXISTS fyp.ix_rental_properties_postcode")
    )
    for column in (
        "address_validated_at",
        "address_formatted",
        "address_validation_status",
        "postcode",
    ):
        bind.execute(
            sa.text(
                f"ALTER TABLE fyp.rental_properties DROP COLUMN IF EXISTS {column}"
            )
        )
