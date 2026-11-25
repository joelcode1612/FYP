-- =====================================================================
-- 20261125_02 — CQ publication principal (DD-096)
--
-- Problem
--   Publication has no application-level principal. The four release tables
--   (`cq_bank_versions`, `cq_manifest_releases`, `cq_question_assignments`,
--   `cq_campaigns`) are owned by `postgres`, RLS is enabled but not FORCEd,
--   and every policy on them is declared `TO p1_ee01_runtime`. Measured
--   consequences (dd096_publication_permission_probe.py, 2026-11-25):
--
--     sitewise_e2e      releases_visible=0   (holds SELECT,INSERT,UPDATE,DELETE
--                                             and still cannot use them)
--     p1_m2_runtime     releases_visible=0
--     p1_ee01_runtime   releases_visible=0   unbound
--     p1_ee01_runtime   releases_visible=1   with project1.actor_id bound
--     operator          releases_visible=1   (owns the tables; RLS not FORCEd)
--
--   So the only executable publication principal is the operator, and no
--   policy distinguishes "an entrepreneur publishing their own instrument"
--   from "the respondent runtime minting the instrument it answers". Both are
--   the same role. That is the defect.
--
-- What this migration creates
--   One new principal, `p1_cq_publisher`, and the policies that make it able
--   to do exactly one thing: write the release built from an assessment the
--   authenticated actor owns. It cannot read a respondent's evidence, it
--   cannot write a session, and it cannot publish against somebody else's
--   assessment.
--
-- Why a separate role and not a grant to p1_ee01_runtime
--   `cq/20261124_01:21-29` already rejected splitting the *respondent* path
--   across two principals, and that decision stands: the fifteen evidence
--   INSERTs and the campaign INSERT stay where they are. This migration does
--   not move any of them. It adds a second principal for a different
--   operation, which is what "separate publication permissions from
--   respondent runtime permissions" means in practice. If publication were
--   granted to `p1_ee01_runtime`, the respondent process would hold INSERT on
--   the instrument tables and the separation would be nominal.
--
-- Why the publisher may read the M2 tables
--   `cq_repository.py:assessment_owned` explains that the CQ principal holds
--   no privilege on the M2 tables and must not be given one "just to answer an
--   existence question" -- and that is still true: the publisher is not given
--   that grant for an existence check. It is given SELECT because publication
--   *is* the act of binding a release to the owner's confirmed declarations,
--   and `assert_authoritative_binding` must compare the manifest against the
--   persisted M2/BCB records inside the same transaction that writes the
--   release. Four `GRANT SELECT` statements are sufficient because every M2
--   policy is already `TO public` and owner-scoped on `project1_actor()`:
--
--     m2_assessments.owner_scope             owner_user_id = project1_actor()
--     m2_confirmation_snapshots.owner_scope  EXISTS(... a.owner_user_id = ...)
--     m2_business_contexts.owner_scope       EXISTS(... a.owner_user_id = ...)
--     m2_answer_revisions.owner_scope        EXISTS(... a.owner_user_id = ...)
--     m2_item_versions.reference_read        true   (SELECT only, reference data)
--
--   No M2 policy is created or altered here, and the publisher sees only the
--   rows of the actor it is bound to. The grant widens *which role may ask*,
--   not *which rows answer*.
--
-- What is deliberately NOT granted
--   No UPDATE, DELETE or TRUNCATE on any CQ table. No privilege at all on
--   `cq_participants`, `cq_sessions`, `cq_answer_revisions`,
--   `cq_effective_answers`, `cq_submission_receipts`, `cq_consent_events` or
--   any other respondent-scoped relation. No BYPASSRLS, no SUPERUSER, no
--   CREATEROLE, no CREATEDB. A publisher that could read a session would make
--   the respondent boundary decorative.
--
-- Residual, stated rather than hidden
--   `cq_bank_versions` has no owner column: a bank version is content-
--   addressed and shared by any release that names it. Its INSERT policy
--   therefore requires only that an actor is bound, not that the bank belongs
--   to that actor. A publisher could insert an *unreferenced* bank version for
--   another owner's assessment; it would be inert, because no release row can
--   name it without passing `cq_publication_manifest_owned` on
--   `cq_manifest_releases`, and no respondent can reach a bank row that no
--   campaign's release resolves to.
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
  IF to_regclass('public.cq_manifest_releases') IS NULL
     OR to_regclass('public.cq_question_assignments') IS NULL
     OR to_regclass('public.cq_bank_versions') IS NULL
     OR to_regclass('public.cq_campaigns') IS NULL THEN
    RAISE EXCEPTION 'CQ runtime absent: apply 20261115_04 first';
  END IF;
  IF to_regclass('public.m2_assessments') IS NULL THEN
    RAISE EXCEPTION 'M2 tables absent: the publisher cannot bind a release';
  END IF;
  IF EXISTS (SELECT 1 FROM cq_schema_migrations
              WHERE version = '20261125_02'
                AND migration_sha256 <> current_setting('project1.cq_migration_sha256')) THEN
    RAISE EXCEPTION 'Migration hash differs';
  END IF;
  -- The password is supplied by the operator, never stored in this file.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_cq_publisher')
     AND nullif(current_setting('project1.cq_publisher_password', true), '') IS NULL THEN
    RAISE EXCEPTION 'project1.cq_publisher_password is required to create the role';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 1. The principal. Login + NOINHERIT so it cannot pick up a group role's
