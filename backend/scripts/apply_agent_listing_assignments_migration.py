"""Apply migration 0010 (explicit agent listing assignments).

Why a script: ``alembic_version`` in this database still lags the migration
files (earlier revisions were applied out-of-band). This script applies ONLY
the additive 0010 DDL after validating the target.

Safety rules, all enforced before any DDL:

* the connected database must be the application database, never the
  read-only analytics database;
* ``fyp.rental_properties`` must exist and be non-empty (the FK target);
* the table is created ``IF NOT EXISTS`` with one FK to the real property
  primary key - no existing table, row or column is touched;
* everything runs in one transaction.

Rollback SQL is printed at the end.
"""

from __future__ import annotations

import sys

from sqlalchemy import text

from sitewise.db.session import engine

_TABLE = "agent_listing_assignment"


def main() -> int:
    with engine.begin() as conn:
        db_name = conn.execute(text("SELECT current_database()")).scalar_one()
        if "analytics" in str(db_name).lower():
            print(f"REFUSING: {db_name!r} looks like the analytics database.")
            return 2

        target = conn.execute(
            text("SELECT to_regclass('fyp.rental_properties')")
        ).scalar()
        if target is None:
            print("REFUSING: fyp.rental_properties does not exist.")
            return 2
        rows = conn.execute(text("SELECT count(*) FROM fyp.rental_properties")).scalar_one()
        if int(rows) == 0:
            print("REFUSING: fyp.rental_properties is empty - wrong target?")
            return 2

        exists = conn.execute(
            text("SELECT to_regclass('public.agent_listing_assignment')")
        ).scalar()
        if exists is not None:
            print("agent_listing_assignment already exists; nothing to do.")
            return 0

        conn.execute(
            text(
                f"""
                CREATE TABLE {_TABLE} (
                    listing_id BIGINT PRIMARY KEY,
                    agent_id INTEGER NOT NULL,
                    assigned_by_user_id UUID NULL,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    CONSTRAINT agent_listing_assignment_listing_id_fkey
                        FOREIGN KEY (listing_id)
                        REFERENCES fyp.rental_properties(id)
                        ON DELETE CASCADE
                )
                """
            )
        )
        conn.execute(
            text(
                f"CREATE INDEX IF NOT EXISTS ix_agent_listing_assignment_agent "
                f"ON {_TABLE} (agent_id)"
            )
        )
        print("agent_listing_assignment created with FK to fyp.rental_properties(id)")

    print()
    print("Rollback SQL:")
    print("  DROP TABLE IF EXISTS public.agent_listing_assignment;")
    return 0


if __name__ == "__main__":
    sys.exit(main())
