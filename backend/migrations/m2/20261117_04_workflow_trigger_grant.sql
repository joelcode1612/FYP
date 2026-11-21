-- CP-03F-13 / M2-WRITE-01: make the workflow-projection trigger usable by the
-- application role.
--
-- Defect this repairs
-- -------------------
-- 20261115_02_workflow_projection.sql created the projection machinery and then
-- left it unusable by anyone but the owner (postgres). Four separate gaps, all
-- on the same write path:
--
--   1. `REVOKE ALL ON FUNCTION refresh_m2_workflow(uuid),
--          m2_workflow_change() FROM PUBLIC` with no matching GRANT.
--   2. No SELECT on `public.m2_workflow_summary`, which refresh reads.
--   3. No SELECT/INSERT on `public.assessment_workflow_projection`, which
--      refresh reads and writes.
--   4. `assessment_workflow_projection` has ROW LEVEL SECURITY **enabled with
--      zero policies** — a default-deny table, so even a granted INSERT would
--      be rejected.
--
-- Both functions are SECURITY INVOKER and `refresh_workflow` is a
-- CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED on 14 tables, so it runs
-- with the caller's rights at COMMIT. The observable symptom was:
--
--     permission denied for function refresh_m2_workflow
--     ... then, once granted ...
--     permission denied for view m2_workflow_summary
--
-- surfaced by the HTTP layer as a fixed
-- 503 {"code":"M2_SOURCE_UNAVAILABLE"}, which read as "storage unavailable"
-- rather than a privilege gap. No M2 answer, review, confirmation, BDJ
-- evaluation or finding could ever be persisted.
--
-- Scope: additive. Grants and one owner-scoped policy that mirrors the existing
-- `m2_assessments.owner_scope` policy exactly. No table, function body or
-- trigger is altered, and no existing policy is relaxed. RLS stays enabled and
-- stays owner-scoped: the projection is derived per-owner data, not a bypass.
--
-- Explicit operator execution only. Never run at startup.
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $$ BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit migration target and receipt required';
  END IF;
  IF to_regprocedure('public.refresh_m2_workflow(uuid)') IS NULL
     OR to_regprocedure('public.m2_workflow_change()') IS NULL
     OR to_regclass('public.m2_workflow_summary') IS NULL
     OR to_regclass('public.assessment_workflow_projection') IS NULL THEN
    RAISE EXCEPTION 'Workflow projection objects missing: apply 20261115_02 first';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'p1_m2_runtime') THEN
    RAISE EXCEPTION 'Role p1_m2_runtime missing';
  END IF;
END $$;

-- 1. Trigger functions (invoker rights: the caller needs EXECUTE).
GRANT EXECUTE ON FUNCTION public.refresh_m2_workflow(uuid) TO p1_m2_runtime;
GRANT EXECUTE ON FUNCTION public.m2_workflow_change() TO p1_m2_runtime;

-- 2. The summary view refresh reads.
GRANT SELECT ON public.m2_workflow_summary TO p1_m2_runtime;

-- 3. The projection table refresh reads and writes.
GRANT SELECT, INSERT ON public.assessment_workflow_projection TO p1_m2_runtime;

-- 4. The owner-scoped policy that was never created. Mirrors
--    m2_assessments.owner_scope verbatim so the projection cannot become a
--    cross-owner read path.
DROP POLICY IF EXISTS owner_scope ON public.assessment_workflow_projection;
CREATE POLICY owner_scope ON public.assessment_workflow_projection
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);

-- 5. `m2_workflow_change` resolves an objective's assessment through this table
--    for rows that carry no assessment_id.
GRANT SELECT ON public.m2_review_question_versions TO p1_m2_runtime;

-- Prove every grant took effect in the same transaction, so a silent no-op
-- cannot be mistaken for success.
DO $$ BEGIN
  IF NOT has_function_privilege('p1_m2_runtime',
        'public.refresh_m2_workflow(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('p1_m2_runtime',
        'public.m2_workflow_change()', 'EXECUTE')
     OR NOT has_table_privilege('p1_m2_runtime',
        'public.m2_workflow_summary', 'SELECT')
     OR NOT has_table_privilege('p1_m2_runtime',
        'public.assessment_workflow_projection', 'INSERT')
     OR NOT has_table_privilege('p1_m2_runtime',
        'public.m2_review_question_versions', 'SELECT') THEN
    RAISE EXCEPTION 'One or more grants did not take effect';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_policies
                 WHERE schemaname = 'public'
                   AND tablename = 'assessment_workflow_projection'
                   AND policyname = 'owner_scope') THEN
    RAISE EXCEPTION 'owner_scope policy was not created';
  END IF;
END $$;
COMMIT;
