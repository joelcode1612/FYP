-- 20261122_07 — Research Workspace read scope, compatible with the
-- `project1_actor()` form of `m2_assessments.owner_scope`.
--
-- Why this file exists
-- --------------------
-- `20261117_05_workflow_view_read_scope.sql` ends with a guard that greps the
-- policy text:
--
--     qual LIKE '%project1.actor_id%'
--
-- This database expresses the identical predicate through the helper:
--
--     owner_scope  (owner_user_id = project1_actor())
--
-- so `_05` refuses to run and the four Research Workspace tables it was meant to
-- open remain at RLS default-deny with no SELECT grant. That is the entire
-- content of the 503 `M2_SOURCE_UNAVAILABLE`.
--
-- The guard is textual, not semantic. `public.project1_actor()` is a plain
-- STABLE SQL function:
--
--     SELECT nullif(current_setting('project1.actor_id', true), '')::uuid
--
-- so `owner_user_id = project1_actor()` and
-- `owner_user_id = nullif(current_setting('project1.actor_id',true),'')::uuid`
-- are the same predicate. This was verified by execution before writing this
-- file, not inferred from the body:
--
--   * unset actor  -> helper NULL, literal NULL          (fail-closed, no rows)
--   * seeded owner -> helper 2 rows, literal 2 rows      (identical)
--   * stranger     -> helper 0 rows, literal 0 rows      (identical)
--
-- The schema already contains both spellings: `m2_assessment_links.owner_scope`
-- uses the inline literal form and is FORCE RLS, while `m2_confirmed_uncertainties`
-- and `m2_confirmation_snapshots` use `project1_actor()`. The helper form is the
-- established convention here, not a deviation from it.
--
-- What this migration changes
-- ---------------------------
-- Exactly what `_05` changes, and nothing else:
--
--   1. SELECT grants for the relations the security_invoker workflow views read.
--   2. Owner-scoped FOR SELECT policies on the six default-deny tables.
--
-- It does NOT alter `m2_assessments.owner_scope`, does not drop or replace any
-- existing policy, adds no INSERT/UPDATE/DELETE grant (so writes stay
-- default-deny), and touches no table, view, function or trigger definition.
--
-- Two deliberate differences from `_05`, both narrowing rather than widening:
--
--   * The actor-keyed check is structural (policy references the actor helper,
--     and the helper provably resolves to the actor GUC) instead of a substring
--     match on policy text.
--   * The "no INSERT privilege" assertion exempts `m2_research_objective_sources`,
--     which legitimately holds INSERT under `20261118_06_research_objective_write.sql`
--     (append-only provenance, no UPDATE). Re-running `_05` verbatim after `_06`
--     would fail on its own correct grant.
--
-- FORCE ROW LEVEL SECURITY is not added. It is not required for isolation here:
-- every one of these tables is owned by `postgres`, and the runtime role
-- `p1_m2_runtime` is never the owner, so RLS applies to it without FORCE.
-- `_05` does not force these tables either; this migration preserves that.
--
-- Explicit operator execution only. Never run at startup.

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
  v_qual   text;
  v_helper text;
