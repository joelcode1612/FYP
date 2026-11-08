
#!/usr/bin/env python3
"""Sitewise PostgreSQL preflight and guarded local schema bootstrap.

Default: READ ONLY.
--create-tables: create declared tables in an EMPTY local development DB.

NOT a replacement for Alembic migrations.
Does not seed questionnaire data.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

from sqlalchemy import create_engine, inspect, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import SQLAlchemyError

BACKEND = Path(__file__).resolve().parents[1]

if Path.cwd().resolve() != BACKEND:
    raise SystemExit("Run from the backend/ directory.")

from sitewise.core.config import settings  # noqa: E402


EXPECTED_TABLES = [
    "users",
    "m2_instrument_versions",
    "m2_item_versions",
    "m2_assessments",
    "m2_answer_revisions",
    "m2_bdj_evaluations",
    "m2_bdj_findings",
    "m2_review_events",
    "m2_confirmation_snapshots",
    "m2_confirmed_uncertainties",
]


def load_table_definitions():
    """Load existing project models without inventing table schemas."""
    from sqlmodel import SQLModel

    import sitewise.db.models  # noqa: F401
    from sitewise.db.models.m2_schema import instruments, items

    registries = [
        SQLModel.metadata,
        instruments.metadata,
        items.metadata,
    ]

    declared = {}

    for metadata in registries:
        for table in metadata.tables.values():
            if table.name not in EXPECTED_TABLES:
                continue

            if table.schema not in (None, "public"):
                raise RuntimeError(
                    f"Unexpected schema for {table.name}"
                )

            previous = declared.get(table.name)

            if previous is not None and previous is not table:
                raise RuntimeError(
                    f"Conflicting definitions for {table.name}"
                )

            declared[table.name] = table

    missing = set(EXPECTED_TABLES) - set(declared)

    if missing:
        raise RuntimeError(
            "Missing SQLAlchemy model definitions: "
            + ", ".join(sorted(missing))
        )

    # Require one shared metadata registry for dependency ordering.
    metadata_ids = {id(t.metadata) for t in declared.values()}

    if len(metadata_ids) != 1:
        raise RuntimeError(
            "M2 models use multiple metadata registries. "
            "Reconcile the schema before table creation."
        )

    metadata = next(iter(declared.values())).metadata
    return metadata, declared


def inspect_database(conn):
    database, schema, role = conn.execute(
        text(
            "SELECT current_database(), "
            "current_schema(), current_user"
        )
    ).one()

    print("TARGET database:", database)
    print("TARGET schema:", schema)
    print("TARGET role:", role)

    existing = set(
        inspect(conn).get_table_names(schema="public")
    )

    for name in EXPECTED_TABLES:
        print(
            "TABLE",
            name,
            "PRESENT" if name in existing else "ABSENT",
        )

    for name in (
        "public.alembic_version",
        "supabase_migrations.schema_migrations",
    ):
        present = conn.execute(
            text("SELECT to_regclass(:name)"),
            {"name": name},
        ).scalar()

        print(
            "MIGRATION_TRACKER",
            name,
            "PRESENT" if present is not None else "ABSENT",
        )

    return database, existing


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--create-tables",
        action="store_true",
        help="Bootstrap a completely empty local development DB",
    )

    parser.add_argument(
        "--confirm-database",
        help="Exact database name required for bootstrap",
    )

    parser.add_argument(
        "--backup-confirmed",
        action="store_true",
        help="A restorable backup has been verified",
    )

    args = parser.parse_args()

    url = make_url(settings.database_url)

    print("CONFIG: dialect:", url.get_backend_name())
    print("CONFIG: host:", url.host)
    print("CONFIG: port:", url.port)
    print("CONFIG: database:", url.database)

    if url.get_backend_name() != "postgresql":
        raise SystemExit("DENIED: PostgreSQL required.")

    engine = create_engine(
        url,
        pool_pre_ping=True,
        connect_args={"connect_timeout": 6},
    )

    try:
        if not args.create_tables:
            with engine.connect() as conn:
                conn.execute(text("SET TRANSACTION READ ONLY"))
                print(
                    "CONNECTION_OK:",
                    conn.execute(text("SELECT 1")).scalar_one(),
                )
                inspect_database(conn)

            print("READ_ONLY_PREFLIGHT_COMPLETE")
            return

        # --------- Explicit creation mode ---------

        if url.host not in ("localhost", "127.0.0.1"):
            raise RuntimeError(
                "DENIED: Bootstrap restricted to local PostgreSQL."
            )

        if (
            not args.confirm_database
            or args.confirm_database != url.database
        ):
            raise RuntimeError(
                "DENIED: Explicit matching database name required."
            )

        if not args.backup_confirmed:
            raise RuntimeError(
                "DENIED: Verified database backup required."
            )

        # Verify that all ten authoritative models exist
        # before any DDL statement is executed.
        metadata, declared = load_table_definitions()

        with engine.begin() as conn:
            actual_db = conn.execute(
                text("SELECT current_database()")
            ).scalar_one()

            if actual_db != args.confirm_database:
                raise RuntimeError(
                    "DENIED: Connected database mismatch."
                )

            existing = set(
                inspect(conn).get_table_names(schema="public")
            )

            if existing:
                raise RuntimeError(
                    "DENIED: Database already contains tables. "
                    "Use a reviewed Alembic migration instead."
                )

            other_schemas = conn.execute(
                text(
                    "SELECT schema_name "
                    "FROM information_schema.schemata "
                    "WHERE schema_name NOT IN "
                    "('public', 'information_schema', "
                    "'pg_catalog', 'pg_toast') "
                    "AND schema_name NOT LIKE 'pg_temp_%' "
                    "AND schema_name NOT LIKE 'pg_toast_temp_%'"
                )
            ).scalars().all()

            if other_schemas:
                raise RuntimeError(
                    "DENIED: Additional schemas exist. "
                    "Database requires manual inspection."
                )

            print("CREATING_TABLES...")

            metadata.create_all(
                bind=conn,
                tables=[
                    declared[name] for name in EXPECTED_TABLES
                ],
                checkfirst=True,
            )

        # Verify after transaction commits.
        with engine.connect() as conn:
            conn.execute(text("SET TRANSACTION READ ONLY"))
            _, existing = inspect_database(conn)

        missing = set(EXPECTED_TABLES) - existing

        if missing:
            raise RuntimeError(
                "POSTCHECK_FAILED: "
                + ", ".join(sorted(missing))
            )

        print("LOCAL_BOOTSTRAP_COMPLETE")
        print("NOTE: No migration history was established.")
        print("NOTE: No M2 questionnaire records were seeded.")

    except (SQLAlchemyError, RuntimeError, ImportError) as exc:
        # Do not print raw exception messages that may contain URLs.
        if isinstance(exc, SQLAlchemyError):
            print("DATABASE_ERROR:", type(exc).__name__)
        else:
            print("ERROR:", str(exc))
        sys.exit(1)

    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
