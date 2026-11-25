-- =====================================================================
-- 20261125_04 (down) — remove the collection state surface
--
-- Rollback for 20261125_04_cq_collection_state.sql. Additive and complete: the
-- migration created exactly one table, four policies and two grants, so the
-- rollback drops exactly those and nothing else.
--
-- Order matters: policies die with the table, but the grants are on the table
-- too, so a single DROP TABLE removes all of it. The ledger row is removed last
-- so the migration can be re-applied with the same bytes.
--
-- This refuses to run if any row exists: dropping the table would destroy a
-- target or an End Collection decision, and that is data loss, not rollback.
-- Take a backup and delete the rows deliberately first.
--
-- Explicit operator execution only. Never run at startup.
-- =====================================================================
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$ BEGIN
  IF current_setting('project1.cq_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.cq_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and receipt required';
  END IF;
  IF to_regclass('public.cq_collection_state') IS NULL THEN
    RAISE NOTICE 'cq_collection_state absent; nothing to roll back';
  ELSE
    IF EXISTS (SELECT 1 FROM public.cq_collection_state) THEN
      RAISE EXCEPTION 'cq_collection_state holds rows; refusing to destroy '
                      'targets or End Collection decisions';
    END IF;
  END IF;
END $$;

DROP TABLE IF EXISTS public.cq_collection_state;

DELETE FROM cq_schema_migrations WHERE version = '20261125_04';

COMMIT;
