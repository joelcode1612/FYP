"""Read-only schema probe for the ownership/agent-management audit.

Connects through the ACTIVE FastAPI settings (sitewise.core.config) and runs
SELECT-only introspection. Session is forced READ ONLY as a hard guarantee.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from sqlalchemy import create_engine, text

from sitewise.core.config import settings

OUT = Path(__file__).parent / "_audit_schema.json"


def main() -> None:
    url = settings.database_url
    # Never print credentials.
    safe = url.split("@")[-1] if "@" in url else url
    print(f"ACTIVE DATABASE_URL target: {safe}")

    engine = create_engine(url)
    with engine.connect() as conn:
        conn.execute(text("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY"))
        conn.execute(text("BEGIN"))

        db = conn.execute(text("SELECT current_database(), current_schema()")).one()
        print(f"current_database={db[0]} current_schema={db[1]}")

        tables = conn.execute(text(
            "SELECT table_schema, table_name FROM information_schema.tables "
            "WHERE table_schema NOT IN ('pg_catalog','information_schema') "
            "ORDER BY table_schema, table_name"
        )).all()
        print(f"total tables: {len(tables)}")

        targets = [
            "rental_properties", "agent_listing_assignment", "users", "agent",
            "property", "property_subject_links", "listing_verification",
            "property_verification", "company", "role_change_audit",
            "staff_invitations", "saved_properties",
        ]
        cols = conn.execute(text(
            "SELECT table_schema, table_name, column_name, data_type, is_nullable, column_default "
            "FROM information_schema.columns "
            "WHERE table_name = ANY(:names) "
            "AND table_schema NOT IN ('pg_catalog','information_schema') "
            "ORDER BY table_schema, table_name, ordinal_position"
        ), {"names": targets}).mappings().all()

        constraints = conn.execute(text(
            "SELECT tc.table_schema, tc.table_name, tc.constraint_type, tc.constraint_name, "
            "kcu.column_name, ccu.table_schema AS ref_schema, ccu.table_name AS ref_table, "
            "ccu.column_name AS ref_column "
            "FROM information_schema.table_constraints tc "
            "JOIN information_schema.key_column_usage kcu "
            "  ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema "
            "LEFT JOIN information_schema.constraint_column_usage ccu "
            "  ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema "
            "WHERE tc.table_name = ANY(:names) "
            "AND tc.constraint_type IN ('PRIMARY KEY','FOREIGN KEY','UNIQUE') "
            "AND tc.table_schema NOT IN ('pg_catalog','information_schema') "
            "ORDER BY tc.table_schema, tc.table_name, tc.constraint_type"
        ), {"names": targets}).mappings().all()

        indexes = conn.execute(text(
            "SELECT schemaname, tablename, indexname, indexdef FROM pg_indexes "
            "WHERE tablename = ANY(:names) ORDER BY tablename, indexname"
        ), {"names": targets}).mappings().all()

        payload = {
            "database": db[0],
            "tables": [{"schema": r[0], "table": r[1]} for r in tables],
            "columns": [dict(r) for r in cols],
            "constraints": [dict(r) for r in constraints],
            "indexes": [dict(r) for r in indexes],
        }
        OUT.write_text(json.dumps(payload, indent=2, default=str), encoding="utf-8")
        print(f"wrote {OUT}")

        # Compact console summary: schemas + target table locations.
        schemas = sorted({r[0] for r in tables})
        print(f"schemas: {schemas}")
        for r in tables:
            if r[1] in targets:
                print(f"  found: {r[0]}.{r[1]}")
        conn.execute(text("ROLLBACK"))


if __name__ == "__main__":
    sys.exit(main())