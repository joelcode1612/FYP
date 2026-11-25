-- Rollback for 20261124_06_qg_consent.sql (DD-044).
--
-- Fails closed. Dropping these tables destroys owner permissions that were
-- granted explicitly and cannot be re-derived: unlike a derived fact, a consent
-- record has no source to recompute from. A rollback therefore refuses while
-- either table holds a row unless the operator states, in the session, that
-- discarding recorded consent is intended:
--
--   SELECT set_config('project1.qg_consent_rollback_discard',
--                     'I_ACCEPT_CONSENT_LOSS', false);
--
-- Order matters: the consumption table references the grant table, so it is
-- dropped first. Both guard functions go with their triggers.
--
-- This restores the pre-06 shape exactly: after rollback, consent can only be
-- read from m2_confirmation_snapshots.snapshot_json -> 'ai_processing_qg',
-- which is to say QG generation returns to AI_PROCESSING_QG_CONSENT_ABSENT for
-- every assessment. That is the state DD-044 described, and it is why this
-- rollback is not a neutral operation.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required';
  END IF;

  IF current_database() IN ('Dss', 'Final_Location_Analysis') THEN
    RAISE EXCEPTION 'Refusing to roll back QG consent store on protected database %',
                    current_database();
  END IF;
END
$guard$;

DO $dependent$
DECLARE
    grants       bigint := 0;
    consumptions bigint := 0;
BEGIN
  IF to_regclass('public.m2_qg_consent_grants') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.m2_qg_consent_grants' INTO grants;
  END IF;
  IF to_regclass('public.m2_qg_consent_consumptions') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.m2_qg_consent_consumptions' INTO consumptions;
  END IF;

  IF (grants + consumptions) > 0
     AND current_setting('project1.qg_consent_rollback_discard', true)
         IS DISTINCT FROM 'I_ACCEPT_CONSENT_LOSS' THEN
    RAISE EXCEPTION 'Cannot roll back: % consent grant(s) and % consumption(s) '
                    'are recorded and cannot be re-derived. Set '
                    'project1.qg_consent_rollback_discard to '
                    'I_ACCEPT_CONSENT_LOSS to discard them deliberately.',
                    grants, consumptions;
  END IF;
END
$dependent$;

DROP TRIGGER IF EXISTS m2_qg_consent_consumption_guard_trg
    ON public.m2_qg_consent_consumptions;
DROP TRIGGER IF EXISTS m2_qg_consent_guard_trg
    ON public.m2_qg_consent_grants;

DROP FUNCTION IF EXISTS public.m2_qg_consent_consumption_guard();
DROP FUNCTION IF EXISTS public.m2_qg_consent_guard();

DROP TABLE IF EXISTS public.m2_qg_consent_consumptions;
DROP TABLE IF EXISTS public.m2_qg_consent_grants;

COMMIT;
