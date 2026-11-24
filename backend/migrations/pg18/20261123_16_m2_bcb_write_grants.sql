-- =====================================================================
-- 20261123_16_m2_bcb_write_grants.sql
--
-- Purpose
--   Give ``p1_m2_runtime`` INSERT/UPDATE on the two business-context-build
--   tables so confirmation can create the BCB row its trigger requires.
--
-- Reason
--   ``m2_bcb_initialize_status()`` fires AFTER INSERT on
--   ``m2_confirmation_snapshots`` and inserts a PENDING build row. The role
--   could read those tables (``20261123_12``) but not write them, so every
--   confirmation failed behind the same bare 503. Reproduced in-process
--   (tools/pg18_diag_m2_confirm.py), real error:
--
--     sqlalchemy.exc.ProgrammingError: (psycopg2.errors.InsufficientPrivilege)
--       permission denied for table m2_business_context_builds
--     CONTEXT: SQL statement "INSERT INTO public.m2_business_context_builds(
--                confirmation_id,assessment_id,owner_user_id,
--                assessment_revision,status)
--              VALUES(NEW.id,NEW.assessment_id,NEW.actor_user_id,
--                     NEW.assessment_revision,'PENDING')"
--              PL/pgSQL function m2_bcb_initialize_status() line 3 at SQL statement
--
--   ``m2_business_contexts`` gets the same treatment because the build writes
--   the produced packet there; leaving it read-only would only move the
--   failure one statement later.
--
-- Constraint
--   SELECT, INSERT, UPDATE — no DELETE and no TRUNCATE. A build row is an
--   audit record of an attempt, and the contexts table holds confirmed
--   packets; neither may be removed by the runtime lane. Row scoping is
--   unchanged: both tables keep their ``owner_scope`` policy keyed on
--   ``current_setting('project1.actor_id')``.
--
-- Safety
--   Only a ``project1_pg18_%`` database on port 5544 may run this file.
-- =====================================================================

DO $$
DECLARE
    db   text := current_database();
    port int  := inet_server_port();
    t    text;
    n    int  := 0;
BEGIN
    IF db NOT LIKE 'project1\_pg18\_%' THEN
        RAISE EXCEPTION 'REFUSED: % is not a project1_pg18_* database', db;
    END IF;
    IF port <> 5544 THEN
        RAISE EXCEPTION 'REFUSED: port % is not the isolated PG18 cluster (5544)', port;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_m2_runtime') THEN
        RAISE EXCEPTION 'REFUSED: role p1_m2_runtime does not exist';
    END IF;

    FOREACH t IN ARRAY ARRAY[
        'm2_business_context_builds',
        'm2_business_contexts'
    ]
    LOOP
        IF to_regclass('public.' || t) IS NULL THEN
            RAISE NOTICE 'public.% is absent; skipped', t;
            CONTINUE;
        END IF;
        EXECUTE format('GRANT SELECT, INSERT, UPDATE ON public.%I TO p1_m2_runtime', t);
        n := n + 1;
    END LOOP;

    RAISE NOTICE 'SELECT/INSERT/UPDATE granted on % business-context relation(s)', n;
END $$;
