"""Apply migration 0008 (durable recommendation persistence).

Why a script instead of ``alembic upgrade head``: revisions 0004-0007 were
applied out-of-band (see ``apply_owner_listing_verification_migration.py``,
``apply_drop_legacy_property.py``, ``apply_listing_address_fields_migration.py``)
and the ``alembic_version`` row still says ``0003``, so a normal upgrade would
try to re-run them. This script applies ONLY the additive 0008 DDL, after
validating the target.

Safety rules, all enforced before any DDL:

* the connected database must be the application database, never the read-only
  analytics database;
* ``recommendation_result`` must exist and must be EMPTY - the retype of
  ``property_id`` from INTEGER to TEXT loses no data only on an empty table
  (any other state is refused, never auto-rewritten);
* every added column is nullable (``IF NOT EXISTS``) - no row rewrite, no
  column drop, no data loss;
* the whole migration runs in one transaction, so a failure leaves the schema
  exactly as it was.

Rollback SQL is printed at the end (and lives in the Alembic ``downgrade()``).
"""

from __future__ import annotations

import sys

from sqlalchemy import text

from sitewise.db.session import engine

_TABLE = "recommendation_result"
_USER_FK = "recommendation_result_user_id_fkey"

ADDED_COLUMNS = {
    "batch_id": "uuid",
    "pu_association_score": "numeric(8,6)",
    "preference_match_score": "numeric(8,6)",
    "scoring_version": "varchar(64)",
    "model_name": "varchar(64)",
    "payload": "jsonb",
    "shap": "jsonb",
}


def main() -> int:
    with engine.begin() as conn:
        db_name = conn.execute(text("SELECT current_database()")).scalar_one()
        if "analytics" in str(db_name).lower():
            print(f"REFUSING: {db_name!r} looks like the analytics database.")
            return 2

        table = conn.execute(
            text("SELECT to_regclass('public.recommendation_result')")
        ).scalar()
        if table is None:
            print("REFUSING: public.recommendation_result does not exist.")
            return 2

        rows = conn.execute(
            text(f"SELECT count(*) FROM {_TABLE}")
        ).scalar_one()
        if int(rows) != 0:
            print(
                f"REFUSING: {_TABLE} holds {rows} rows; the property_id retype "
                "is only loss-free on an empty table. Migrate manually."
            )
            return 2

        prop_type = conn.execute(
            text(
                "SELECT data_type FROM information_schema.columns "
                "WHERE table_schema='public' AND table_name=:t AND column_name='property_id'"
            ),
            {"t": _TABLE},
        ).scalar_one()
        if prop_type == "integer":
            conn.execute(
                text(f"ALTER TABLE {_TABLE} ALTER COLUMN property_id TYPE text")
            )
            print("property_id: integer -> text")
        else:
            print(f"property_id already {prop_type}; skipped")

        existing_cols = {
            r[0]
            for r in conn.execute(
                text(
                    "SELECT column_name FROM information_schema.columns "
                    "WHERE table_schema='public' AND table_name=:t"
                ),
                {"t": _TABLE},
            ).fetchall()
        }
        for name, ddl in ADDED_COLUMNS.items():
            if name in existing_cols:
                print(f"column {name} already present; skipped")
                continue
            conn.execute(
                text(
                    f"ALTER TABLE {_TABLE} ADD COLUMN IF NOT EXISTS {name} {ddl}"
                )
            )
            print(f"column {name} added")

        fk = conn.execute(
            text(
                "SELECT conname FROM pg_constraint "
                "WHERE conrelid = 'public.recommendation_result'::regclass "
                "AND conname = :name"
            ),
            {"name": _USER_FK},
        ).scalar()
        if fk:
            conn.execute(
                text(f"ALTER TABLE {_TABLE} DROP CONSTRAINT {_USER_FK}")
            )
            print("old user FK dropped")
        conn.execute(
            text(
                f"ALTER TABLE {_TABLE} ADD CONSTRAINT {_USER_FK} "
                "FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE"
            )
        )
        print("user FK recreated with ON DELETE CASCADE")

        conn.execute(
            text(
                f"CREATE INDEX IF NOT EXISTS ix_recommendation_result_user_batch "
                f"ON {_TABLE} (user_id, batch_id)"
            )
        )
        conn.execute(
            text(
                f"CREATE INDEX IF NOT EXISTS ix_recommendation_result_batch "
                f"ON {_TABLE} (batch_id)"
            )
        )
        print("indexes ensured")

    print()
    print("Rollback SQL:")
    print(f"  ALTER TABLE {_TABLE} DROP CONSTRAINT {_USER_FK};")
    print(
        f"  ALTER TABLE {_TABLE} ADD CONSTRAINT {_USER_FK} "
        "FOREIGN KEY (user_id) REFERENCES users(user_id);"
    )
    print(
        f"  DROP INDEX IF EXISTS ix_recommendation_result_user_batch, "
        "ix_recommendation_result_batch;"
    )
    print(
        f"  ALTER TABLE {_TABLE} DROP COLUMN IF EXISTS batch_id, "
        "DROP COLUMN IF EXISTS pu_association_score, "
        "DROP COLUMN IF EXISTS preference_match_score, "
        "DROP COLUMN IF EXISTS scoring_version, "
        "DROP COLUMN IF EXISTS model_name, "
        "DROP COLUMN IF EXISTS payload, DROP COLUMN IF EXISTS shap;"
    )
    print(f"  ALTER TABLE {_TABLE} ALTER COLUMN property_id TYPE integer USING property_id::integer;")
    return 0


if __name__ == "__main__":
    sys.exit(main())
