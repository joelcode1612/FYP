-- Rollback for 20261122_0700_admission_objective_binding.
--
-- Drops only what that migration added. It does NOT touch the admission rows
-- themselves: an admission is an owner decision and destroying it to tidy a
-- schema would be exactly the history deletion 03_STATUS_AND_TRANSITIONS.md
-- forbids. Dropping the columns is reversible; the decisions stay.
--
-- Guarded identically to the forward migration.

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
BEGIN
  IF inet_server_port() = 5432 THEN
    RAISE EXCEPTION 'Refusing to roll back on the protected cluster (port 5432)';
  END IF;
  IF current_database() NOT LIKE 'project1\_%' THEN
    RAISE EXCEPTION 'Unexpected target %', current_database();
  END IF;
END
$guard$;

ALTER TABLE public.m2_bdj_objective_admissions
    DROP COLUMN IF EXISTS policy_resolution,
    DROP COLUMN IF EXISTS policy_disposition,
    DROP COLUMN IF EXISTS policy_classification,
    DROP COLUMN IF EXISTS policy_version,
    DROP COLUMN IF EXISTS objective_id;

COMMIT;
