-- =====================================================================
-- 20261125_06 — a below-target closure must state its reason
--
-- Why this exists (owner directive, 2026-11-25)
--   The owner adopted ``OWNER_DISCRETION`` as the only policy that permits
--   closing collection while ``reached < target``, **with a mandatory recorded
--   reason**. Before this migration the reason was optional: ``end_collection``
--   accepted ``reason=None`` and the column was nullable, so a closure could be
--   recorded that said ``130/129`` and nothing about why. That is auditable as
--   *that* a decision was taken, but not as *what* was decided.
--
-- Why no new column
--   ``end_reason varchar(200)`` already exists (20261125_04) and
--   ``end_collection`` already writes it. The gap is enforcement, not storage.
--   Adding a second reason column would create two places to look and a silent
--   precedence question; a CHECK on the existing column makes the rule
--   unbypassable by any caller, including a future one that forgets to validate.
--
-- Why the constraint is scoped to OWNER_DISCRETION
--   ``TARGET_REACHED_ONLY`` needs no justification: the target was met, and the
--   policy itself is the statement. Requiring prose there would be noise. The
--   rule is therefore "if you closed below target, say why", not "always say
--   why".
--
-- Existing rows
--   The one ENDED row already carries
--   ``'cohort finished; below target acknowledged'``, so this constraint
--   validates without a backfill. No historical value is rewritten and the
--   constraint is created VALID, not NOT VALID.
--
-- Additive only: one CHECK, one comment. No column added or dropped, no grant
-- changed, no policy changed.
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
  IF to_regclass('public.cq_collection_state') IS NULL THEN
    RAISE EXCEPTION 'cq_collection_state missing: apply 20261125_04 first';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public'
                    AND table_name = 'cq_collection_state'
                    AND column_name = 'end_reason') THEN
    RAISE EXCEPTION 'end_reason missing: apply 20261125_04 first';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conname = 'cq_collection_state_owner_reason_chk'
                AND conrelid = 'public.cq_collection_state'::regclass) THEN
    RAISE EXCEPTION 'cq_collection_state_owner_reason_chk already exists';
  END IF;
END $$;

-- The rule. ``btrim(...) <> ''`` because a string of spaces is not a reason.
ALTER TABLE public.cq_collection_state
    ADD CONSTRAINT cq_collection_state_owner_reason_chk
    CHECK (completion_policy IS DISTINCT FROM 'OWNER_DISCRETION'
           OR (end_reason IS NOT NULL AND btrim(end_reason) <> ''));

COMMENT ON COLUMN public.cq_collection_state.end_reason IS
  'Free-text reason for the closure. REQUIRED when completion_policy = '
  'OWNER_DISCRETION (below-target closure); optional under TARGET_REACHED_ONLY. '
  'Enforced by cq_collection_state_owner_reason_chk, not only by the service.';

-- Post-state assertions ---------------------------------------------------
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'cq_collection_state_owner_reason_chk'
                    AND conrelid = 'public.cq_collection_state'::regclass) THEN
    RAISE EXCEPTION 'constraint was not created';
  END IF;
  IF NOT (SELECT convalidated FROM pg_constraint
           WHERE conname = 'cq_collection_state_owner_reason_chk'
             AND conrelid = 'public.cq_collection_state'::regclass) THEN
    RAISE EXCEPTION 'constraint must be VALID, not NOT VALID';
  END IF;

  -- The constraint must carry the rule, not merely exist. Read the stored
  -- definition back rather than trusting the statement above: a CHECK that had
  -- been written ``completion_policy IS NULL OR ...`` would still create.
  IF NOT (SELECT pg_get_constraintdef(oid)
            FROM pg_constraint
           WHERE conname = 'cq_collection_state_owner_reason_chk'
             AND conrelid = 'public.cq_collection_state'::regclass)
         LIKE '%OWNER_DISCRETION%' THEN
    RAISE EXCEPTION 'constraint does not mention OWNER_DISCRETION';
  END IF;
  IF NOT (SELECT pg_get_constraintdef(oid)
            FROM pg_constraint
           WHERE conname = 'cq_collection_state_owner_reason_chk'
             AND conrelid = 'public.cq_collection_state'::regclass)
         LIKE '%btrim%' THEN
    RAISE EXCEPTION 'constraint does not reject a blank reason';
  END IF;

  -- Enforcement itself is proven behaviourally by
  -- backend/var/e2e/pg18/cq_flow_20261125/step12_reason_required.py, in a
  -- rolled-back transaction against a real campaign. A probe insert here could
  -- not prove it: campaign_id is the primary key and also a foreign key, so the
  -- FK fires before the CHECK and the CHECK would never be exercised.
  IF EXISTS (SELECT 1 FROM public.cq_collection_state
              WHERE completion_policy = 'OWNER_DISCRETION'
                AND (end_reason IS NULL OR btrim(end_reason) = '')) THEN
    RAISE EXCEPTION 'an existing ENDED row has no reason; backfill before applying';
  END IF;

  -- Nothing else may have changed.
  IF has_table_privilege('p1_ee01_runtime',
                         'public.cq_collection_state', 'DELETE') THEN
    RAISE EXCEPTION 'DELETE appeared on cq_collection_state';
  END IF;
END $$;

INSERT INTO cq_schema_migrations(version, migration_sha256, receipt)
VALUES ('20261125_06', current_setting('project1.cq_migration_sha256'),
        current_setting('project1.cq_migration_receipt'))
ON CONFLICT (version) DO NOTHING;

COMMIT;
