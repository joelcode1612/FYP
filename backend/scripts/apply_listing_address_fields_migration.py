"""Apply migration 0006 (listing postcode + address-validation evidence).

Why a script instead of ``alembic upgrade head``: revisions 0004 and 0005 were
applied out-of-band (see ``apply_owner_listing_verification_migration.py`` and
``apply_drop_legacy_property.py``) and the ``alembic_version`` row still says
``0003``, so a normal upgrade would try to re-run them. This script applies
ONLY the additive 0006 DDL, after validating the target.

Safety rules, all enforced before any DDL:

* the connected database must be the application database, never the read-only
  analytics database;
* ``fyp.rental_properties`` must exist and must not be empty;
* every column is nullable and added with ``IF NOT EXISTS`` — no row rewrite,
  no column drop, no data loss;
* the whole migration runs in one transaction, so a failure leaves the schema
  exactly as it was.

Rollback SQL is printed at the end (and lives in the Alembic ``downgrade()``).
"""

from __future__ import annotations

import sys

from sqlalchemy import text

from sitewise.db.session import engine

COLUMNS = {
    "postcode": "varchar(5)",
    "address_validation_status": "varchar(24)",
    "address_formatted": "text",
    "address_validated_at": "timestamp with time zone",
}

CHECK_NAME = "rental_properties_address_validation_status_check"
INDEX_NAME = "ix_rental_properties_postcode"


def main() -> int:
    with engine.begin() as conn:
        db_name = conn.execute(text("SELECT current_database()")).scalar_one()
        if "analytics" in str(db_name).lower():
            print(f"REFUSING: {db_name!r} looks like the analytics database.")
            return 2

        table = conn.execute(
            text("SELECT to_regclass('fyp.rental_properties')")
        ).scalar()
        if table is None:
            print("REFUSING: fyp.rental_properties does not exist.")
            return 2

        rows = conn.execute(
            text("SELECT count(*) FROM fyp.rental_properties")
        ).scalar_one()
        if int(rows) == 0:
            print("REFUSING: fyp.rental_properties is empty — wrong target?")
            return 2

        existing = {
            row[0]
            for row in conn.execute(
                text(
                    "SELECT column_name FROM information_schema.columns "
                    "WHERE table_schema = 'fyp' "
                    "AND table_name = 'rental_properties' "
                    "AND column_name = ANY(:names)"
                ),
                {"names": list(COLUMNS)},
            ).all()
        }
        if existing:
            print(f"SKIP: columns already present: {sorted(existing)}")
            return 0

        print(f"Target: {db_name} · fyp.rental_properties · {rows} rows")
        for column, sql_type in COLUMNS.items():
            conn.execute(
                text(
                    "ALTER TABLE fyp.rental_properties "
                    f"ADD COLUMN IF NOT EXISTS {column} {sql_type}"
                )
            )
            print(f"  + {column} {sql_type}")

        conn.execute(
            text(
                f"CREATE INDEX IF NOT EXISTS {INDEX_NAME} "
                "ON fyp.rental_properties (postcode)"
            )
        )
        conn.execute(
            text(
                "DO $$ BEGIN "
                "IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = "
                f"'{CHECK_NAME}') THEN "
                "  ALTER TABLE fyp.rental_properties ADD CONSTRAINT "
                f"  {CHECK_NAME} CHECK (address_validation_status IS NULL OR "
                "  address_validation_status IN "
                "  ('validated', 'partially_validated', 'unconfirmed')); "
                "END IF; END $$;"
            )
        )

        applied = {
            row[0]
            for row in conn.execute(
                text(
                    "SELECT column_name FROM information_schema.columns "
                    "WHERE table_schema = 'fyp' "
                    "AND table_name = 'rental_properties' "
                    "AND column_name = ANY(:names)"
                ),
                {"names": list(COLUMNS)},
            ).all()
        }
        missing = set(COLUMNS) - applied
        if missing:
            raise SystemExit(f"FAILED: columns missing after DDL: {sorted(missing)}")
        print("OK: all four columns, index and CHECK constraint are present.")

    print(
        "\nRollback:\n"
        "  ALTER TABLE fyp.rental_properties "
        f"DROP CONSTRAINT IF EXISTS {CHECK_NAME};\n"
        f"  DROP INDEX IF EXISTS fyp.{INDEX_NAME};\n"
        "  ALTER TABLE fyp.rental_properties "
        "DROP COLUMN IF EXISTS address_validated_at, "
        "DROP COLUMN IF EXISTS address_formatted, "
        "DROP COLUMN IF EXISTS address_validation_status, "
        "DROP COLUMN IF EXISTS postcode;"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
