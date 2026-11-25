-- =====================================================================
-- 20261124_01 — CQ respondent write scope (campaign, participant, session)
--
-- Problem
--   The CQ respondent flow cannot perform its first write. `cq_campaigns`,
--   `cq_participants` and `cq_sessions` carry SELECT (and one column UPDATE)
--   for `p1_ee01_runtime` but no INSERT for any principal, and no INSERT
--   policy at all. `CustomerQuestionnaireService.create_campaign`,
--   `.invite` and `.start` therefore fail with
--   `permission denied for table …` before a single answer can be recorded.
--   (DD-CQ-13; campaign creation was missing from the original scope.)
--
-- Principal decision
--   Extend `p1_ee01_runtime`; do NOT create a new role and do NOT touch
--   `p1_m2_runtime`.
--
--   * `p1_m2_runtime` stays read-only on CQ. `m2/20261117_06:67-69` raises
--     at migration time if any write privilege appears there, and that
--     assertion is load-bearing: the M2 runtime renders the workflow summary
--     view and must never be able to alter answer evidence.
--   * A dedicated `p1_cq_runtime` role was evaluated and rejected for now.
--     It would be cleaner separation of duties, but the respondent write
--     path is *already* assigned to `p1_ee01_runtime`: 15 INSERTs and 1
--     column UPDATE on the answer, consent, receipt, routing, presentation
--     and lifecycle tables come from `cq/20261116_02/03/04`. Splitting three
--     tables into a new role would leave the flow straddling two principals
--     and would require re-homing those 15 grants plus ~20 policies — a much
--     larger change with more places to get wrong. Revisit only if a
--     measurement/collection separation is required as policy.
--
-- Why two SECURITY DEFINER predicates
--   The checks below need to read `m2_assessments`, `cq_campaigns` and
--   `cq_participants`, all of which have RLS. A plain subquery inside a
--   policy is itself subject to the invoking role's policies, so it would
--   return zero rows and deny everything — the classic RLS recursion trap.
--   The predicates are owned by the migration runner, pin `search_path`,
--   are revoked from PUBLIC, and are granted only to `p1_ee01_runtime`.
--   Each derives the actor from `project1.actor_id` only; none accepts an
--   actor argument, so a caller cannot assert someone else's identity.
--
-- What each policy enforces
--   cq_campaigns     actor owns the row AND owns the referenced M2 assessment
--   cq_participants  actor owns the campaign being invited to
--   cq_sessions      actor is the respondent AND is a participant of the
--                    campaign AND the session release matches the campaign's
--
--   Absent or empty `project1.actor_id` matches nothing: every predicate
--   compares against `current_setting(..., true)`, which is '' when unset,
--   so all three fail closed rather than defaulting open.
--
-- Not changed here: immutability triggers, foreign keys, the CP12 write
-- barrier, and every existing SELECT/UPDATE grant. No table gains a new
-- DELETE or TRUNCATE privilege. No policy is dropped or widened.
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
  IF to_regclass('public.cq_sessions') IS NULL OR to_regclass('public.cq_campaigns') IS NULL THEN
    RAISE EXCEPTION 'CQ runtime absent: apply 20261115_04 first';
  END IF;
  IF EXISTS (SELECT 1 FROM cq_schema_migrations
              WHERE version = '20261124_01'
                AND migration_sha256 <> current_setting('project1.cq_migration_sha256')) THEN
    RAISE EXCEPTION 'Migration hash differs';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_ee01_runtime') THEN
    RAISE EXCEPTION 'Role p1_ee01_runtime missing';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- Predicates. Actor comes from the GUC only, never from an argument.
-- ---------------------------------------------------------------------

-- Does the requesting actor own this M2 assessment?
CREATE OR REPLACE FUNCTION public.cq_assessment_owned_by_actor(aid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.m2_assessments a
     WHERE a.id = aid
       AND a.owner_user_id::text = current_setting('project1.actor_id', true)
  )
$$;

-- Does the requesting actor own this campaign?
CREATE OR REPLACE FUNCTION public.cq_campaign_owned_by_actor(cid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.cq_campaigns c
     WHERE c.id = cid
       AND c.owner_user_id::text = current_setting('project1.actor_id', true)
  )
$$;