--    privileges, and NOBYPASSRLS so the policies below are the only thing
--    that decides what it sees.
-- ---------------------------------------------------------------------
DO $$
DECLARE pw text := current_setting('project1.cq_publisher_password', true);
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_cq_publisher') THEN
    EXECUTE format(
      'CREATE ROLE p1_cq_publisher LOGIN NOINHERIT NOSUPERUSER NOCREATEDB '
      'NOCREATEROLE NOBYPASSRLS PASSWORD %L', pw);
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO p1_cq_publisher;

-- ---------------------------------------------------------------------
-- 2. Read the owner's confirmed declarations. RLS scopes every row to
--    project1_actor(); no policy is created or altered.
-- ---------------------------------------------------------------------
GRANT SELECT ON public.m2_assessments,
                public.m2_confirmation_snapshots,
                public.m2_business_contexts,
                public.m2_answer_revisions,
                public.m2_item_versions
  TO p1_cq_publisher;

-- ---------------------------------------------------------------------
-- 3. Write the release. SELECT is needed for the idempotency read
--    (`release_by_manifest_hash`) and the bank-version collision check.
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT ON public.cq_bank_versions,
                        public.cq_manifest_releases,
                        public.cq_question_assignments,
                        public.cq_campaigns
  TO p1_cq_publisher;

-- ---------------------------------------------------------------------
-- 4. Predicates. Each derives the actor from the GUC only; none accepts an
--    actor argument, so a caller cannot assert somebody else's identity.
--    All SECURITY DEFINER with a pinned search_path, because a policy
--    subquery against a table with RLS is itself filtered by the invoking
--    role's policies and would return zero rows (the RLS recursion trap
--    already documented in 20261124_01:31-39).
-- ---------------------------------------------------------------------

-- Does this release manifest name an assessment the actor owns?
-- Text comparison on purpose: a malformed uuid in manifest_json yields
-- false rather than raising 22P02 from inside a WITH CHECK.
CREATE OR REPLACE FUNCTION public.cq_publication_manifest_owned(m jsonb)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.m2_assessments a
     WHERE a.id::text = (m -> 'assignment' ->> 'assessment_id')
       AND a.owner_user_id::text = current_setting('project1.actor_id', true)
  )
$$;

