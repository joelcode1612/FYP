-- =====================================================================
-- 20261124_03 — CQ workflow projection trigger must run with definer rights
--
-- Problem
--   `cq_campaigns`, `cq_sessions` and `cq_submission_receipts` carry an
--   AFTER trigger `refresh_cq_workflow -> public.m2_workflow_cq_change()`
--   (created by `m2/20261115_03`, re-created by `cq/20261116_04`). That
--   function calls `public.refresh_m2_workflow(aid)` and is **not**
--   SECURITY DEFINER, so the call executes as the invoking role. Neither
--   restricted principal can execute it:
--
--       has_function_privilege('p1_ee01_runtime',
--           'public.refresh_m2_workflow(uuid)', 'EXECUTE')  ->  false
--       has_function_privilege('p1_m2_runtime',
--           'public.refresh_m2_workflow(uuid)', 'EXECUTE')  ->  false
--
--   Consequence, measured on a clean install: every CQ write by the real
--   runtime principal aborts **at COMMIT**, after the row has been written
--   and all policies have passed, with
--
--       permission denied for function refresh_m2_workflow
--       CONTEXT: PL/pgSQL function m2_workflow_cq_change() line 10
--
--   That is the worst possible place for the failure. The store's
--   `except SQLAlchemyError` turns it into `CQ_STORAGE_UNAVAILABLE`, so a
--   deterministic privilege gap is reported to the client as a transient
--   outage. The whole respondent flow — campaign, session, receipt — stops
--   at its final statement. (DD-CQ-22)
--
-- Why the fix is SECURITY DEFINER and not a GRANT
--   Granting EXECUTE on `refresh_m2_workflow(uuid)` to `p1_ee01_runtime`
--   would make the projection refresher directly callable by the CQ
--   principal for *any* assessment id, which is a write into
--   `m2_workflow_projection` outside anything the CQ policies check. A
--   trigger function's authority should be the schema's, not the caller's:
--   PostgreSQL does not require EXECUTE privilege on a trigger function for
--   the trigger to fire, so `SECURITY DEFINER` widens nothing that is
--   callable while making the trigger body run as its owner.
--
--   The trigger body derives the assessment from the row being written
--   (`NEW.assessment_id` for a campaign, the campaign's assessment for a
--   session), and the INSERT policies on those tables already prove the actor
--   owns the assessment or participates in the campaign. So the definer's
--   reach is bounded by the row the caller was already authorized to write.
--
-- Body preserved exactly
--   `ALTER FUNCTION ... SECURITY DEFINER` changes the attribute and leaves
--   `prosrc` byte-identical, which is asserted below. Rewriting the body
--   would invalidate the `md5(prosrc)` guard in `cq/20261116_04:14-15`
--   (`24c80efe21c506ba5cc1fe2795ac83a4`) for any later re-run.
--
-- Explicit operator execution only. Never run at startup.
-- =====================================================================
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$ BEGIN
  IF current_setting('project1.cq_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.cq_migration_receipt', true), '') IS NULL
     OR coalesce(current_setting('project1.cq_migration_sha256', true), '') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Explicit target, receipt and hash required';
  END IF;
  IF to_regprocedure('public.m2_workflow_cq_change()') IS NULL THEN
    RAISE EXCEPTION 'm2_workflow_cq_change() absent: apply m2/20261115_03 and cq/20261116_04 first';
  END IF;
  IF EXISTS (SELECT 1 FROM cq_schema_migrations
              WHERE version = '20261124_03'
                AND migration_sha256 <> current_setting('project1.cq_migration_sha256')) THEN
    RAISE EXCEPTION 'Migration hash differs';
  END IF;
END $$;

-- Record the body digest before the change so the assertion can prove it did
-- not move. A separate temp table keeps the CP12 inventory untouched.
CREATE TEMP TABLE cq_trigger_body_before ON COMMIT DROP AS
  SELECT md5(prosrc) AS digest
    FROM pg_proc WHERE oid = to_regprocedure('public.m2_workflow_cq_change()');

ALTER FUNCTION public.m2_workflow_cq_change() SECURITY DEFINER;
ALTER FUNCTION public.m2_workflow_cq_change() SET search_path = pg_catalog, public;

-- The trigger fires regardless of EXECUTE privilege, so nothing needs it.
REVOKE ALL ON FUNCTION public.m2_workflow_cq_change() FROM PUBLIC;

DO $$
DECLARE
  fn record; before_digest text; n int;
BEGIN
  SELECT md5(prosrc) AS digest, prosecdef, proconfig
    INTO fn FROM pg_proc WHERE oid = to_regprocedure('public.m2_workflow_cq_change()');
  SELECT t.digest INTO before_digest FROM cq_trigger_body_before t;

  IF fn.prosecdef IS NOT TRUE THEN
    RAISE EXCEPTION 'm2_workflow_cq_change() is still not SECURITY DEFINER';
  END IF;
  IF fn.digest IS DISTINCT FROM before_digest THEN
    RAISE EXCEPTION 'trigger body changed (% -> %); only the security attribute may change',
      before_digest, fn.digest;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(fn.proconfig) c WHERE c LIKE 'search_path=%') THEN
    RAISE EXCEPTION 'search_path is not pinned on the trigger function';
  END IF;

  -- It must not have become callable as a side effect.
  IF has_function_privilege('public', 'public.m2_workflow_cq_change()', 'EXECUTE')
     OR has_function_privilege('p1_ee01_runtime', 'public.m2_workflow_cq_change()', 'EXECUTE') THEN
    RAISE EXCEPTION 'trigger function must not be directly executable';
  END IF;

  -- The refresher it calls must stay out of both principals' reach: the point
  -- of the definer switch is that the *trigger* may refresh, not the caller.
  IF has_function_privilege('p1_ee01_runtime', 'public.refresh_m2_workflow(uuid)', 'EXECUTE')
     OR has_function_privilege('p1_m2_runtime', 'public.refresh_m2_workflow(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'refresh_m2_workflow must not be directly executable by a runtime principal';
  END IF;

  -- Still attached to all three CQ tables.
  SELECT count(*) INTO n
    FROM pg_trigger t JOIN pg_class k ON k.oid = t.tgrelid
    JOIN pg_namespace s ON s.oid = k.relnamespace
   WHERE s.nspname = 'public' AND t.tgname = 'refresh_cq_workflow'
     AND k.relname IN ('cq_campaigns', 'cq_sessions', 'cq_submission_receipts')
     AND NOT t.tgisinternal;
  IF n <> 3 THEN
    RAISE EXCEPTION 'expected the workflow trigger on 3 CQ tables, found %', n;
  END IF;

  -- And the other CQ triggers that reach across schemas already run as their
  -- owner; this migration must not be the only one holding the line.
  SELECT count(*) INTO n FROM pg_proc p
   WHERE p.proname IN ('write_barrier', 'cq_is_synthetic_campaign')
     AND p.prosecdef IS NOT TRUE;
  IF n > 0 THEN
    RAISE EXCEPTION '% cross-schema CQ trigger function(s) are not SECURITY DEFINER', n;
  END IF;
END $$;

INSERT INTO cq_schema_migrations(version, migration_sha256, receipt)
VALUES ('20261124_03', current_setting('project1.cq_migration_sha256'),
        current_setting('project1.cq_migration_receipt'))
ON CONFLICT (version) DO NOTHING;

COMMIT;
