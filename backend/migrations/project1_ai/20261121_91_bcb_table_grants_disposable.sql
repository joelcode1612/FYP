-- Disposable-only correction: BCB persistence privileges for p1_m2_runtime.
-- Migration: 20261121_91_bcb_table_grants_disposable
--
-- 20261121_90 enabled RLS on these tables but granted no privileges, so the
-- runtime principal could neither read nor write a business context. This adds
-- the minimum the real store needs: SELECT, INSERT, UPDATE. No DELETE, no
-- TRUNCATE, no ownership, no schema management. RLS policies are untouched.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

DO $$
BEGIN
    IF current_database() <> 'project1_workflow_tests' THEN
        RAISE EXCEPTION 'Disposable target only';
    END IF;
    IF current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
       OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
        RAISE EXCEPTION 'Explicit target and migration receipt required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_m2_runtime') THEN
        RAISE EXCEPTION 'p1_m2_runtime missing: apply the role migration first';
    END IF;
    IF to_regclass('public.m2_business_contexts') IS NULL
       OR to_regclass('public.m2_business_context_builds') IS NULL THEN
        RAISE EXCEPTION 'BCB tables missing: apply the context schema first';
    END IF;
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE relname = 'm2_business_contexts')
       OR NOT (SELECT relrowsecurity FROM pg_class WHERE relname = 'm2_business_context_builds') THEN
        RAISE EXCEPTION 'RLS must already be enabled: this migration does not change it';
    END IF;
END $$;

GRANT SELECT, INSERT, UPDATE ON
  public.m2_business_contexts,
  public.m2_business_context_builds
TO p1_m2_runtime;

COMMIT;
