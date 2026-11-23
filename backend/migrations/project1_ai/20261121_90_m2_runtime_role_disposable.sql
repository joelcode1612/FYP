-- Disposable-only M2 runtime principal for project1_workflow_tests@5433.
-- Migration: 20261121_90_m2_runtime_role_disposable
--
-- Authoritative reference: 20261116_02_m2_runtime_role.sql (Dss-only, unchanged).
-- Reproduces the applicable least-privilege grants and owner-scoped RLS for the
-- disposable cluster only. Refuses any other database, and refuses to run
-- without an explicit migration receipt. No password is written here.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $$
BEGIN
    IF current_database() <> 'project1_workflow_tests'
       OR current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
       OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
        RAISE EXCEPTION 'Explicit disposable target and migration receipt required';
    END IF;
    IF to_regclass('public.m2_assessments') IS NULL THEN
        RAISE EXCEPTION 'Existing M2 schema required';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_m2_runtime') THEN
        RAISE EXCEPTION 'p1_m2_runtime already exists: reconcile grants before migrating';
    END IF;
END $$;

CREATE ROLE p1_m2_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;

GRANT USAGE ON SCHEMA public TO p1_m2_runtime;
GRANT SELECT ON public.m2_instrument_versions, public.m2_item_versions TO p1_m2_runtime;

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

-- The actor is bound per request with set_config('project1.actor_id', …, false).
-- A helper keeps every policy free of nested quoting and fail-closed: an unset
-- actor yields NULL, so no comparison matches.
CREATE FUNCTION public.project1_actor() RETURNS uuid
LANGUAGE sql STABLE AS $fn$ SELECT nullif(current_setting('project1.actor_id', true), '')::uuid $fn$;

ALTER TABLE public.m2_assessments ENABLE ROW LEVEL SECURITY;
CREATE POLICY owner_scope ON public.m2_assessments
  USING (owner_user_id = public.project1_actor())
  WITH CHECK (owner_user_id = public.project1_actor());

DO $$
DECLARE t text;
BEGIN
    FOR t IN SELECT unnest(ARRAY[
        'm2_answer_revisions', 'm2_bdj_evaluations', 'm2_bdj_findings',
        'm2_review_events', 'm2_confirmation_snapshots',
        'm2_business_contexts', 'm2_business_context_builds'])
    LOOP
        IF to_regclass('public.' || t) IS NULL THEN CONTINUE; END IF;
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_schema='public' AND table_name=t
                         AND column_name='assessment_id') THEN CONTINUE; END IF;
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE POLICY owner_scope ON public.%I
            USING (EXISTS (SELECT 1 FROM public.m2_assessments a
                           WHERE a.id = %I.assessment_id
                             AND a.owner_user_id = public.project1_actor()))
            WITH CHECK (EXISTS (SELECT 1 FROM public.m2_assessments a
                           WHERE a.id = %I.assessment_id
                             AND a.owner_user_id = public.project1_actor()))', t, t, t);
    END LOOP;
END $$;

-- Uncertainties key on confirmation_id: scope through the snapshot.
DO $$
BEGIN
    IF to_regclass('public.m2_confirmed_uncertainties') IS NOT NULL THEN
        ALTER TABLE public.m2_confirmed_uncertainties ENABLE ROW LEVEL SECURITY;
        CREATE POLICY owner_scope ON public.m2_confirmed_uncertainties
          USING (EXISTS (SELECT 1 FROM public.m2_confirmation_snapshots s
                         JOIN public.m2_assessments a ON a.id = s.assessment_id
                         WHERE s.id = m2_confirmed_uncertainties.confirmation_id
                           AND a.owner_user_id = public.project1_actor()))
          WITH CHECK (EXISTS (SELECT 1 FROM public.m2_confirmation_snapshots s
                         JOIN public.m2_assessments a ON a.id = s.assessment_id
                         WHERE s.id = m2_confirmed_uncertainties.confirmation_id
                           AND a.owner_user_id = public.project1_actor()));
    END IF;
END $$;

ALTER TABLE public.m2_instrument_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.m2_item_versions ENABLE ROW LEVEL SECURITY;
CREATE POLICY reference_read ON public.m2_instrument_versions FOR SELECT USING (true);
CREATE POLICY reference_read ON public.m2_item_versions FOR SELECT USING (true);

COMMIT;
