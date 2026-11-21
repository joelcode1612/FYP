-- D3: give a BDJ finding a source identity so two findings from one rule can
-- coexist, and so re-running the same execution stays idempotent.
--
-- WHY THIS EXISTS
-- public.m2_bdj_findings currently carries
--   UNIQUE (assessment_id, assessment_revision, rule_id, rule_version)
-- which says "at most one finding per rule per revision". That is true of the
-- retired contradiction rulesets, where a rule was a single assertion about the
-- whole declaration set. It is false of the information-gap ruleset, where one
-- rule fires once per source item: answering M2V1-01 and M2V1-02 both
-- UNDECIDED is two distinct findings from one rule. The current key rejects the
-- second with SQLSTATE 23505 and aborts the entire result persist, because the
-- link insert runs in the same transaction.
--
-- WHAT THIS CHANGES
--   1. Adds source_identity text NOT NULL, the SHA-256 of the finding's own
--      sorted source answer ids. It is the finding's source, not its prose.
--   2. Replaces the 4-column unique key with
--        (assessment_id, assessment_revision, rule_id, rule_version, source_identity)
--      Same execution replayed -> same identity -> still one row (idempotent).
--      Different sources -> different identity -> two rows (allowed).
--   3. Derives the value in the DATABASE via a BEFORE INSERT trigger, so a
--      writer cannot supply a value that disagrees with the ids it stored.
--      The column is append-only by the existing m2_bcb_append_only trigger,
--      so once written it cannot be corrected by an UPDATE.
--
-- CANONICAL FORM (must match the application exactly)
--   source_identity = sha256( ',' . join( sorted(source_answer_ids) ) )
--   sorted by byte order (COLLATE "C"), UTF-8, no spaces.
--   Python equivalent:
--     hashlib.sha256(','.join(sorted(ids)).encode('utf-8')).hexdigest()
--   An empty array hashes the empty string. Duplicate ids are NOT deduplicated;
--   a caller that repeats a source id gets a different identity on purpose.
--
-- REQUIRED CO-CHANGES IN APPLICATION CODE (this migration does not make them)
--   * M2Repository.find_current_finding() looks up the exact 4-column key and
--     will raise MultipleResultsFound once two rows share it. It must add
--     source_identity to the lookup.
--   * M2ContextBindings builds {rule_id: rule_version}, a dict that silently
--     collapses duplicate rule ids. It must become a list, or be keyed by
--     finding id.
--   * The four test fixtures that duplicate this constraint
--     (tests/m2_bcb/fixtures/dss_m2_schema_20261113.sql,
--      tests/cq_runtime/fixtures/dss_m2_schema_20261113.sql,
--      tests/cp07/fixtures/stage_m2_schema.sql,
--      src/sitewise/db/models/m2_schema.py)
--     must be updated in the same change, or the suite runs a stale schema.
--
-- STATUS: PROPOSED. NOT APPLIED. Refuses the protected database by name; a
-- separately reviewed Dss variant plus backup, role/lock checks and written
-- authorization are required before this can run anywhere real.
--
-- Explicit operator execution only. Never run at application startup.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $guard$
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required '
                    '(project1.m2_bcb_migration_target must equal current_database(); '
                    'project1.m2_bcb_migration_receipt must be non-empty)';
  END IF;

  IF current_database() = 'Dss' THEN
    RAISE EXCEPTION 'Refusing to alter finding identity on protected database %',
                    current_database();
  END IF;

  IF to_regclass('public.m2_bdj_findings') IS NULL THEN
    RAISE EXCEPTION 'public.m2_bdj_findings missing; nothing to migrate';
  END IF;

  -- Refuse to re-run rather than half-apply.
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'm2_bdj_findings'
               AND column_name = 'source_identity') THEN
    RAISE EXCEPTION 'source_identity already exists: reconcile version before migrating';
  END IF;

  -- The old key must be the one we think it is. Discovered, never guessed.
  IF NOT EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.m2_bdj_findings'::regclass
        AND conname = 'uq_m2_bdj_rule_revision'
        AND contype = 'u'
  ) THEN
    RAISE EXCEPTION 'expected constraint uq_m2_bdj_rule_revision not found: '
                    'reconcile schema drift before migrating';
  END IF;
END
$guard$;

-- ---------------------------------------------------------------------------
-- 1. Canonical identity function
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.m2_bdj_source_identity(source_ids json) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(sha256(convert_to(coalesce((
    SELECT string_agg(value, ',' ORDER BY value COLLATE "C")
    FROM json_array_elements_text(source_ids) AS value
  ), ''), 'UTF8')), 'hex')
$$;

COMMENT ON FUNCTION public.m2_bdj_source_identity(json) IS
  'SHA-256 over the sorted, comma-joined source answer ids. This is the single '
  'definition of a finding''s source identity; the BEFORE INSERT trigger uses '
  'it and so must the application, or the two will disagree and idempotency '
  'breaks. Sorted with COLLATE "C" so the order is byte order, matching a '
  'plain sorted() in Python.';

-- ---------------------------------------------------------------------------
-- 2. Column, backfill, constraints
-- ---------------------------------------------------------------------------
ALTER TABLE public.m2_bdj_findings ADD COLUMN source_identity text;

UPDATE public.m2_bdj_findings
   SET source_identity = public.m2_bdj_source_identity(source_answer_ids);

ALTER TABLE public.m2_bdj_findings
  ALTER COLUMN source_identity SET NOT NULL,
  ADD CONSTRAINT ck_m2_bdj_source_identity
    CHECK (source_identity ~ '^[a-f0-9]{64}$');

COMMENT ON COLUMN public.m2_bdj_findings.source_identity IS
  'Source identity of this finding: sha256 of its sorted source answer ids. '
  'Part of the uniqueness key, so two findings from one rule coexist when they '
  'cite different sources, while a replay of the same execution stays a single '
  'row. Derived by trigger; never supplied by a writer.';

-- ---------------------------------------------------------------------------
-- 3. Database-derived value
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.m2_bdj_set_source_identity() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.source_identity := public.m2_bdj_source_identity(NEW.source_answer_ids);
  RETURN NEW;
END $$;

CREATE TRIGGER m2_bdj_derive_source_identity
  BEFORE INSERT ON public.m2_bdj_findings
  FOR EACH ROW EXECUTE FUNCTION public.m2_bdj_set_source_identity();

-- ---------------------------------------------------------------------------
-- 4. Replace the uniqueness key
-- ---------------------------------------------------------------------------
ALTER TABLE public.m2_bdj_findings DROP CONSTRAINT uq_m2_bdj_rule_revision;

ALTER TABLE public.m2_bdj_findings
  ADD CONSTRAINT uq_m2_bdj_finding_source
    UNIQUE (assessment_id, assessment_revision, rule_id, rule_version, source_identity);

COMMENT ON CONSTRAINT uq_m2_bdj_finding_source ON public.m2_bdj_findings IS
  'One finding per rule per source. Replaces uq_m2_bdj_rule_revision, which '
  'could not represent two findings from one rule for different item revisions.';

-- ---------------------------------------------------------------------------
-- 5. Record
-- ---------------------------------------------------------------------------
-- The m2 migration family keeps no schema-version table, so this file records
-- nothing itself. The operator's migration receipt (project1.m2_bcb_migration_receipt)
-- is the record; capture it in the run log alongside the file's SHA-256.
-- Do not invent a version table here: a table nobody reads is worse than none.

COMMIT;