-- Does this release belong to an assessment the actor owns?
CREATE OR REPLACE FUNCTION public.cq_publication_release_owned(r uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.cq_manifest_releases x
      JOIN public.m2_assessments a
        ON a.id::text = (x.manifest_json -> 'assignment' ->> 'assessment_id')
     WHERE x.id = r
       AND a.owner_user_id::text = current_setting('project1.actor_id', true)
  )
$$;

REVOKE ALL ON FUNCTION public.cq_publication_manifest_owned(jsonb),
                       public.cq_publication_release_owned(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cq_publication_manifest_owned(jsonb),
                          public.cq_publication_release_owned(uuid)
  TO p1_cq_publisher;

-- The existing ownership predicates and the campaign trigger function were
-- never granted to PUBLIC, so the publisher needs them named explicitly.
GRANT EXECUTE ON FUNCTION public.cq_assessment_owned_by_actor(uuid),
                          public.cq_campaign_owned_by_actor(uuid),
                          public.m2_workflow_cq_change()
  TO p1_cq_publisher;

-- ---------------------------------------------------------------------
-- 5. Policies. Every one is declared TO p1_cq_publisher, so nothing here
--    can change what p1_ee01_runtime or p1_m2_runtime sees.
-- ---------------------------------------------------------------------
DO $$ BEGIN

  -- A release is visible to the publisher exactly when it was built from an
  -- assessment the actor owns. This is what makes publication idempotent: the
  -- second publish reads the existing row instead of minting a second one.
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                  AND tablename='cq_manifest_releases'
                  AND policyname='cq_publisher_release_read') THEN
    CREATE POLICY cq_publisher_release_read ON public.cq_manifest_releases
      FOR SELECT TO p1_cq_publisher
      USING (public.cq_publication_manifest_owned(manifest_json));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                  AND tablename='cq_manifest_releases'
                  AND policyname='cq_publisher_release_insert') THEN
    CREATE POLICY cq_publisher_release_insert ON public.cq_manifest_releases
      FOR INSERT TO p1_cq_publisher
      WITH CHECK (public.cq_publication_manifest_owned(manifest_json));
  END IF;

  -- The bank row is content-addressed and carries no owner. The minimum
  -- truthful predicate is that an authenticated actor is bound; see the
  -- residual note in the header.
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                  AND tablename='cq_bank_versions'
                  AND policyname='cq_publisher_bank_read') THEN
    CREATE POLICY cq_publisher_bank_read ON public.cq_bank_versions
      FOR SELECT TO p1_cq_publisher
      USING (version::text IN (SELECT (manifest_json ->> 'bank_version')
                                 FROM public.cq_manifest_releases));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                  AND tablename='cq_bank_versions'
                  AND policyname='cq_publisher_bank_insert') THEN
    CREATE POLICY cq_publisher_bank_insert ON public.cq_bank_versions
      FOR INSERT TO p1_cq_publisher
      WITH CHECK (nullif(current_setting('project1.actor_id', true), '') IS NOT NULL);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                  AND tablename='cq_question_assignments'
                  AND policyname='cq_publisher_assignment_read') THEN
    CREATE POLICY cq_publisher_assignment_read ON public.cq_question_assignments
      FOR SELECT TO p1_cq_publisher
      USING (public.cq_publication_release_owned(release_id));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                  AND tablename='cq_question_assignments'
                  AND policyname='cq_publisher_assignment_insert') THEN
    CREATE POLICY cq_publisher_assignment_insert ON public.cq_question_assignments
      FOR INSERT TO p1_cq_publisher
      WITH CHECK (public.cq_publication_release_owned(release_id));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                  AND tablename='cq_campaigns'
                  AND policyname='cq_publisher_campaign_read') THEN
    CREATE POLICY cq_publisher_campaign_read ON public.cq_campaigns
      FOR SELECT TO p1_cq_publisher
      USING (owner_user_id::text = current_setting('project1.actor_id', true));
  END IF;

  -- Three conjuncts, and the third is new: the campaign must point at a
  -- release built from the actor's own assessment. `cq_owner_insert`
  -- (20261124_01:140-144) checks only assessment ownership, so without this
  -- a caller who learned another release id could bind their own assessment
  -- to somebody else's instrument. The publisher path cannot.
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                  AND tablename='cq_campaigns'
                  AND policyname='cq_publisher_campaign_insert') THEN
    CREATE POLICY cq_publisher_campaign_insert ON public.cq_campaigns
      FOR INSERT TO p1_cq_publisher
      WITH CHECK (
        owner_user_id::text = current_setting('project1.actor_id', true)
        AND public.cq_assessment_owned_by_actor(assessment_id)
        AND public.cq_publication_release_owned(release_id)
      );
  END IF;

