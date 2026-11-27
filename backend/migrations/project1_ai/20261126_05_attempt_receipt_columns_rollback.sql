-- Rollback for 20261126_05_attempt_receipt_columns.sql (DD-174).
--
-- Dropping these columns discards whatever the ledger recorded about which model
-- actually returned and what HTTP status the provider sent. That is metadata, not
-- source content, but it is evidence of a call having happened, so the rollback is
-- written to be explicit rather than silent: it refuses while any receipt holds a
-- value, and the operator must delete those values deliberately first.
BEGIN;

DO $$
DECLARE populated bigint;
BEGIN
    SELECT count(*) INTO populated
      FROM project1_ai.attempt_receipts
     WHERE model_returned IS NOT NULL
        OR provider_response_status IS NOT NULL;
    IF populated > 0 THEN
        RAISE EXCEPTION
            'refusing to drop: % receipt(s) still hold model_returned or '
            'provider_response_status; clear them deliberately first', populated;
    END IF;
END $$;

ALTER TABLE project1_ai.attempt_receipts
  DROP CONSTRAINT IF EXISTS attempt_receipts_model_returned_chk,
  DROP CONSTRAINT IF EXISTS attempt_receipts_provider_status_chk,
  DROP COLUMN IF EXISTS model_returned,
  DROP COLUMN IF EXISTS provider_response_status;

COMMIT;
