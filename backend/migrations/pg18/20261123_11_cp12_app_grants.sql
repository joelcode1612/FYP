-- =====================================================================
-- 20261123_11_cp12_app_grants.sql
-- =====================================================================
-- Purpose
--   Grant the application roles the privileges the assessment path actually
--   needs on the ``cp12`` barrier schema.
--
--   Measured failure without this (POST /api/v1/assessments/):
--     psycopg2.errors.InsufficientPrivilege: permission denied for table operations
--       assessments.py:66 -> assessment_service.create_or_resume:620
--         -> get_owned:590 -> assessment_discard_service.assert_available:90
--           -> SELECT EXISTS(... FROM cp12.operations ...)
--
--   ``assert_available`` runs on the *market* connection (DATABASE_URL,
--   role ``sitewise_e2e``) and reads ``cp12.operations`` directly, while the
--   discard coordinator calls the ``cp12.*`` functions on both the market and
--   the DSS connection (role ``p1_m2_runtime``). Before this file only
--   ``postgres`` could read those tables, so every assessment create/resume
--   failed even though the assessment row itself had been written.
--
-- Scope of the grant
--   USAGE on the schema, SELECT on its tables, EXECUTE on its functions.
--   No DDL, no ownership, and deliberately no write privileges: the barrier is
--   a read model for the application, and the discard workflow mutates it
--   through SECURITY DEFINER functions, not through direct DML.
--
-- Safety
--   Only a ``project1_pg18_%`` database on port 5544 may run this file.
-- =====================================================================

DO $$
DECLARE
    db   text := current_database();
    port int  := inet_server_port();
    r    text;
BEGIN
    IF db NOT LIKE 'project1\_pg18\_%' THEN
        RAISE EXCEPTION 'REFUSED: % is not a project1_pg18_* database', db;
    END IF;
    IF port <> 5544 THEN
        RAISE EXCEPTION 'REFUSED: port % is not the isolated PG18 cluster (5544)', port;
    END IF;
    IF to_regclass('cp12.operations') IS NULL THEN
        RAISE EXCEPTION 'REFUSED: cp12.operations is missing';
    END IF;

    FOREACH r IN ARRAY ARRAY['sitewise_e2e', 'p1_m2_runtime', 'p1ai_runtime']
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            RAISE NOTICE 'role % does not exist; skipped', r;
            CONTINUE;
        END IF;

        EXECUTE format('GRANT USAGE ON SCHEMA cp12 TO %I', r);
        EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA cp12 TO %I', r);
        EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA cp12 TO %I', r);
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES IN SCHEMA cp12 GRANT SELECT ON TABLES TO %I', r);
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES IN SCHEMA cp12 GRANT EXECUTE ON FUNCTIONS TO %I', r);
        RAISE NOTICE 'cp12 privileges granted to %', r;
    END LOOP;
END
$$;
