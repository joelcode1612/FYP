-- =====================================================================
-- Rollback for 20261125_05.
--
-- Removes exactly what the up migration added: the predicate function and the
-- five closure columns (the three CHECK constraints go with the columns, except
-- the closure-record one, which references only remaining columns and is
-- dropped explicitly). The ledger row is removed so a re-apply is possible.
--
-- Refuses if any row is already ENDED: dropping the closure record of a real
-- closure would destroy evidence rather than undo a schema change.
-- =====================================================================
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$ BEGIN
  IF to_regclass('public.cq_collection_state') IS NULL THEN
    RAISE EXCEPTION 'cq_collection_state missing';
  END IF;
  IF EXISTS (SELECT 1 FROM public.cq_collection_state
              WHERE lifecycle_state = 'ENDED') THEN
    RAISE EXCEPTION 'refusing to roll back: a closure record already exists';
  END IF;
END $$;

DROP FUNCTION IF EXISTS public.cq_collection_closed(uuid);

ALTER TABLE public.cq_collection_state
    DROP CONSTRAINT IF EXISTS cq_collection_state_closure_record,
    DROP CONSTRAINT IF EXISTS cq_collection_state_disposition_check,
    DROP CONSTRAINT IF EXISTS cq_collection_state_policy_check,
    DROP COLUMN IF EXISTS evidence_cutoff,
    DROP COLUMN IF EXISTS completion_policy,
    DROP COLUMN IF EXISTS in_progress_disposition,
    DROP COLUMN IF EXISTS target_at_closure,
    DROP COLUMN IF EXISTS reached_at_closure;

DELETE FROM cq_schema_migrations WHERE version = '20261125_05';

COMMIT;
