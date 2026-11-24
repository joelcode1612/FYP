-- =====================================================================
-- 20261124_20_p1ai_runtime_ledger_read.sql
--
-- Purpose
--   Give ``p1ai_runtime`` -- the restricted principal the result read path
--   switches into -- USAGE on schema ``project1_ai`` and SELECT on
--   ``project1_ai.bdj_results``. Nothing else.
--
-- Reason
--   ``GET /m2/assessments/{id}/bdj/current`` failed with
--
--     503 {"code":"WORKFLOW_STORAGE_UNAVAILABLE"}
--
--   ``result_store.results_for_assessment`` calls ``restricted_scope``, which
--   does ``SET LOCAL ROLE p1ai_runtime`` (principal.RESTRICTED_ROLE). That role
--   held no privilege at all on the ledger:
--
--     has_schema_privilege('p1ai_runtime','project1_ai','USAGE')             -> false
--     has_table_privilege('p1ai_runtime','project1_ai.bdj_results','SELECT') -> false
--
--   so the SELECT raised, and result_store maps SQLAlchemyError to
--   WORKFLOW_STORAGE_UNAVAILABLE. The 503 therefore described a missing grant,
--   not a missing result. This file is the grant.
--
--   This is deliberately *not* the same role as 20261124_19. Stage 3's evaluator
--   reads as ``p1_m2_runtime``; this read path switches to ``p1ai_runtime``.
--   Fixing one never fixes the other, which is why the 503 survived migration 19.
--
-- Scope
--   Read only, one table. ``bdj_real_data_authorizations`` is intentionally NOT
--   granted here: this read path never selects it, and its owner_scope policy is
--   scoped to ``p1_m2_runtime``. ``bdj_results`` keeps its forced RLS and
--   owner_scope policy, so the grant cannot widen past one owner.
--
--   Target: the isolated PG18 cluster only.
-- =====================================================================

BEGIN;

DO $$
BEGIN
    IF current_database() <> 'project1_pg18_migrated_tests' THEN
        RAISE EXCEPTION
            'refusing to run outside the isolated PG18 test database (current=%)',
            current_database();
    END IF;
END $$;

GRANT USAGE ON SCHEMA project1_ai TO p1ai_runtime;
GRANT SELECT ON project1_ai.bdj_results TO p1ai_runtime;

DO $$
BEGIN
    IF NOT has_schema_privilege('p1ai_runtime', 'project1_ai', 'USAGE') THEN
        RAISE EXCEPTION 'p1ai_runtime still lacks USAGE on project1_ai';
    END IF;
    IF NOT has_table_privilege('p1ai_runtime',
                               'project1_ai.bdj_results', 'SELECT') THEN
        RAISE EXCEPTION 'p1ai_runtime lacks SELECT on bdj_results';
    END IF;

    -- Read-only: no write path may have been acquired.
    IF has_table_privilege('p1ai_runtime', 'project1_ai.bdj_results', 'INSERT')
       OR has_table_privilege('p1ai_runtime', 'project1_ai.bdj_results', 'UPDATE')
       OR has_table_privilege('p1ai_runtime', 'project1_ai.bdj_results', 'DELETE') THEN
        RAISE EXCEPTION 'p1ai_runtime acquired a write privilege on the ledger';
    END IF;

    -- Forced RLS on bdj_results must survive: the grant is row-scoped.
    IF NOT (SELECT relrowsecurity FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'project1_ai' AND c.relname = 'bdj_results') THEN
        RAISE EXCEPTION 'bdj_results lost its row-level security';
    END IF;
END $$;

COMMIT;
