"""Apply the 20261110 legacy-property removal to the app database.

Safety rails (task Phase 5):
* Refuses to run unless public.property contains exactly zero rows.
* Writes a restorable backup FIRST: full CREATE TABLE DDL, the eight child
  FK constraint definitions, and row counts, to
  backend/backups/20261110_drop_legacy_property_backup.json.
* Drops only the eight empty child tables' FK constraints, then the parent
  with RESTRICT (never CASCADE).
* Never touches public.users, public.address, auth.users or any fyp.* table.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import create_engine, text

from sitewise.core.config import settings

BACKUP_PATH = (
    Path(__file__).resolve().parent.parent / "backups" /
    "20261110_drop_legacy_property_backup.json"
)
CHILD_FKS = (
    "ai_explanation",
    "nearby_competitor",
    "property_feature",
    "property_foot_traffic",
    "property_geospatial_feature",
    "property_photo",
    "recommendation_result",
    "virtual_tour",
)

# Exact CREATE TABLE reconstruction (columns verified against
# information_schema before the drop; kept in the backup for restore).
_PROPERTY_DDL = """
CREATE TABLE public.property (
    property_id integer NOT NULL,
    address_id uuid,
    district_id character varying(50),
    user_id uuid,
    company_name character varying(255),
    normalized_address character varying(255),
    property_type_normalized character varying(100),
    tenure character varying(50),
    floor_level character varying(50),
    unit_position character varying(50),
    built_up_area_sqft numeric,
    land_area_sqft numeric,
    frontage_ft numeric,
    depth_ft numeric,
    facing_direction character varying(50),
    bathroom_count integer,
    parking_spaces integer,
    title character varying(255),
    description text,
    status character varying(50),
    price numeric,
    bedrooms integer,
    year_built integer,
    CONSTRAINT property_pkey PRIMARY KEY (property_id),
    CONSTRAINT property_address_id_fkey FOREIGN KEY (address_id)
        REFERENCES public.address (address_id),
    CONSTRAINT property_district_id_fkey FOREIGN KEY (district_id)
        REFERENCES public.district_demographic (district_id),
    CONSTRAINT property_user_id_fkey FOREIGN KEY (user_id)
        REFERENCES public.users (user_id)
)
"""


def fk_definitions(conn) -> dict:
    rows = conn.execute(
        text(
            "SELECT conrelid::regclass::text AS child, conname, "
            "pg_get_constraintdef(oid) AS def FROM pg_constraint "
            "WHERE confrelid = 'public.property'::regclass AND contype = 'f'"
        )
    ).fetchall()
    return {name: {"child": child, "definition": definition}
            for child, name, definition in rows}


def main() -> None:
    engine = create_engine(settings.database_url)
    with engine.begin() as conn:
        count = int(
            conn.execute(text("SELECT count(*) FROM public.property")).scalar_one()
        )
        if count != 0:
            raise SystemExit(
                f"ABORT: public.property holds {count} rows. Back up and "
                "migrate them before removal."
            )

        backup = {
            "captured_at": datetime.now(timezone.utc).isoformat(),
            "database": str(settings.database_url).split("@")[-1],
            "public_property_row_count": count,
            "create_table_ddl": _PROPERTY_DDL,
            "child_fk_constraints": fk_definitions(conn),
            "row_counts": {
                table: int(conn.execute(
                    text(f"SELECT count(*) FROM {table}")
                ).scalar_one())
                for table in CHILD_FKS
            },
        }
        BACKUP_PATH.parent.mkdir(parents=True, exist_ok=True)
        BACKUP_PATH.write_text(json.dumps(backup, indent=2, default=str))
        print(f"backup written: {BACKUP_PATH}")

        for table in CHILD_FKS:
            conn.execute(
                text(
                    f"ALTER TABLE {table} DROP CONSTRAINT IF EXISTS "
                    f"{table}_property_id_fkey"
                )
            )
        conn.execute(text("DROP TABLE public.property RESTRICT"))
        print("public.property dropped (RESTRICT)")

    with engine.connect() as conn:
        exists = conn.execute(
            text(
                "SELECT count(*) FROM information_schema.tables "
                "WHERE table_schema='public' AND table_name='property'"
            )
        ).scalar_one()
        print("public.property exists after drop:", bool(exists))
        leftovers = conn.execute(
            text(
                "SELECT count(*) FROM pg_constraint c "
                "JOIN pg_class t ON t.oid = c.conrelid "
                "JOIN pg_namespace n ON n.oid = t.relnamespace "
                "WHERE t.relname = 'property' AND n.nspname = 'public'"
            )
        ).scalar_one()
        print("constraints on tables named public.property:", leftovers)
        for label, sql in (
            ("fyp.rental_properties", "SELECT count(*) FROM fyp.rental_properties"),
            ("fyp.property_subject_links", "SELECT count(*) FROM fyp.property_subject_links"),
            ("fyp.property_subject_links verified",
             "SELECT count(*) FROM fyp.property_subject_links WHERE match_verified IS TRUE"),
        ):
            print(label, "=", conn.execute(text(sql)).scalar_one())


if __name__ == "__main__":
    main()
