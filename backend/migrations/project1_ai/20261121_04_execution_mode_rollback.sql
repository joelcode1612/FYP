-- Rollback for 20261121_04_execution_mode.sql.
--
-- Drops the three columns and their constraints. Nothing is deleted: the
-- execution mode is descriptive metadata, and dropping it loses only the record
-- of WHO evaluated — which is precisely why this refuses while any row is
-- marked LIVE_PROVIDER_EXECUTION. Destroying the only evidence that a real
-- provider ran would let a later reader assume everything was deterministic.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
DECLARE live integer;
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required';
  END IF;

  IF current_database() = 'Dss' THEN
    RAISE EXCEPTION 'Refusing to roll back execution mode on protected database %',
                    current_database();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'project1_ai' AND table_name = 'bdj_results'
                   AND column_name = 'execution_mode') THEN
    RAISE EXCEPTION 'execution_mode absent: migration not applied, nothing to roll back';
  END IF;

  EXECUTE $q$SELECT count(*) FROM project1_ai.bdj_results
              WHERE execution_mode = 'LIVE_PROVIDER_EXECUTION'$q$ INTO live;
  IF live > 0 THEN
    RAISE EXCEPTION
      'Refusing rollback: % row(s) record a LIVE_PROVIDER_EXECUTION. Dropping the '
      'column would erase the only evidence that a real provider was called.', live;
  END IF;
END
$guard$;

ALTER TABLE project1_ai.bdj_results
  DROP CONSTRAINT ck_bdj_execution_status,
  DROP CONSTRAINT ck_bdj_execution_dispatch,
  DROP CONSTRAINT ck_bdj_execution_mode,
  DROP COLUMN provider_response_status,
  DROP COLUMN provider_dispatched,
  DROP COLUMN execution_mode;

COMMIT;
