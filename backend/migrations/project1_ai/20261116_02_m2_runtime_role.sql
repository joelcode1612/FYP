-- REVIEW CANDIDATE, EXPLICIT OPERATOR EXECUTION ONLY. Never run at startup.
--
-- Purpose: give the M2/BCB application a least-privilege LOGIN role in `Dss`
-- that is NOT a superuser and does NOT hold BYPASSRLS, together with the
-- owner-scoped RLS policies the existing M2 tables lack. Without policies a
-- non-owner role reads zero rows even with table grants, because the tables
-- already have ROW LEVEL SECURITY enabled.
--
-- Requires a reviewed target and receipt, e.g.:
--   SET project1.migration_target='Dss';
--   SET project1.migration_receipt='<actual reviewed change record>';
--
-- Deliberately withheld: no grants on the research-objective / candidate-question
-- tables (m2_research_*, m2_review_question_versions, m2_desired_options,
-- m2_candidate_*). Those surfaces have no execution endpoint and their owner
-- scope cannot be expressed from the current columns, so access stays closed
-- rather than being approximated.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $$
BEGIN
  IF current_database() <> 'Dss'
     OR current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
     OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
    RAISE EXCEPTION 'Explicit reviewed database identity and receipt required';
  END IF;
  IF to_regclass('public.m2_assessments') IS NULL THEN
    RAISE EXCEPTION 'Existing M2 schema required';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_m2_runtime') THEN
    RAISE EXCEPTION 'p1_m2_runtime already exists: reconcile grants before migrating';
  END IF;
END $$;

-- Login role, no escalation path. The password is provisioned separately by the
-- operator and never stored in this file.
CREATE ROLE p1_m2_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;

GRANT USAGE ON SCHEMA public TO p1_m2_runtime;

-- Global reference data: read-only.
GRANT SELECT ON public.m2_instrument_versions, public.m2_item_versions TO p1_m2_runtime;

-- Owner-scoped M2 core. No DELETE: no M2 route deletes rows.
GRANT SELECT, INSERT, UPDATE ON
  public.m2_assessments,
  public.m2_answer_revisions,
  public.m2_bdj_evaluations,
  public.m2_bdj_findings,
  public.m2_review_events,
  public.m2_confirmation_snapshots,
  public.m2_confirmed_uncertainties,
  public.m2_clarification_events
TO p1_m2_runtime;

GRANT SELECT, INSERT, UPDATE ON
  public.m2_business_contexts,
  public.m2_business_context_builds
TO p1_m2_runtime;

-- ---- RLS policies -------------------------------------------------------
-- The actor is bound per request by the application as
--   set_config('project1.actor_id', <uuid>, false)
-- on a non-pooled connection. An unset/blank actor yields NULL, so the
-- comparison is false and the row is invisible: fail closed.

CREATE POLICY owner_scope ON public.m2_assessments
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);

-- Child rows inherit scope from the assessment. The subquery is itself subject
-- to the m2_assessments policy, so this cannot widen access.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
      'm2_answer_revisions', 'm2_bdj_evaluations', 'm2_bdj_findings',
      'm2_review_events', 'm2_confirmation_snapshots', 'm2_clarification_events']
  LOOP
    EXECUTE format(
      'CREATE POLICY owner_scope ON public.%I
         USING (assessment_id IN (SELECT id FROM public.m2_assessments))
         WITH CHECK (assessment_id IN (SELECT id FROM public.m2_assessments))', t);
  END LOOP;
END $$;

CREATE POLICY owner_scope ON public.m2_confirmed_uncertainties
  USING (confirmation_id IN (SELECT id FROM public.m2_confirmation_snapshots))
  WITH CHECK (confirmation_id IN (SELECT id FROM public.m2_confirmation_snapshots));

CREATE POLICY owner_scope ON public.m2_business_contexts
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);

CREATE POLICY owner_scope ON public.m2_business_context_builds
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);

-- Reference data is not owner-scoped, but RLS is enabled, so it needs an
-- explicit read policy or it would also read as empty.
CREATE POLICY reference_read ON public.m2_instrument_versions FOR SELECT USING (true);
CREATE POLICY reference_read ON public.m2_item_versions FOR SELECT USING (true);

COMMIT;
