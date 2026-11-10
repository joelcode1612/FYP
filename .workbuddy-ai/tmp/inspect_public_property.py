"""Phase 1: read-only inspection of public.property dependencies."""

from __future__ import annotations

from sqlalchemy import create_engine, text

from sitewise.core.config import settings

engine = create_engine(settings.database_url, pool_pre_ping=True)

QUERIES = [
    ("row counts",
     """SELECT
          (SELECT count(*) FROM public.property) AS public_property,
          (SELECT count(*) FROM fyp.rental_properties) AS fyp_rental,
          (SELECT count(*) FROM fyp.property_subject_links) AS subject_links,
          (SELECT count(*) FROM fyp.property_subject_links WHERE match_verified IS TRUE)
            AS verified_links"""),
    ("FKs referencing public.property (all schemas)",
     """SELECT conrelid::regclass AS child_table, conname, pg_get_constraintdef(oid) AS def
        FROM pg_constraint
        WHERE confrelid = 'public.property'::regclass AND contype = 'f'"""),
    ("FKs FROM public.property (outbound)",
     """SELECT conname, pg_get_constraintdef(oid) AS def
        FROM pg_constraint
        WHERE conrelid = 'public.property'::regclass AND contype = 'f'"""),
    ("views/matviews depending on public.property",
     """SELECT DISTINCT dependent_ns.nspname AS view_schema, dependent_view.relname AS view_name,
              dependent_view.relkind
       FROM pg_depend
       JOIN pg_rewrite ON pg_depend.objid = pg_rewrite.oid
       JOIN pg_class AS dependent_view ON pg_rewrite.ev_class = dependent_view.oid
       JOIN pg_namespace AS dependent_ns ON dependent_view.relnamespace = dependent_ns.oid
       WHERE pg_depend.refobjid = 'public.property'::regclass"""),
    ("triggers on public.property",
     """SELECT trigger_name, action_timing, event_manipulation
        FROM information_schema.triggers WHERE event_object_table = 'property'"""),
    ("routines referencing public.property",
     """SELECT n.nspname, p.proname
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE pg_get_functiondef(p.oid) ILIKE '%property.property_id%'
           OR pg_get_functiondef(p.oid) ILIKE '%FROM property %'"""),
    ("indexes on public.property",
     """SELECT indexname, indexdef FROM pg_indexes WHERE schemaname='public'
        AND tablename='property'"""),
    ("public.property columns",
     """SELECT column_name, data_type, is_nullable FROM information_schema.columns
        WHERE table_schema='public' AND table_name='property' ORDER BY ordinal_position"""),
    ("candidate child tables: row counts",
     """SELECT 'public.property_photo' t, count(*) FROM public.property_photo
        UNION ALL SELECT 'public.property_feature', count(*) FROM public.property_feature
        UNION ALL SELECT 'public.property_geospatial_feature', count(*) FROM public.property_geospatial_feature
        UNION ALL SELECT 'public.property_foot_traffic', count(*) FROM public.property_foot_traffic
        UNION ALL SELECT 'public.nearby_competitor', count(*) FROM public.nearby_competitor
        UNION ALL SELECT 'public.recommendation_result', count(*) FROM public.recommendation_result
        UNION ALL SELECT 'public.virtual_tour', count(*) FROM public.virtual_tour
        UNION ALL SELECT 'public.ai_explanation', count(*) FROM public.ai_explanation
        UNION ALL SELECT 'public.property_verification', count(*) FROM public.property_verification
        UNION ALL SELECT 'public.verification_document', count(*) FROM public.verification_document
        UNION ALL SELECT 'public.verification_audit', count(*) FROM public.verification_audit
        UNION ALL SELECT 'public.address', count(*) FROM public.address
        UNION ALL SELECT 'public.users', count(*) FROM public.users"""),
]

with engine.connect() as conn:
    for label, sql in QUERIES:
        print(f"=== {label}")
        try:
            rows = conn.execute(text(sql)).fetchall()
            if not rows:
                print("   (none)")
            for row in rows:
                print("   ", tuple(row))
        except Exception as exc:  # noqa: BLE001
            print("   ERROR:", type(exc).__name__, str(exc)[:160])
            conn.rollback()
        print()
