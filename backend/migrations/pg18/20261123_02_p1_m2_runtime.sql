-- PROJECT1 PG18 isolated environment — Phase P1 (helper function + M2 owner-scope RLS)
-- Migration: 20261123_02_p1_m2_runtime
-- Target:    project1_pg18_migrated_tests @ 127.0.0.1:5544
--
-- Why this file exists
-- --------------------
-- Phase P2–P5 (``migrations/sql/20261122_0300_*``) refuse to run without
-- ``public.project1_actor()``, because two of the eight policies name it and a
-- ``CREATE POLICY`` against a missing function is an error, not a default-deny.
--
-- The authoritative reference is
-- ``migrations/project1_ai/20261121_90_m2_runtime_role_disposable.sql``, but
-- that file refuses any database whose name is not ``project1_workflow_tests``.
-- Copying it verbatim would re-freeze the test-only identity into the PG18
-- architecture — the exact defect recorded in
-- PROJECT1_DATABASE_ARCHITECTURE_ADVERSARIAL_REVIEW.md §2.2.
--
-- So this file reproduces the *substance* (helper + owner-scope policies +
-- least-privilege grants) against an environment-neutral guard, and differs in
-- exactly three deliberate ways:
--
--   1. The guard accepts any ``project1_pg18_*`` database on a non-5432/5433
--      port, and still refuses ``Dss`` / ``Final_Location_Analysis``.
--   2. The role is NOT created here — ``20261123_00_roles.sql`` owns principals,
--      so this file never holds a password.
--   3. Every policy is dropped-then-created, so a rerun reconciles rather than
--      failing on "policy already exists".
--
-- Withheld on purpose: no grants on ``m2_research_*``,
-- ``m2_review_question_versions``, ``m2_desired_options`` or ``m2_candidate_*``.
-- Those surfaces have no execution endpoint and their owner scope cannot be
-- expressed from the current columns, so access stays closed rather than
-- approximated.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $$
BEGIN
    IF current_database() IN ('Dss', 'Final_Location_Analysis') THEN
        RAISE EXCEPTION 'REFUSED: % is a protected database', current_database();
    END IF;
    IF current_database() NOT LIKE 'project1\_pg18\_%' THEN
        RAISE EXCEPTION 'REFUSED: expected a project1_pg18_* database, connected to %',
            current_database();
    END IF;
    IF inet_server_port() IN (5432, 5433) THEN
        RAISE EXCEPTION 'REFUSED: port % is a protected or legacy cluster', inet_server_port();
    END IF;
    IF coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
        RAISE EXCEPTION 'Explicit migration receipt required';
    END IF;
    IF to_regclass('public.m2_assessments') IS NULL THEN
        RAISE EXCEPTION 'Existing M2 schema required: restore the baseline first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_m2_runtime') THEN
        RAISE EXCEPTION 'p1_m2_runtime is missing: apply 20261123_00_roles.sql first';
    END IF;
END $$;

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
-- Fail-closed: an unset actor yields NULL, so no comparison matches.
CREATE OR REPLACE FUNCTION public.project1_actor() RETURNS uuid
LANGUAGE sql STABLE AS $fn$ SELECT nullif(current_setting('project1.actor_id', true), '')::uuid $fn$;

ALTER TABLE public.m2_assessments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS owner_scope ON public.m2_assessments;
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
        EXECUTE format('DROP POLICY IF EXISTS owner_scope ON public.%I', t);
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
        DROP POLICY IF EXISTS owner_scope ON public.m2_confirmed_uncertainties;
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
DROP POLICY IF EXISTS reference_read ON public.m2_instrument_versions;
DROP POLICY IF EXISTS reference_read ON public.m2_item_versions;
CREATE POLICY reference_read ON public.m2_instrument_versions FOR SELECT USING (true);
CREATE POLICY reference_read ON public.m2_item_versions FOR SELECT USING (true);

COMMIT;
