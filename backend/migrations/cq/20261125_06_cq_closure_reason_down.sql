-- =====================================================================
-- 20261125_06 (down) — remove the mandatory-reason rule
--
-- Dropping a CHECK removes enforcement; it does not delete data. Every reason
-- already recorded stays in ``end_reason``, so the evidence survives the
-- rollback even though the rule that required it does not.
--
-- This is the opposite of 20261125_05's down migration, which refuses to run
-- once a closure exists because dropping the *columns* would destroy the
-- closure record. Here nothing is destroyed.
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
END $$;

ALTER TABLE public.cq_collection_state
    DROP CONSTRAINT IF EXISTS cq_collection_state_owner_reason_chk;

COMMENT ON COLUMN public.cq_collection_state.end_reason IS
  'Operator/owner-supplied label; not a governed vocabulary (DD-097 policy open).';

DELETE FROM cq_schema_migrations WHERE version = '20261125_06';

COMMIT;