-- If the requesting actor is a participant of this campaign, its release id;
-- otherwise NULL. Comparing `release_id = this` therefore enforces both
-- participation and release binding in one expression, and a NULL result
-- denies rather than passes.
CREATE OR REPLACE FUNCTION public.cq_participant_campaign_release(cid uuid)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT c.release_id
    FROM public.cq_campaigns c
   WHERE c.id = cid
     AND EXISTS (SELECT 1 FROM public.cq_participants x
                  WHERE x.campaign_id = cid
                    AND x.respondent_user_id::text = current_setting('project1.actor_id', true))
$$;

REVOKE ALL ON FUNCTION public.cq_assessment_owned_by_actor(uuid),
                       public.cq_campaign_owned_by_actor(uuid),
                       public.cq_participant_campaign_release(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cq_assessment_owned_by_actor(uuid),
                          public.cq_campaign_owned_by_actor(uuid),
                          public.cq_participant_campaign_release(uuid) TO p1_ee01_runtime;

-- ---------------------------------------------------------------------
-- Grants: three tables, INSERT only. Nothing else widens.
-- ---------------------------------------------------------------------
GRANT INSERT ON public.cq_campaigns, public.cq_participants, public.cq_sessions
  TO p1_ee01_runtime;

-- ---------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname='public' AND tablename='cq_campaigns'
                    AND policyname='cq_owner_insert') THEN
    CREATE POLICY cq_owner_insert ON public.cq_campaigns FOR INSERT TO p1_ee01_runtime
      WITH CHECK (
        owner_user_id::text = current_setting('project1.actor_id', true)
        AND public.cq_assessment_owned_by_actor(assessment_id)
      );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname='public' AND tablename='cq_participants'
                    AND policyname='cq_owner_invite_insert') THEN
    CREATE POLICY cq_owner_invite_insert ON public.cq_participants FOR INSERT TO p1_ee01_runtime
      WITH CHECK (public.cq_campaign_owned_by_actor(campaign_id));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname='public' AND tablename='cq_sessions'
                    AND policyname='cq_respondent_insert') THEN
    CREATE POLICY cq_respondent_insert ON public.cq_sessions FOR INSERT TO p1_ee01_runtime
      WITH CHECK (
        respondent_user_id::text = current_setting('project1.actor_id', true)
        AND release_id = public.cq_participant_campaign_release(campaign_id)
      );
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- Assertions: the new surface is exactly three INSERTs, and the M2 runtime
-- contract is intact.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text; n int;
BEGIN
  FOREACH t IN ARRAY ARRAY['cq_campaigns','cq_participants','cq_sessions'] LOOP
    IF NOT has_table_privilege('p1_ee01_runtime', 'public.' || t, 'INSERT') THEN
      RAISE EXCEPTION 'INSERT grant missing on %', t;
    END IF;
    IF has_table_privilege('p1_ee01_runtime', 'public.' || t, 'DELETE')
       OR has_table_privilege('p1_ee01_runtime', 'public.' || t, 'TRUNCATE') THEN
      RAISE EXCEPTION 'unexpected destructive privilege on %', t;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies
                    WHERE schemaname='public' AND tablename=t AND cmd='INSERT') THEN
      RAISE EXCEPTION 'no INSERT policy on %', t;
    END IF;
  END LOOP;

  -- The M2 runtime stays read-only on every CQ table it can see.
  FOREACH t IN ARRAY ARRAY['cq_campaigns','cq_participants','cq_sessions'] LOOP
    IF has_table_privilege('p1_m2_runtime', 'public.' || t, 'INSERT')
       OR has_table_privilege('p1_m2_runtime', 'public.' || t, 'UPDATE')
       OR has_table_privilege('p1_m2_runtime', 'public.' || t, 'DELETE') THEN
      RAISE EXCEPTION 'p1_m2_runtime must remain read-only on %', t;
    END IF;
  END LOOP;

  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
   WHERE s.nspname='public'
     AND p.proname IN ('cq_assessment_owned_by_actor','cq_campaign_owned_by_actor',
                       'cq_participant_campaign_release')
     AND (p.prosecdef IS FALSE OR p.proconfig IS NULL);
  IF n > 0 THEN
    RAISE EXCEPTION '% predicate(s) not SECURITY DEFINER with a pinned search_path', n;
  END IF;
END $$;

INSERT INTO cq_schema_migrations(version, migration_sha256, receipt)
VALUES ('20261124_01', current_setting('project1.cq_migration_sha256'),
        current_setting('project1.cq_migration_receipt'))
ON CONFLICT (version) DO NOTHING;

COMMIT;