END $$;

-- ---------------------------------------------------------------------
-- 6. Assertions. The migration may not report success unless the post-state
--    is the intended one, and unless nothing else moved.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text; n int;
BEGIN
  -- 6.1 The principal exists and carries no escalation path.
  SELECT count(*) INTO n FROM pg_roles
   WHERE rolname = 'p1_cq_publisher'
     AND (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb);
  IF n > 0 THEN
    RAISE EXCEPTION 'p1_cq_publisher carries an escalation path';
  END IF;

  -- 6.2 Exactly SELECT+INSERT on the four release tables, and nothing else.
  FOREACH t IN ARRAY ARRAY['cq_bank_versions','cq_manifest_releases',
                           'cq_question_assignments','cq_campaigns'] LOOP
    IF NOT has_table_privilege('p1_cq_publisher', 'public.' || t, 'SELECT')
       OR NOT has_table_privilege('p1_cq_publisher', 'public.' || t, 'INSERT') THEN
      RAISE EXCEPTION 'publisher lacks SELECT or INSERT on %', t;
    END IF;
    IF has_table_privilege('p1_cq_publisher', 'public.' || t, 'UPDATE')
       OR has_table_privilege('p1_cq_publisher', 'public.' || t, 'DELETE')
       OR has_table_privilege('p1_cq_publisher', 'public.' || t, 'TRUNCATE') THEN
      RAISE EXCEPTION 'unexpected write privilege on %', t;
    END IF;
  END LOOP;

  -- 6.3 The publisher can read the owner's declarations and nothing more.
  FOREACH t IN ARRAY ARRAY['m2_assessments','m2_confirmation_snapshots',
                           'm2_business_contexts','m2_answer_revisions',
                           'm2_item_versions'] LOOP
    IF NOT has_table_privilege('p1_cq_publisher', 'public.' || t, 'SELECT') THEN
      RAISE EXCEPTION 'publisher cannot read %', t;
    END IF;
    IF has_table_privilege('p1_cq_publisher', 'public.' || t, 'INSERT')
       OR has_table_privilege('p1_cq_publisher', 'public.' || t, 'UPDATE')
       OR has_table_privilege('p1_cq_publisher', 'public.' || t, 'DELETE') THEN
      RAISE EXCEPTION 'publisher must not write M2 table %', t;
    END IF;
  END LOOP;

  -- 6.4 No privilege at all on respondent-scoped relations.
  FOREACH t IN ARRAY ARRAY['cq_sessions','cq_participants','cq_answer_revisions',
                           'cq_effective_answers','cq_submission_receipts',
                           'cq_consent_events','cq_stimulus_deliveries',
                           'cq_presentations','cq_render_events',
                           'cq_session_controls','cq_lifecycle_events',
                           'cq_routing_decisions','cq_rejected_answer_events',
                           'ee01_measurement_snapshots'] LOOP
    IF to_regclass('public.' || t) IS NULL THEN CONTINUE; END IF;
    IF has_table_privilege('p1_cq_publisher', 'public.' || t, 'SELECT')
       OR has_table_privilege('p1_cq_publisher', 'public.' || t, 'INSERT')
       OR has_table_privilege('p1_cq_publisher', 'public.' || t, 'UPDATE')
       OR has_table_privilege('p1_cq_publisher', 'public.' || t, 'DELETE') THEN
      RAISE EXCEPTION 'publisher must hold nothing on respondent table %', t;
    END IF;
  END LOOP;

  -- 6.5 Every policy this migration created names exactly the new principal.
  SELECT count(*) INTO n FROM pg_policies
   WHERE schemaname='public' AND policyname LIKE 'cq_publisher_%'
     AND roles <> ARRAY['p1_cq_publisher']::name[];
  IF n > 0 THEN
    RAISE EXCEPTION '% publisher policy/policies target another role', n;
  END IF;
  SELECT count(*) INTO n FROM pg_policies
   WHERE schemaname='public' AND policyname LIKE 'cq_publisher_%';
  IF n <> 8 THEN
    RAISE EXCEPTION 'expected 8 publisher policies, found %', n;
  END IF;

  -- 6.6 The respondent principal is exactly as it was: no release-table
  --     INSERT, and its campaign INSERT policy unchanged.
  FOREACH t IN ARRAY ARRAY['cq_bank_versions','cq_manifest_releases',
                           'cq_question_assignments'] LOOP
    IF has_table_privilege('p1_ee01_runtime', 'public.' || t, 'INSERT') THEN
      RAISE EXCEPTION 'respondent principal gained INSERT on %', t;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                  AND tablename='cq_campaigns' AND policyname='cq_owner_insert'
                  AND roles = ARRAY['p1_ee01_runtime']::name[]) THEN
    RAISE EXCEPTION 'cq_owner_insert changed; the respondent path is not this migration''s to alter';
  END IF;

  -- 6.7 The M2 runtime contract is intact.
  FOREACH t IN ARRAY ARRAY['cq_bank_versions','cq_manifest_releases',
                           'cq_question_assignments','cq_campaigns'] LOOP
    IF has_table_privilege('p1_m2_runtime', 'public.' || t, 'INSERT')
       OR has_table_privilege('p1_m2_runtime', 'public.' || t, 'UPDATE')
       OR has_table_privilege('p1_m2_runtime', 'public.' || t, 'DELETE') THEN
      RAISE EXCEPTION 'p1_m2_runtime must remain read-only on %', t;
    END IF;
  END LOOP;

  -- 6.8 Both new predicates are SECURITY DEFINER with a pinned search_path.
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
   WHERE s.nspname='public'
     AND p.proname IN ('cq_publication_manifest_owned','cq_publication_release_owned')
     AND (p.prosecdef IS FALSE OR p.proconfig IS NULL);
  IF n > 0 THEN
    RAISE EXCEPTION '% publisher predicate(s) not SECURITY DEFINER with a pinned search_path', n;
  END IF;

  -- 6.9 The append-only protection still exists on all four tables. Matched by
  --     the function it runs, not by trigger name: `cq_bank_versions` uses
  --     `cq_source_bank_append_only` while the other three use
  --     `cq_append_only`, and asserting a name would have been a false test.
  FOREACH t IN ARRAY ARRAY['cq_bank_versions','cq_manifest_releases',
                           'cq_question_assignments','cq_campaigns'] LOOP
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger g
          JOIN pg_proc p ON p.oid = g.tgfoid
         WHERE g.tgrelid = ('public.' || t)::regclass AND NOT g.tgisinternal
           AND p.proname IN ('cq_immutable_record','cq_source_bank_immutable_record')) THEN
      RAISE EXCEPTION 'append-only trigger missing on %', t;
    END IF;
  END LOOP;
END $$;

INSERT INTO cq_schema_migrations(version, migration_sha256, receipt)
VALUES ('20261125_02', current_setting('project1.cq_migration_sha256'),
        current_setting('project1.cq_migration_receipt'))
ON CONFLICT (version) DO NOTHING;

COMMIT;
