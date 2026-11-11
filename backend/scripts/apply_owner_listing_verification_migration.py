"""Apply the 20261110 owner-listing verification migration to the app DB.

Safety rails:
* Records the pre-change constraint DDLs and row counts to
  backend/backups/20261110_owner_listing_verification_backup.json.
* Refuses to run when any verification table holds rows (they were verified
  empty on 2026-11-10; re-binding a populated legacy table would strand rows).
* Read-only against fyp.rental_properties data (only the CHECK constraint is
  replaced; no row is modified or deleted).
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import create_engine, text

from sitewise.core.config import settings

BACKUP_PATH = (
    Path(__file__).resolve().parent.parent / "backups" /
    "20261110_owner_listing_verification_backup.json"
)
REBIND = ("property_verification", "verification_document", "verification_audit")
NEW_CHECK = (
    "((verification_status)::text = ANY (ARRAY['draft'::character varying, "
    "'pending'::character varying, 'approved'::character varying, "
    "'rejected'::character varying]::text[]))"
)


def constraint_ddl(conn, table: str) -> dict:
    rows = conn.execute(
        text(
            "SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint "
            "WHERE conrelid = CAST(:t AS regclass) AND contype = 'f'"
        ),
        {"t": table},
    ).fetchall()
    return {name: definition for name, definition in rows}


def main() -> None:
    engine = create_engine(settings.database_url)
    with engine.begin() as conn:
        backup = {
            "captured_at": datetime.now(timezone.utc).isoformat(),
            "database": str(settings.database_url).split("@")[-1],
            "row_counts": {
                t: int(conn.execute(text(f"SELECT count(*) FROM {t}")).scalar_one())
                for t in (*REBIND, "fyp.rental_properties")
            },
            "fk_constraints_before": {t: constraint_ddl(conn, t) for t in REBIND},
            "rental_properties_status_check_before": conn.execute(
                text(
                    "SELECT pg_get_constraintdef(oid) FROM pg_constraint "
                    "WHERE conrelid = 'fyp.rental_properties'::regclass "
                    "AND conname = 'rental_properties_verification_status_check'"
                )
            ).scalar_one(),
        }

        for table in REBIND:
            if backup["row_counts"][table] > 0:
                raise SystemExit(
                    f"ABORT: {table} holds {backup['row_counts'][table]} rows. "
                    "Back up and migrate them before rebinding."
                )

        BACKUP_PATH.parent.mkdir(parents=True, exist_ok=True)
        BACKUP_PATH.write_text(json.dumps(backup, indent=2))
        print(f"backup written: {BACKUP_PATH}")

        conn.execute(
            text(
                "ALTER TABLE fyp.rental_properties "
                "DROP CONSTRAINT rental_properties_verification_status_check"
            )
        )
        conn.execute(
            text(
                "ALTER TABLE fyp.rental_properties "
                "ADD CONSTRAINT rental_properties_verification_status_check "
                f"CHECK {NEW_CHECK}"
            )
        )

        for table in REBIND:
            name = f"{table}_property_id_fkey"
            conn.execute(text(f"ALTER TABLE {table} DROP CONSTRAINT {name}"))
            conn.execute(
                text(f"ALTER TABLE {table} ALTER COLUMN property_id TYPE BIGINT")
            )
            conn.execute(
                text(
                    f"ALTER TABLE {table} ADD CONSTRAINT {name} "
                    "FOREIGN KEY (property_id) REFERENCES fyp.rental_properties(id)"
                )
            )

        print("migration applied")

    # Post-conditions (fresh connection, read-only).
    with engine.connect() as conn:
        for table in REBIND:
            ddl = constraint_ddl(conn, table)[f"{table}_property_id_fkey"]
            assert "fyp.rental_properties" in ddl, (table, ddl)
            print(f"{table}: {ddl}")
        check = conn.execute(
            text(
                "SELECT pg_get_constraintdef(oid) FROM pg_constraint "
                "WHERE conrelid = 'fyp.rental_properties'::regclass "
                "AND conname = 'rental_properties_verification_status_check'"
            )
        ).scalar_one()
        assert "'draft'" in check
        print(f"rental_properties check: {check}")
        # A draft insert must now be legal: verify via rollback-only probe.
        with conn.begin_nested():
            conn.execute(
                text(
                    "INSERT INTO fyp.rental_properties "
                    "(name, verification_status, is_published) VALUES "
                    "('__migration_probe__', 'draft', false)"
                )
            )
        conn.rollback()
        print("draft-status insert probe: OK (rolled back)")


if __name__ == "__main__":
    main()
