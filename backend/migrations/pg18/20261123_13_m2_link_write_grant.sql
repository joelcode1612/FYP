-- =====================================================================
-- 20261123_13_m2_link_write_grant.sql
--
-- Purpose
--   Grant ``p1_m2_runtime`` INSERT on ``public.m2_assessment_links``, the one
--   write the assessment → M2 link path needs and did not have.
--
-- Reason
--   ``20261123_02_p1_m2_runtime.sql`` granted SELECT/INSERT/UPDATE over eight
--   ``m2_*`` tables and simply omitted ``m2_assessment_links`` from the list.
--   Reads were added later by ``20261123_12``, so the table ended up readable
--   and unwritable by the M2 lane. Every "Initialize M2 questionnaire" therefore
--   failed with a bare 503, because both link endpoints convert any
--   ``SQLAlchemyError`` into ``M2_SOURCE_UNAVAILABLE`` and log nothing.
--
--   Reproduced in-process (tools/pg18_diag_m2_create.py), real error:
--
--     sqlalchemy.exc.ProgrammingError: (psycopg2.errors.InsufficientPrivilege)
--       permission denied for table m2_assessment_links
--     SQL: insert into public.m2_assessment_links
--            (m2_assessment_id, marketplace_assessment_id, user_id, created_by)
--          values (?, ?, ?, ?)
--
--   Row visibility is unchanged: the table already carries FORCE ROW LEVEL
--   SECURITY with an ``owner_scope`` policy comparing ``user_id`` against
--   ``current_setting('project1.actor_id')``, which the service sets per
--   transaction. A grant without that actor still matches no row, so this file
--   widens the privilege and not the scope.
--
-- Constraint
--   INSERT only. The service never updates a link in place — reassignment is
--   refused by design, and revocation is an explicit operator action that this
--   migration must not quietly enable.
--
-- Safety
--   Only a ``project1_pg18_%`` database on port 5544 may run this file.
-- =====================================================================

DO $$
DECLARE
    db   text := current_database();
    port int  := inet_server_port();
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
    IF to_regclass('public.m2_assessment_links') IS NULL THEN
        RAISE EXCEPTION 'REFUSED: public.m2_assessment_links is absent';
    END IF;

    EXECUTE 'GRANT INSERT ON public.m2_assessment_links TO p1_m2_runtime';
    RAISE NOTICE 'INSERT granted on public.m2_assessment_links to p1_m2_runtime';
END $$;
