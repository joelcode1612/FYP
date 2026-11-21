-- CP-03F-13 / M2-WRITE-01 (cause 4): complete the read scope for the CQ bridge.
--
-- `20261115_03_workflow_cq_bridge.sql` replaces the empty stub
-- `m2_workflow_campaigns` with a real `security_invoker=true` view over the CQ
-- tables, so the summary view transitively reads four more relations:
--
--     cq_campaigns, cq_manifest_releases, cq_sessions, cq_submission_receipts
--
-- None of them was ever granted to the application role, so the deferred workflow
-- trigger still aborted at COMMIT with:
--
--     permission denied for table cq_sessions
--
-- This is the fourth and last privilege gap on the M2 write path. The set is not
-- hand-maintained: `scripts/cp03f_m2_view_closure_audit.py` derives it from the
-- catalog by walking the `_RETURN` rewrite rules of both views, which is how the
-- earlier hand-written lists kept missing a cause.
--
-- No policies are added here, and none are needed. All four tables already have
-- ROW LEVEL SECURITY enabled with policies that resolve to the requesting owner:
--
--     cq_campaigns.owner_user_id = current_setting('project1.actor_id')
--     cq_manifest_releases  id IN (SELECT release_id FROM cq_campaigns)
--     cq_sessions           campaign_id IN (SELECT id FROM cq_campaigns)
--     cq_submission_receipts session_id IN (SELECT id FROM cq_sessions)
--
-- The last three are scoped transitively, because RLS is applied to the referenced
-- table inside each policy expression. So granting SELECT widens nothing: a caller
-- still sees only its own campaigns. This matters more than it looks, because
-- `m2_workflow_campaigns` is directly queryable — not only through the summary view
-- that constrains it by `assessment_id` and `owner_user_id`.
--
-- Read only. No INSERT/UPDATE/DELETE is granted on any CQ table: fielding is not
-- authorized, and this migration must not be the thing that makes it possible.
--
-- Explicit operator execution only. Never run at startup.
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $$ BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit migration target and receipt required';
  END IF;
  IF to_regclass('public.m2_workflow_campaigns') IS NULL
     OR to_regclass('public.cq_campaigns') IS NULL THEN
    RAISE EXCEPTION 'CQ bridge missing: apply 20261115_03 first';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'p1_m2_runtime') THEN
    RAISE EXCEPTION 'Role p1_m2_runtime missing';
  END IF;
END $$;

GRANT SELECT ON public.cq_campaigns           TO p1_m2_runtime;
GRANT SELECT ON public.cq_manifest_releases   TO p1_m2_runtime;
GRANT SELECT ON public.cq_sessions            TO p1_m2_runtime;
GRANT SELECT ON public.cq_submission_receipts TO p1_m2_runtime;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'cq_campaigns','cq_manifest_releases','cq_sessions','cq_submission_receipts'] LOOP
    IF NOT has_table_privilege('p1_m2_runtime', 'public.' || t, 'SELECT') THEN
      RAISE EXCEPTION 'SELECT grant missing on %', t;
    END IF;
    -- Fielding stays unauthorized: no write privilege may appear here.
    IF has_table_privilege('p1_m2_runtime', 'public.' || t, 'INSERT')
       OR has_table_privilege('p1_m2_runtime', 'public.' || t, 'UPDATE')
       OR has_table_privilege('p1_m2_runtime', 'public.' || t, 'DELETE') THEN
      RAISE EXCEPTION 'unexpected write privilege on %', t;
    END IF;
    -- Every table must still be owner-scoped by RLS.
    IF NOT (SELECT relrowsecurity FROM pg_class
             WHERE oid = ('public.' || t)::regclass) THEN
      RAISE EXCEPTION 'RLS is not enabled on %', t;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_policies
                    WHERE schemaname = 'public' AND tablename = t) THEN
      RAISE EXCEPTION 'no policy on %, granting SELECT would be unscoped', t;
    END IF;
  END LOOP;
END $$;
COMMIT;
