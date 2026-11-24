-- =====================================================================
-- 20261124_19_stage3_ledger_read.sql
--
-- Purpose
--   Let the Stage 3 contract read its own BDJ evidence as the restricted M2
--   runtime principal: ``p1_m2_runtime`` gains USAGE on schema
--   ``project1_ai`` and SELECT on ``bdj_results`` and
--   ``bdj_real_data_authorizations``. ``bdj_real_data_authorizations`` also
--   gains row-level security, which it never had.
--
-- Reason
--   ``sitewise-stage3-completion/2`` evaluates T3-04 from the attempt ledger.
--   Against this cluster the runtime principal could not read it at all:
--
--     has_schema_privilege('p1_m2_runtime','project1_ai','USAGE')            -> false
--     has_table_privilege('p1_m2_runtime','project1_ai.bdj_results','SELECT')-> false
--
--   so every Stage 3 evaluation reported T3-04 ``NO_EVALUATION`` -- the same
--   answer a genuinely absent evaluation produces. That is the failure mode
--   this file removes: "no evaluation exists" and "I was not allowed to look"
--   must not be indistinguishable.
--
--   The second problem is specific to the authorizations table. RLS is
--   *disabled* on it, so granting SELECT alone would have exposed every owner's
--   authorizations to a runtime role that is supposed to see one owner's rows.
--   The table carries no ``owner_user_id``, so the owner-scope predicate goes
--   through ``m2_assessments.owner_user_id`` -- the same authority the link
--   chain already uses.
--
-- Scope
--   Read only, two tables, one schema. No INSERT, UPDATE or DELETE is granted:
--   the ledger is written by ``p1ai_engine``, and the evaluator is a SELECT-only
--   reference implementation. ``bdj_results`` already has forced RLS and an
--   ``owner_scope`` policy; this file asserts both survived.
--
--   Target: the isolated PG18 cluster only (``project1_pg18_migrated_tests``,
--   port 5544). The guard below refuses any other database name.
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

-- 1. Schema usage only. CREATE on the schema is deliberately not granted.
GRANT USAGE ON SCHEMA project1_ai TO p1_m2_runtime;

-- 2. SELECT on exactly the two tables the evaluator reads.
GRANT SELECT ON project1_ai.bdj_results TO p1_m2_runtime;
GRANT SELECT ON project1_ai.bdj_real_data_authorizations TO p1_m2_runtime;

-- 3. The authorizations table had RLS disabled. Enable it and scope rows to the
--    owning assessment so the new grant cannot read another owner's receipts.
ALTER TABLE project1_ai.bdj_real_data_authorizations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS owner_scope ON project1_ai.bdj_real_data_authorizations;
CREATE POLICY owner_scope ON project1_ai.bdj_real_data_authorizations
    FOR SELECT TO p1_m2_runtime
    USING (
        EXISTS (
            SELECT 1
            FROM public.m2_assessments a
            WHERE a.id = bdj_real_data_authorizations.assessment_id
              AND a.owner_user_id =
                  NULLIF(current_setting('project1.actor_id', true), '')::uuid
        )
    );

-- 4. ``p1ai_engine`` writes this table and has no BYPASSRLS. Without a policy
--    enabling RLS would break the writer, so it keeps full access explicitly.
DROP POLICY IF EXISTS engine_all ON project1_ai.bdj_real_data_authorizations;
CREATE POLICY engine_all ON project1_ai.bdj_real_data_authorizations
    FOR ALL TO p1ai_engine
    USING (true) WITH CHECK (true);

-- 5. The audit role reads every ledger table through ``technical_audit_read``;
--    this table never had that policy because RLS was off. Add it so enabling
--    RLS does not silently blind the audit lane.
DROP POLICY IF EXISTS technical_audit_read ON project1_ai.bdj_real_data_authorizations;
CREATE POLICY technical_audit_read ON project1_ai.bdj_real_data_authorizations
    FOR SELECT TO p1ai_audit USING (true);

-- 6. Assert the boundary this file is supposed to leave intact.
DO $$
BEGIN
    IF NOT has_schema_privilege('p1_m2_runtime', 'project1_ai', 'USAGE') THEN
        RAISE EXCEPTION 'p1_m2_runtime still lacks USAGE on project1_ai';
    END IF;

    IF NOT has_table_privilege('p1_m2_runtime',
                               'project1_ai.bdj_results', 'SELECT') THEN
        RAISE EXCEPTION 'p1_m2_runtime lacks SELECT on bdj_results';
    END IF;

    -- No write path may have been acquired by this migration.
    IF has_table_privilege('p1_m2_runtime', 'project1_ai.bdj_results', 'INSERT')
       OR has_table_privilege('p1_m2_runtime',
                              'project1_ai.bdj_real_data_authorizations', 'INSERT') THEN
        RAISE EXCEPTION 'p1_m2_runtime acquired a write privilege on the ledger';
    END IF;

    IF NOT (SELECT relrowsecurity FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'project1_ai' AND c.relname = 'bdj_results') THEN
        RAISE EXCEPTION 'bdj_results lost its row-level security';
    END IF;

    IF NOT (SELECT relrowsecurity FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'project1_ai'
              AND c.relname = 'bdj_real_data_authorizations') THEN
        RAISE EXCEPTION 'bdj_real_data_authorizations did not gain row-level security';
    END IF;
END $$;

COMMIT;
