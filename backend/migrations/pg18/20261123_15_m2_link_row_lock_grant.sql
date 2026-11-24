-- =====================================================================
-- 20261123_15_m2_link_row_lock_grant.sql
--
-- Purpose
--   Let ``p1_m2_runtime`` take the row lock that the review path needs on
--   ``public.m2_assessment_links``, without letting it change what the link
--   says.
--
-- Reason
--   ``ConfirmationService.record_review`` verifies the binding before it writes
--   an event:
--
--     SELECT link_id FROM public.m2_assessment_links
--      WHERE m2_assessment_id = ... AND marketplace_assessment_id = ...
--        AND user_id = ... AND revoked_at IS NULL
--      FOR SHARE
--
--   PostgreSQL requires UPDATE privilege for any row-locking clause, so the
--   statement was refused even though the role could already SELECT the row:
--
--     sqlalchemy.exc.ProgrammingError: (psycopg2.errors.InsufficientPrivilege)
--       permission denied for table m2_assessment_links
--
--   The lock is the point: it keeps a concurrent revocation from landing
--   between the check and the write. Removing the clause in application code
--   would trade a privilege problem for a race, so the privilege is widened
--   instead.
--
-- Constraint
--   Column-level UPDATE on ``link_id`` only. PostgreSQL accepts UPDATE on any
--   one column as sufficient for row locking, so this enables ``FOR SHARE``
--   while leaving ``m2_assessment_id``, ``marketplace_assessment_id``,
--   ``user_id`` and the revocation columns unwritable. The M2 lane still cannot
--   re-point a link, and ``20261123_13`` granted INSERT only — revocation stays
--   an explicit operator action.
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

    EXECUTE 'GRANT UPDATE (link_id) ON public.m2_assessment_links TO p1_m2_runtime';
    RAISE NOTICE 'UPDATE(link_id) granted on public.m2_assessment_links to p1_m2_runtime';
END $$;
