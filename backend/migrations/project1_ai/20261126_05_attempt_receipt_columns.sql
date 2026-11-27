-- DD-174: attempt_receipts is missing the two columns ledger.finish() writes.
--
-- `project1_ai.attempt_receipts` was created by
-- `20261111_01_candidate_ledger.sql` with five columns. `ledger.finish()` then
-- began writing `model_returned` and `provider_response_status` as well, and no
-- migration in this tree ever added them. The result is a schema the code cannot
-- write and the migrations cannot reproduce:
--
--   INSERT INTO project1_ai.attempt_receipts (run_id, owner_user_id, attempt_no,
--     outcome, output_digest, model_returned, provider_response_status)
--   -> ERROR: column "model_returned" of relation "attempt_receipts" does not exist
--
-- Measured on the disposable clone built from these migrations:
-- `tests/project1/test_result_store.py` -> 25 failed / 2 passed / 3 skipped, every
-- failure the same UndefinedColumn.
--
-- Additive and idempotent. The bounds mirror what `ledger.finish()` already
-- enforces before it inserts (it nulls a `model_returned` longer than 128
-- characters and a status outside 100..599), so the constraint cannot reject a
-- value the writer was willing to send — it only stops another writer from
-- storing what the ledger itself refuses.
--
-- `bdj_results` already carries `model_returned` with the same 1..128 bound
-- (`20261117_03_bdj_result_persistence.sql`), so the two ledgers agree on the
-- provider's own label rather than diverging.
--
-- No existing row is rewritten. Both columns are nullable with no default, so a
-- receipt written before this migration keeps reading exactly as it did.
BEGIN;

ALTER TABLE project1_ai.attempt_receipts
  ADD COLUMN IF NOT EXISTS model_returned text,
  ADD COLUMN IF NOT EXISTS provider_response_status integer;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'project1_ai.attempt_receipts'::regclass
       AND conname = 'attempt_receipts_model_returned_chk') THEN
    ALTER TABLE project1_ai.attempt_receipts
      ADD CONSTRAINT attempt_receipts_model_returned_chk
      CHECK (model_returned IS NULL
             OR length(model_returned) BETWEEN 1 AND 128);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'project1_ai.attempt_receipts'::regclass
       AND conname = 'attempt_receipts_provider_status_chk') THEN
    ALTER TABLE project1_ai.attempt_receipts
      ADD CONSTRAINT attempt_receipts_provider_status_chk
      CHECK (provider_response_status IS NULL
             OR provider_response_status BETWEEN 100 AND 599);
  END IF;
END $$;

COMMIT;
