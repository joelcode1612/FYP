-- =====================================================================
-- 20261123_14_m2_workflow_projection_grants.sql
--
-- Purpose
--   Give ``p1_m2_runtime`` the reads and the single write that
--   ``public.refresh_m2_workflow(uuid)`` needs when it fires from the
--   ``m2_workflow_change`` trigger on ``m2_assessment_links``.
--
-- Reason
--   After ``20261123_13`` granted the link INSERT, the same request failed one
--   layer deeper, still behind the bare 503. Reproduced in-process
--   (tools/pg18_diag_m2_create.py), real error:
--
--     sqlalchemy.exc.ProgrammingError: (psycopg2.errors.InsufficientPrivilege)
--       permission denied for view m2_workflow_summary
--     CONTEXT: PL/pgSQL function refresh_m2_workflow(uuid) line 5 at SQL statement
--              PL/pgSQL function m2_workflow_change() line 12 at PERFORM
--
--   ``refresh_m2_workflow`` is not SECURITY DEFINER, so it runs with the
--   caller's privileges. It reads ``m2_workflow_summary`` and writes
--   ``assessment_workflow_projection``; the M2 lane had no privilege on either.
--
--   ``m2_workflow_summary`` and ``m2_workflow_campaigns`` are
--   ``security_invoker=true``, which is deliberate: the projection must be
--   scoped to the caller's rows, not to the view owner's. The consequence is
--   that the caller needs SELECT on the relations underneath, including the
--   four ``cq_*`` tables the campaigns view aggregates. Those grants are
--   SELECT-only and read no answer content — campaign id, release manifest
--   hash, and session/receipt counts.
--
-- Constraint
--   SELECT everywhere, plus INSERT on ``assessment_workflow_projection`` only.
--   The projection is append-only by construction (the function inserts a new
--   sequence row and never updates), so UPDATE and DELETE stay withheld. Row
--   scoping is unchanged: every one of these tables keeps its ``owner_scope``
--   policy against ``current_setting('project1.actor_id')``.
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
    IF to_regprocedure('public.refresh_m2_workflow(uuid)') IS NULL THEN
        RAISE EXCEPTION 'REFUSED: refresh_m2_workflow(uuid) is absent';
    END IF;

    FOREACH t IN ARRAY ARRAY[
        -- read by refresh_m2_workflow itself
        'm2_workflow_summary',
        'assessment_workflow_projection',
        -- underneath the security_invoker campaigns view
        'm2_workflow_campaigns',
        'cq_campaigns',
        'cq_manifest_releases',
        'cq_sessions',
        'cq_submission_receipts'
    ]
    LOOP
        IF to_regclass('public.' || t) IS NULL THEN
            RAISE NOTICE 'public.% is absent; skipped', t;
            CONTINUE;
        END IF;
        EXECUTE format('GRANT SELECT ON public.%I TO p1_m2_runtime', t);
        n := n + 1;
    END LOOP;

    -- The only write in the refresh path: append one projection row.
    EXECUTE 'GRANT INSERT ON public.assessment_workflow_projection TO p1_m2_runtime';

    RAISE NOTICE 'SELECT granted on % relation(s); INSERT on assessment_workflow_projection', n;
END $$;
