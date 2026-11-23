-- Disposable-only correction: restore the recorded creation timestamp default.
-- Migration: 20261122_10_bcb_created_at_disposable
--
-- DEFECT D8. The adopted BCB schema (migrations/m2/20261113_01_confirmed_
-- context_persistence.sql) declares:
--
--     created_at timestamptz NOT NULL DEFAULT now()
--
-- on both public.m2_business_contexts and public.m2_business_context_builds.
-- The disposable cluster drifted: both columns are nullable with no default,
-- so every row persisted there recorded NULL. Because ContextResponse and
-- ContextStatusResponse typed the field as a required datetime, the BCB read
-- and status endpoints answered HTTP 500 with a ResponseValidationError.
--
-- What this migration does
--   * restores DEFAULT now() on both columns, so any row inserted from now on
--     carries the timestamp of its own insert transaction.
--
-- What this migration deliberately does NOT do
--   * it does not back-fill the existing rows. Their creation times are not
--     recoverable: m2_business_context_builds is not a reliable witness (the
--     primary build row was later overwritten by a HELD attempt with
--     context_id NULL and a much later updated_at), and no other table records
--     when a context was inserted. Writing a plausible value would fabricate
--     provenance, so the NULLs stay NULL and the API reports null.
--   * it does not add NOT NULL. That constraint cannot be applied while the
--     two historical rows are NULL, and it must not be satisfied by inventing
--     values. The drift from the adopted DDL is therefore recorded here rather
--     than silently closed.
--   * it does not touch RLS, grants, triggers, packet integrity or any other
--     column. It is additive metadata only.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

DO $$
BEGIN
    IF current_database() <> 'project1_workflow_tests' THEN
        RAISE EXCEPTION 'Disposable target only';
    END IF;
    IF inet_server_port() = 5432 THEN
        RAISE EXCEPTION 'Refused: the default port is not a disposable cluster';
    END IF;
    IF current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
       OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
        RAISE EXCEPTION 'Explicit target and migration receipt required';
    END IF;
    IF to_regclass('public.m2_business_contexts') IS NULL
       OR to_regclass('public.m2_business_context_builds') IS NULL THEN
        RAISE EXCEPTION 'BCB tables missing: apply the context schema first';
    END IF;
END $$;

ALTER TABLE public.m2_business_contexts
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE public.m2_business_context_builds
  ALTER COLUMN created_at SET DEFAULT now();

COMMENT ON COLUMN public.m2_business_contexts.created_at IS
  'Insert transaction timestamp. Nullable on this disposable cluster only: '
  'two pre-default rows have no recoverable creation time and were not '
  'back-filled. The adopted DDL declares NOT NULL DEFAULT now().';

COMMENT ON COLUMN public.m2_business_context_builds.created_at IS
  'Insert transaction timestamp. Nullable on this disposable cluster only; see '
  'm2_business_contexts.created_at.';

COMMIT;