BEGIN
  -- 1. Explicit target and receipt, as `_05` requires.
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit migration target and receipt required';
  END IF;

  -- 2. The view chain `_05` depends on must already be present.
  IF to_regclass('public.m2_workflow_summary') IS NULL
     OR to_regclass('public.m2_workflow_campaigns') IS NULL
     OR to_regclass('public.m2_confirmed_uncertainties') IS NULL
     OR to_regclass('public.m2_review_question_versions') IS NULL THEN
    RAISE EXCEPTION 'Workflow view chain missing: apply 20261115_02 first';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'p1_m2_runtime') THEN
    RAISE EXCEPTION 'Role p1_m2_runtime missing';
  END IF;

  -- 3. The helper must be the actor-scoped reader it is assumed to be.
  --    A SECURITY DEFINER variant, or one reading a different GUC, would make
  --    the equivalence claim false and the policy unauditable.
  SELECT pg_get_functiondef(p.oid)
    INTO v_helper
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'project1_actor';

  IF v_helper IS NULL THEN
    RAISE EXCEPTION 'public.project1_actor() missing; cannot verify actor scoping';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'project1_actor'
       AND p.prosecdef = false
       AND p.provolatile = 's'
       AND pg_get_functiondef(p.oid) LIKE '%project1.actor_id%'
  ) THEN
    RAISE EXCEPTION
      'project1_actor() is not a plain STABLE reader of project1.actor_id; '
      'refusing to treat it as equivalent to the literal expression';
  END IF;

  -- 4. Prove the equivalence in this session rather than trusting the body.
  --    Runs with whatever the GUC currently is, including unset.
  IF public.project1_actor()
       IS DISTINCT FROM nullif(current_setting('project1.actor_id', true), '')::uuid THEN
    RAISE EXCEPTION
      'project1_actor() does not resolve to the project1.actor_id GUC; '
      'owner scoping would not be actor-keyed';
  END IF;

  -- 5. `m2_assessments.owner_scope` must exist and be actor-keyed in one of the
  --    two accepted spellings.
  SELECT qual INTO v_qual
    FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'm2_assessments'
     AND policyname = 'owner_scope';

  IF v_qual IS NULL THEN
    RAISE EXCEPTION 'm2_assessments.owner_scope is missing';
  END IF;

  IF v_qual NOT LIKE '%project1_actor()%' AND v_qual NOT LIKE '%project1.actor_id%' THEN
    RAISE EXCEPTION
      'm2_assessments.owner_scope is not actor-keyed: %', v_qual;
  END IF;
END $$;

-- 1. Read grants for the relations the security_invoker views touch.
--    SELECT only: these relations stay read-only to the application role.
GRANT SELECT ON public.m2_workflow_campaigns          TO p1_m2_runtime;
GRANT SELECT ON public.m2_research_objective_sources  TO p1_m2_runtime;
GRANT SELECT ON public.m2_research_clarifications     TO p1_m2_runtime;
GRANT SELECT ON public.m2_research_revisions          TO p1_m2_runtime;
GRANT SELECT ON public.m2_desired_options             TO p1_m2_runtime;
GRANT SELECT ON public.m2_candidate_owner_reviews     TO p1_m2_runtime;

-- 2. Owner-scoped read policies for the six default-deny tables.
--    Each predicate is `id IN (SELECT ...)`, which is actor-scoped
--    transitively: RLS applies inside the subquery, so the chain terminates at
--    `m2_assessments.owner_scope`. DROP-then-CREATE keeps this idempotent and
--    prevents a duplicate permissive policy.
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

-- 3. Prove every change took effect in the same transaction, so a silent no-op
--    cannot be mistaken for success.
DO $$
DECLARE
  t text;
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

    -- Writes must stay denied. `m2_research_objective_sources` is the sole
    -- exception: 20261118_06 grants INSERT there as an append-only provenance
    -- write, and grants no UPDATE. Every other table here must hold no write
    -- privilege at all.
    IF t <> 'm2_research_objective_sources' THEN
      IF has_table_privilege('p1_m2_runtime', 'public.' || t, 'INSERT')
         OR has_table_privilege('p1_m2_runtime', 'public.' || t, 'UPDATE')
         OR has_table_privilege('p1_m2_runtime', 'public.' || t, 'DELETE')
         OR has_table_privilege('p1_m2_runtime', 'public.' || t, 'TRUNCATE') THEN
        RAISE EXCEPTION 'unexpected write privilege on %', t;
      END IF;
    END IF;
  END LOOP;

  -- The append-only exception must itself stay append-only.
  IF has_table_privilege('p1_m2_runtime', 'public.m2_research_objective_sources', 'UPDATE')
     OR has_table_privilege('p1_m2_runtime', 'public.m2_research_objective_sources', 'DELETE')
     OR has_table_privilege('p1_m2_runtime', 'public.m2_research_objective_sources', 'TRUNCATE') THEN
    RAISE EXCEPTION 'm2_research_objective_sources must stay append-only';
  END IF;

  -- No new SELECT policy may exist without a matching SELECT grant, and the
  -- read scope must still terminate at the actor-keyed assessment table.
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname = 'public' AND tablename = 'm2_assessments'
                    AND policyname = 'owner_scope'
                    AND (qual LIKE '%project1.actor_id%' OR qual LIKE '%project1_actor()%')) THEN
    RAISE EXCEPTION 'm2_assessments.owner_scope is missing or no longer actor-keyed';
  END IF;
END $$;

COMMIT;
