
#!/usr/bin/env python3
"""Guarded local execution of the existing M2 SQL migration.

Default: read-only validation.
--apply: execute only after explicit approval and prerequisite checks.

Does not create public.users.
Does not seed questionnaire data.
Does not establish Supabase migration tracking.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from sqlalchemy import create_engine, inspect, text
from sqlalchemy.engine import make_url

BACKEND = Path(__file__).resolve().parents[1]

if Path.cwd().resolve() != BACKEND:
    raise SystemExit("ERROR: Run from backend/")

from sitewise.core.config import settings  # noqa: E402


MIGRATION = (
    BACKEND
    / "supabase"
    / "migrations"
    / "20261107133000_m2_upstream_foundation.sql"
)

M2_TABLES = {
    "m2_instrument_versions",
    "m2_item_versions",
    "m2_assessments",
    "m2_answer_revisions",
    "m2_bdj_evaluations",
    "m2_bdj_findings",
    "m2_review_events",
    "m2_confirmation_snapshots",
    "m2_confirmed_uncertainties",
}



def inspect_target(engine, expected_database):
    errors = []

    with engine.connect() as conn:
        conn.execute(text("SET TRANSACTION READ ONLY"))

        actual_db = conn.execute(
            text("SELECT current_database()")
        ).scalar_one()

        if actual_db == expected_database:
            print("[PASS] V01: Database target verified")
        else:
            print("[FAIL] V01: Wrong database target")
            errors.append("DATABASE_MISMATCH")

        inspector = inspect(conn)
        existing = set(
            inspector.get_table_names(schema="public")
        )

        if "users" not in existing:
            print("[FAIL] V02: public.users missing")
            errors.append("USERS_TABLE_MISSING")
            print("[BLOCKED] V03: Cannot validate users PK")
        else:
            print("[PASS] V02: public.users exists")

            columns = {
                c["name"]: c
                for c in inspector.get_columns(
                    "users", schema="public"
                )
            }

            pk = inspector.get_pk_constraint(
                "users", schema="public"
            )

            user_id = columns.get("user_id")
            valid = (
                user_id is not None
                and str(user_id["type"]).upper() == "UUID"
                and user_id["nullable"] is False
                and pk.get("constrained_columns") == ["user_id"]
            )

            if valid:
                print("[PASS] V03: UUID primary key verified")
            else:
                print("[FAIL] V03: Invalid users PK")
                errors.append("USERS_PRIMARY_KEY_INVALID")

        present_m2 = M2_TABLES & existing

        if present_m2:
            print("[FAIL] V04: M2 tables already exist")
            errors.append("M2_SCHEMA_DRIFT")
            for name in sorted(present_m2):
                print("  EXISTING_TABLE:", name)
        else:
            print("[PASS] V04: No conflicting M2 tables")

        for tracker in (
            "public.alembic_version",
            "supabase_migrations.schema_migrations",
        ):
            present = conn.execute(
                text("SELECT to_regclass(:name)"),
                {"name": tracker},
            ).scalar()

            print(
                "[INFO] V05: Migration tracker",
                tracker,
                "PRESENT" if present else "ABSENT",
            )

    if errors:
        print("PREFLIGHT_FAILED")
        for error in errors:
            print("BLOCKER:", error)

        raise RuntimeError(
            "Migration prerequisites failed. "
            "No migration executed."
        )

    print("DATABASE_PREREQUISITES_PASS")
