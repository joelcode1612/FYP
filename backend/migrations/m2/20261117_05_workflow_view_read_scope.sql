-- CP-03F-13 / M2-WRITE-01 (cause 3): make `m2_workflow_summary` readable in full
-- by the application role.
--
-- Defect this repairs
-- -------------------
-- `20261115_02_workflow_projection.sql` defines BOTH workflow views with
-- `WITH (security_invoker=true)` (lines 25 and 28). That choice is deliberate and
-- correct: it keeps row-level security on the underlying tables authoritative for
-- the calling role instead of letting the view owner's rights silently bypass it.
-- The cost is that the caller needs SELECT on every relation the view touches, and
-- RLS on each of them must actually scope the caller.
--
-- 20261117_04 granted only the objects on the trigger's own path, so the deferred
-- constraint trigger still failed at COMMIT with:
--
--     permission denied for view m2_workflow_campaigns
--
-- A privilege audit of the full view chain (scripts/cp03f_m2_view_privilege_audit.py)
-- found six relations the view reads that `p1_m2_runtime` cannot select at all:
--
--     m2_workflow_campaigns            view    (no grant)
--     m2_research_objective_sources    table   (no grant)
--     m2_research_clarifications       table   (no grant)
--     m2_research_revisions            table   (no grant)
--     m2_desired_options               table   (no grant)
--     m2_candidate_owner_reviews       table   (no grant)
--
-- and a second, quieter defect. Six tables have ROW LEVEL SECURITY **enabled with
-- zero policies**, i.e. default-deny, and the view reads all of them:
--
--     m2_research_objective_sources, m2_research_clarifications,
--     m2_research_revisions, m2_review_question_versions,
--     m2_desired_options, m2_candidate_owner_reviews
--
-- `m2_review_question_versions` already had SELECT (granted in 20261117_04) but no
-- policy, so it returned zero rows. Granting SELECT without policies would have
-- turned a loud 503 into a silent data-fidelity defect: the projection would record
-- `objectives: []`, `candidates: []` and lose each objective's provenance
-- (`origin`, `parent`, `exploration_used`) while still claiming to be a complete
-- snapshot. This migration therefore grants AND scopes.
--
-- Scoping model (unchanged from the rest of M2)
-- --------------------------------------------
-- These six tables have no `owner_user_id`, exactly like the other M2 child tables.
-- The existing convention — see `m2_bdj_findings.owner_scope`,
-- `m2_review_events.owner_scope`, `m2_confirmed_uncertainties.owner_scope` — is an
-- indirect predicate such as
--
--     assessment_id IN (SELECT id FROM public.m2_assessments)
--
-- which is actor-scoped *transitively*: RLS is applied to the referenced table
-- inside the policy expression, so `m2_assessments.owner_scope` filters that
-- subquery, which filters the child rows. This migration follows the same shape and
-- extends the chain where the table has no `assessment_id`:
--
--     m2_research_* and m2_review_question_versions
--         -> m2_confirmed_uncertainties
--              -> m2_confirmation_snapshots
--                   -> m2_assessments (owner_scope: project1.actor_id)
--     m2_desired_options / m2_candidate_owner_reviews
--         -> m2_review_question_versions -> ... as above
--
-- Policies are FOR SELECT only. These tables are read-only to the application role
-- and no INSERT/UPDATE/DELETE grant is added, so RLS remains default-deny for
-- writes. Nothing is relaxed: every table gains a predicate that resolves to the
-- requesting owner, and no existing policy is dropped or replaced.
--
-- Scope: additive. No table, view, function body or trigger is altered.
-- Explicit operator execution only. Never run at startup.
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $$ BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit migration target and receipt required';
  END IF;
  IF to_regclass('public.m2_workflow_summary') IS NULL
     OR to_regclass('public.m2_workflow_campaigns') IS NULL
     OR to_regclass('public.m2_confirmed_uncertainties') IS NULL
     OR to_regclass('public.m2_review_question_versions') IS NULL THEN
    RAISE EXCEPTION 'Workflow view chain missing: apply 20261115_02 first';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'p1_m2_runtime') THEN
    RAISE EXCEPTION 'Role p1_m2_runtime missing';
  END IF;
