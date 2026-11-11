"""Read-only inspection of the live sitesense DB for the Add Property task."""

from __future__ import annotations

from sqlalchemy import create_engine, text

from sitewise.core.config import settings

engine = create_engine(settings.database_url, pool_pre_ping=True)

QUERIES = [
    ("fyp.rental_properties columns",
     """SELECT column_name, data_type, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema='fyp' AND table_name='rental_properties'
        ORDER BY ordinal_position"""),
    ("fyp.rental_properties status check constraints",
     """SELECT conname, pg_get_constraintdef(oid) AS def
        FROM pg_constraint
        WHERE conrelid = 'fyp.rental_properties'::regclass
          AND contype IN ('c','f','u','p')"""),
    ("public.property exists?",
     """SELECT count(*) FROM information_schema.tables
        WHERE table_schema='public' AND table_name='property'"""),
    ("property_verification columns + FKs",
     """SELECT c.column_name, c.data_type
        FROM information_schema.columns c
        WHERE c.table_schema='public' AND c.table_name='property_verification'
        ORDER BY c.ordinal_position"""),
    ("property_verification FK targets",
     """SELECT conname, pg_get_constraintdef(oid) AS def
        FROM pg_constraint
        WHERE conrelid = 'property_verification'::regclass AND contype='f'"""),
    ("verification_document FK targets",
     """SELECT conname, pg_get_constraintdef(oid) AS def
        FROM pg_constraint
        WHERE conrelid = 'verification_document'::regclass AND contype='f'"""),
    ("verification_audit FK targets",
     """SELECT conname, pg_get_constraintdef(oid) AS def
        FROM pg_constraint
        WHERE conrelid = 'verification_audit'::regclass AND contype='f'"""),
    ("existing verification rows",
     "SELECT count(*) FROM property_verification"),
    ("existing verification docs",
     "SELECT count(*) FROM verification_document"),
    ("rental_properties row count by status",
     """SELECT verification_status, is_published, count(*)
        FROM fyp.rental_properties GROUP BY 1,2 ORDER BY 1"""),
    ("rental_properties owner_user_id populated",
     """SELECT count(*) FILTER (WHERE owner_user_id IS NOT NULL) AS with_owner,
              count(*) FILTER (WHERE source_record_type IS NOT NULL) AS with_source
        FROM fyp.rental_properties"""),
    ("public.property row count",
     "SELECT count(*) FROM public.property"),
    ("fyp tables list",
     """SELECT table_name FROM information_schema.tables
        WHERE table_schema='fyp' ORDER BY 1"""),
    ("property_photos table?",
     """SELECT table_name FROM information_schema.tables
        WHERE table_name ILIKE '%photo%' OR table_name ILIKE '%image%'
        ORDER BY 1"""),
]

with engine.connect() as conn:
    for label, sql in QUERIES:
        print(f"=== {label} ===")
        try:
            rows = conn.execute(text(sql)).fetchall()
            for row in rows:
                print("  ", tuple(row))
        except Exception as exc:  # noqa: BLE001
            print("  ERROR:", type(exc).__name__, str(exc)[:200])
            conn.rollback()
        print()
