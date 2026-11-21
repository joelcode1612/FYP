-- Rollback for 20261121_02_finding_source_identity.sql.
--
-- Restores UNIQUE (assessment_id, assessment_revision, rule_id, rule_version),
-- drops the source_identity column, its trigger and both functions.
--
-- REFUSES while any (assessment_id, assessment_revision, rule_id, rule_version)
-- group holds more than one row. Those rows are the entire point of the
-- migration, and the restored 4-column key cannot represent them. Silently
-- deleting or merging findings to make the rollback fit would destroy evidence
-- that is append-only by design, so the operator must decide deliberately.
--
-- Explicit operator execution only. Never run at application startup.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $guard$
DECLARE
  duplicates integer;
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required';
  END IF;

  IF current_database() = 'Dss' THEN
    RAISE EXCEPTION 'Refusing to roll back finding identity on protected database %',
                    current_database();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'm2_bdj_findings'
                   AND column_name = 'source_identity') THEN
    RAISE EXCEPTION 'source_identity absent: migration not applied, nothing to roll back';
  END IF;

  SELECT count(*) INTO duplicates FROM (
    SELECT 1
      FROM public.m2_bdj_findings
     GROUP BY assessment_id, assessment_revision, rule_id, rule_version
    HAVING count(*) > 1
  ) AS multi;

  IF duplicates > 0 THEN
    RAISE EXCEPTION
      'Refusing rollback: % rule/revision group(s) hold multiple findings, which the '
      'restored 4-column key cannot represent. Resolve those findings deliberately '
      'before rolling back.', duplicates;
  END IF;
END
$guard$;

-- Order matters: drop the new key before the column it references.
ALTER TABLE public.m2_bdj_findings DROP CONSTRAINT uq_m2_bdj_finding_source;

ALTER TABLE public.m2_bdj_findings
  ADD CONSTRAINT uq_m2_bdj_rule_revision
    UNIQUE (assessment_id, assessment_revision, rule_id, rule_version);

DROP TRIGGER m2_bdj_derive_source_identity ON public.m2_bdj_findings;

ALTER TABLE public.m2_bdj_findings
  DROP CONSTRAINT ck_m2_bdj_source_identity,
  DROP COLUMN source_identity;

DROP FUNCTION public.m2_bdj_set_source_identity();
DROP FUNCTION public.m2_bdj_source_identity(json);

COMMIT;
