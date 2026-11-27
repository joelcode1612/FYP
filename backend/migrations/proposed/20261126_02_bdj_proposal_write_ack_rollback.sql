-- ROLLBACK for 20261126_02_bdj_proposal_write_ack.sql
-- PROPOSAL ONLY — NOT APPLIED.
--
-- Reverses every object the forward migration creates. The forward migration
-- adds one table and one index and touches nothing else, so the rollback is a
-- drop and nothing more.
--
-- What is lost
-- ------------
-- The acknowledgment rows themselves. They record "this attempt's governed
-- write committed, and it wrote N recommendations". Dropping them does not
-- touch the proposals they describe: `public.m2_bdj_objective_proposals` is not
-- referenced by this table and no row there is modified by either direction.
--
-- Consequence after rollback
-- --------------------------
-- `persisted = 0` becomes ambiguous again for a bound attempt: it can no longer
-- be told apart from "the write failed before inserting anything". The status
-- projection already fails closed for that case (`RETURNED /
-- RETURNED_NOT_PERSISTED`) and needs no change, because it only consults this
-- table when it exists.
--
-- Order matters
-- -------------
-- The table must be dropped before 20261126_01 is rolled back: its foreign keys
-- reference `project1_ai.runs (id, owner_user_id)` and
-- `project1_ai.runs (id, assessment_id)`, both of which that rollback drops.
-- Rolling 01 back first leaves these constraints dangling and the drop of 01
-- fails.

BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '60s';

DO $$
BEGIN
  IF current_setting('project1.migration_target', true)
       IS DISTINCT FROM current_database()
     OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
    RAISE EXCEPTION 'Explicit reviewed database identity and receipt required';
  END IF;
END $$;

-- 1. The index goes with the table, but dropping it explicitly keeps the
--    reversal readable and lets the script be re-run after a partial failure.
DROP INDEX IF EXISTS project1_ai.objective_writes_assessment_idx;

-- 2. The table.
DROP TABLE IF EXISTS project1_ai.objective_writes;

COMMIT;