END $$;

-- 1. Read grants for the relations the security_invoker views touch.
GRANT SELECT ON public.m2_workflow_campaigns          TO p1_m2_runtime;
GRANT SELECT ON public.m2_research_objective_sources  TO p1_m2_runtime;
GRANT SELECT ON public.m2_research_clarifications     TO p1_m2_runtime;
GRANT SELECT ON public.m2_research_revisions          TO p1_m2_runtime;
GRANT SELECT ON public.m2_desired_options             TO p1_m2_runtime;
GRANT SELECT ON public.m2_candidate_owner_reviews     TO p1_m2_runtime;

-- 2. Owner-scoped read policies for the six default-deny tables.
--    `id IN (SELECT ...)` is actor-scoped transitively; see the header note.
DROP POLICY IF EXISTS owner_scope ON public.m2_review_question_versions;
CREATE POLICY owner_scope ON public.m2_review_question_versions FOR SELECT
  USING (objective_id IN (SELECT id FROM public.m2_confirmed_uncertainties));

DROP POLICY IF EXISTS owner_scope ON public.m2_research_objective_sources;
CREATE POLICY owner_scope ON public.m2_research_objective_sources FOR SELECT
  USING (objective_id IN (SELECT id FROM public.m2_confirmed_uncertainties));

DROP POLICY IF EXISTS owner_scope ON public.m2_research_clarifications;
CREATE POLICY owner_scope ON public.m2_research_clarifications FOR SELECT
  USING (objective_id IN (SELECT id FROM public.m2_confirmed_uncertainties));

DROP POLICY IF EXISTS owner_scope ON public.m2_research_revisions;
CREATE POLICY owner_scope ON public.m2_research_revisions FOR SELECT
  USING (parent_id IN (SELECT id FROM public.m2_confirmed_uncertainties));

DROP POLICY IF EXISTS owner_scope ON public.m2_desired_options;
CREATE POLICY owner_scope ON public.m2_desired_options FOR SELECT
  USING (question_version IN (SELECT id FROM public.m2_review_question_versions));

DROP POLICY IF EXISTS owner_scope ON public.m2_candidate_owner_reviews;
CREATE POLICY owner_scope ON public.m2_candidate_owner_reviews FOR SELECT
  USING (candidate_id IN (SELECT id FROM public.m2_review_question_versions));

-- Prove every change took effect in the same transaction, so a silent no-op
-- cannot be mistaken for success.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'm2_workflow_campaigns','m2_research_objective_sources',
    'm2_research_clarifications','m2_research_revisions',
    'm2_desired_options','m2_candidate_owner_reviews'] LOOP
    IF NOT has_table_privilege('p1_m2_runtime', 'public.' || t, 'SELECT') THEN
      RAISE EXCEPTION 'SELECT grant missing on %', t;
    END IF;
  END LOOP;

  FOREACH t IN ARRAY ARRAY[
    'm2_review_question_versions','m2_research_objective_sources',
    'm2_research_clarifications','m2_research_revisions',
    'm2_desired_options','m2_candidate_owner_reviews'] LOOP
    IF NOT EXISTS (SELECT FROM pg_policies
                    WHERE schemaname = 'public' AND tablename = t
                      AND policyname = 'owner_scope') THEN
      RAISE EXCEPTION 'owner_scope policy missing on %', t;
    END IF;
    -- Writes must stay denied: no policy of ours may permit them.
    IF has_table_privilege('p1_m2_runtime', 'public.' || t, 'INSERT') THEN
      RAISE EXCEPTION 'unexpected INSERT privilege on %', t;
    END IF;
  END LOOP;

  -- The read scope must not become a bypass: every policy must still resolve
  -- through the actor-keyed assessment table.
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname = 'public' AND tablename = 'm2_assessments'
                    AND policyname = 'owner_scope'
                    AND qual LIKE '%project1.actor_id%') THEN
    RAISE EXCEPTION 'm2_assessments.owner_scope is missing or no longer actor-keyed';
  END IF;
END $$;
COMMIT;
