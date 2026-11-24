-- PROJECT1 PG18 isolated environment — application grants
-- Migration: 20261123_04_grants_app_role
-- Target:    project1_pg18_migrated_tests @ 127.0.0.1:5544
--
-- Why this file exists
-- --------------------
-- The baseline was dumped with ``--no-privileges`` so that the schema could be
-- reconstructed without dragging Dss's owner/ACL graph across. The consequence
-- is measured, not assumed:
--
--     information_schema.role_table_grants where grantee='sitewise_e2e'  -> 0
--     psql -U sitewise_e2e -c 'select count(*) from public.users'
--         -> ERROR: permission denied for table users
--
-- So the application role can open a connection and read nothing. This file
-- supplies the missing DML grants.
--
-- Least privilege, stated honestly
-- --------------------------------
-- Production reaches these tables as ``postgres`` (superuser), which is the
-- database-credential impersonation defect recorded in
-- ``DATABASE_SECURITY_AUDIT.md`` §C3. This environment deliberately does not
-- repeat that: ``sitewise_e2e`` is NOSUPERUSER and NOBYPASSRLS, so every RLS
-- policy still applies to it. Where a table is RLS-protected and its policy is
-- expressed through ``project1_actor()``, that role sees zero rows — which is
-- correct, because those surfaces are meant to be reached through
-- ``p1_m2_runtime``, not through the ORM role.
--
-- DELETE is granted because the ORM's delete path exists; the append-only
-- tables refuse it with their own triggers, which is the enforcement point, not
-- the grant.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

DO $$
BEGIN
    IF current_database() IN ('Dss', 'Final_Location_Analysis') THEN
        RAISE EXCEPTION 'REFUSED: % is a protected database', current_database();
    END IF;
    IF current_database() NOT LIKE 'project1\_pg18\_%' THEN
        RAISE EXCEPTION 'REFUSED: expected a project1_pg18_* database, connected to %',
            current_database();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sitewise_e2e') THEN
        RAISE EXCEPTION 'sitewise_e2e missing: apply 20261123_00_roles.sql first';
    END IF;
END $$;

-- --- application / ORM principal ----------------------------------------
GRANT USAGE ON SCHEMA public, project1_ai, cp12 TO sitewise_e2e;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO sitewise_e2e;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO sitewise_e2e;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO sitewise_e2e;

-- --- project1_ai ledger principal ---------------------------------------
GRANT USAGE ON SCHEMA project1_ai TO p1ai_engine;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA project1_ai TO p1ai_engine;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA project1_ai TO p1ai_engine;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA project1_ai TO p1ai_engine;

-- --- EE-01 read principal ------------------------------------------------
-- SELECT only: EE-01 renders from persisted snapshots and must not mutate them.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_ee01_runtime') THEN
        GRANT USAGE ON SCHEMA public TO p1_ee01_runtime;
        EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO p1_ee01_runtime';
    END IF;
END $$;

-- --- future objects ------------------------------------------------------
-- Without this, the next CREATE TABLE silently reintroduces the same gap.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO sitewise_e2e;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO sitewise_e2e;
ALTER DEFAULT PRIVILEGES IN SCHEMA project1_ai
    GRANT SELECT, INSERT, UPDATE ON TABLES TO p1ai_engine;

-- --- assertion -----------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n
    FROM information_schema.role_table_grants
    WHERE grantee = 'sitewise_e2e';
    IF n = 0 THEN
        RAISE EXCEPTION 'REFUSED: grant application produced no grants';
    END IF;
    RAISE NOTICE 'sitewise_e2e holds % table grants', n;
END $$;

COMMIT;
