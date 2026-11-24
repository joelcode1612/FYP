-- =====================================================================
-- 20261123_17_p1ai_engine_runtime_membership.sql
--
-- Purpose
--   Make ``p1ai_engine`` a member of ``p1ai_runtime`` so the restricted
--   execution-principal contract can be satisfied at all.
--
-- Reason
--   ``PostgresAttemptLedger._scope`` documents the contract and enforces it:
--
--     * the login principal must be non-superuser and non-BYPASSRLS, and
--     * statements must execute as the NOLOGIN role ``p1ai_runtime``, reached
--       either by a direct restricted login or by
--       ``SET LOCAL ROLE p1ai_runtime`` from ``p1ai_engine``, which is described
--       in that docstring as "member of p1ai_runtime".
--
--   ``20261123_00_roles.sql`` created ``p1ai_engine`` with ``NOINHERIT`` — which
--   is correct, it keeps the restricted role's privileges inactive until the
--   explicit ``SET LOCAL ROLE`` — but never granted the membership. With no
--   membership, ``SET LOCAL ROLE`` fails and every ledger read refuses with:
--
--     RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED
--     "The review service is waiting for its required database authorization."
--
--   Observed as a 503 on
--   ``GET /api/v1/m2/assessments/{id}/bdj/current`` in the Stage 3 view.
--
-- Constraint
--   Membership only, and ``NOINHERIT`` is preserved. ``p1ai_engine`` does not
--   silently acquire ``p1ai_runtime``'s privileges on connect; it acquires the
--   ability to assume them for the duration of one transaction. No table
--   privilege, no schema privilege and no attribute of either role changes.
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
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1ai_engine') THEN
        RAISE EXCEPTION 'REFUSED: role p1ai_engine does not exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1ai_runtime') THEN
        RAISE EXCEPTION 'REFUSED: role p1ai_runtime does not exist';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1ai_engine' AND rolinherit) THEN
        RAISE EXCEPTION 'REFUSED: p1ai_engine must stay NOINHERIT';
    END IF;

    EXECUTE 'GRANT p1ai_runtime TO p1ai_engine';
    RAISE NOTICE 'p1ai_runtime granted to p1ai_engine (NOINHERIT preserved)';
END $$;
