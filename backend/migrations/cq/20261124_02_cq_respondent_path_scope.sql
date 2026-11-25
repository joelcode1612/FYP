-- =====================================================================
-- 20261124_02 — CQ respondent path scope (read visibility and evidence)
--
-- Problem
--   20261124_01 made campaign creation, invitation and session opening
--   possible. They are not sufficient. Every *read* policy on the CQ schema
--   is a transitive chain anchored on `cq_campaigns.owner_user_id`, and every
--   *write* policy on the evidence tables is scoped to the synthetic preview
--   grant. A respondent is never the campaign owner, so the real respondent
--   path is invisible to itself and cannot record a single answer.
--
--   Measured on a clean install before this migration, as
--   `SET LOCAL ROLE p1_ee01_runtime` with `project1.actor_id` set to a
--   respondent who *is* a participant of an existing campaign:
--
--       cq_campaigns        visible = 0
--       cq_sessions         visible = 0
--       cq_participants     visible = 0
--       UPDATE cq_sessions  affected = 0   (policy filters the row away)
--       INSERT cq_consent_events  ERROR 42501 new row violates RLS policy
--
--   The zero-row UPDATE is the dangerous one: `CqUnit.update_session` raises
--   `CQ_STALE_REVISION` on `rowcount != 1`, so a pure authorization failure
--   is reported to the respondent as a concurrency conflict. That is a
--   misleading diagnostic, not a safe one.
--
--   Consequences by table (non-synthetic policy count before this migration):
--
--       SELECT  cq_campaigns, cq_sessions, cq_participants   owner-anchored
--       SELECT  cq_manifest_releases, cq_question_assignments owner-anchored
--       SELECT  cq_bank_versions   chained through releases  owner-anchored
--       INSERT  cq_consent_events, cq_stimulus_deliveries,
--               cq_routing_decisions, cq_effective_answers,
--               cq_presentations, cq_answer_revisions,
--               cq_submission_receipts, cq_lifecycle_events,
--               cq_render_events, cq_rejected_answer_events,
--               cq_session_controls                        synthetic only
--       UPDATE  cq_sessions, cq_effective_answers            synthetic only
--
--   DD-CQ-16 (respondent read visibility), DD-CQ-17 (session and
--   effective-answer UPDATE), DD-CQ-18 (evidence INSERT) and DD-CQ-19
--   (`p1_ee01_runtime` holds no privilege on `m2_assessments`) are the
--   recorded defects. DD-CQ-13 in the handoff understated the gap: it named
--   two tables where the true surface is fourteen.
--
-- Design
--   Additive only. No policy is dropped, replaced or widened, and no
--   synthetic policy is touched, so the synthetic preview path keeps exactly
--   the access it has today and the two paths are distinguished by their
--   authorization basis rather than by precedence.
--
--   Two SECURITY DEFINER predicates carry the whole change:
--
--     cq_actor_is_participant(cid)   actor has a cq_participants row on cid
--     cq_session_respondent(sid)     actor is the session's respondent AND is
--                                    a participant of that session's campaign
--
--   A plain subquery inside a policy is evaluated under the invoking role's
--   own policies, so `EXISTS (SELECT 1 FROM cq_participants ...)` would
--   return zero rows and deny everything. The predicates are owned by the
--   migration runner, pin `search_path`, are revoked from PUBLIC, are
--   granted only to `p1_ee01_runtime`, and derive the actor exclusively from
--   `current_setting('project1.actor_id', true)` — neither accepts an actor
--   argument, so no caller can assert another identity. An unset GUC is ''
--   and matches nothing, so both fail closed.
--
--   Only two of the read chains need a new policy. `cq_manifest_releases`
--   (`id IN (SELECT release_id FROM cq_campaigns)`), `cq_question_assignments`
--   (`release_id IN (SELECT release_id FROM cq_campaigns)`), `cq_bank_versions`
--   (`version IN (SELECT manifest_json->>'bank_version' FROM cq_manifest_releases)`),
--   `cq_sessions` and `cq_participants` (`campaign_id IN (SELECT id FROM
--   cq_campaigns)`) all re-evaluate the inner query against the *new*
--   campaign policy. Widening `cq_campaigns` SELECT for participants is
--   therefore sufficient for the whole read surface, and it is the only
--   read change made here. Likewise the evidence SELECT policies already
--   read `session_id IN (SELECT id FROM cq_sessions)` and need no change
--   once the session itself is visible.
--
--   Naming debt is recorded, not fixed: `cq_effective_answers` and
--   `cq_submission_receipts` reach their SELECT through a policy named
--   `synthetic_owner_inspection`, and `cq_routing_decisions` through
--   `synthetic_execution_read`. Those predicates carry no synthetic grant
--   test — they are plain session-visibility chains — so they are correct,
--   merely misnamed. Renaming them is a separate, non-behavioural change.
--
-- Grants
--   `p1_ee01_runtime` already holds INSERT on ten of the eleven evidence
--   tables; only `cq_session_controls` is missing, and only `cq_sessions`
--   lacks UPDATE. Both are added at the narrowest width available: table
--   INSERT for the append-only control row, and *column* UPDATE on
--   (revision, state, consented, consent_version) for the session, which is
--   exactly the set `CqUnit.update_session` writes. No DELETE and no
--   TRUNCATE is granted anywhere, and `p1_m2_runtime` gains nothing.
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
  -- This migration is a continuation of 20261124_01, not a replacement: the
  -- campaign/participant/session INSERT policies it relies on must exist.
  IF NOT EXISTS (SELECT 1 FROM cq_schema_migrations WHERE version = '20261124_01') THEN
    RAISE EXCEPTION 'Apply 20261124_01 first';
  END IF;
  IF EXISTS (SELECT 1 FROM cq_schema_migrations
              WHERE version = '20261124_02'
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

-- Is the requesting actor an invited participant of this campaign?
CREATE OR REPLACE FUNCTION public.cq_actor_is_participant(cid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.cq_participants p
     WHERE p.campaign_id = cid
       AND p.respondent_user_id::text = current_setting('project1.actor_id', true)
  )
$$;

-- Is the requesting actor the respondent of this session, and still a
-- participant of the campaign that session belongs to? Both halves are
-- required: the participant row is what authorized the session, and a
-- session must stop being writable if the invitation it rests on is gone.
CREATE OR REPLACE FUNCTION public.cq_session_respondent(sid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.cq_sessions s
      JOIN public.cq_participants p
        ON p.campaign_id = s.campaign_id
       AND p.respondent_user_id = s.respondent_user_id
     WHERE s.id = sid
       AND s.respondent_user_id::text = current_setting('project1.actor_id', true)
  )
$$;

REVOKE ALL ON FUNCTION public.cq_actor_is_participant(uuid),
                       public.cq_session_respondent(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cq_actor_is_participant(uuid),
                          public.cq_session_respondent(uuid) TO p1_ee01_runtime;

-- ---------------------------------------------------------------------
-- Grants: one table INSERT and one column-scoped UPDATE.
-- ---------------------------------------------------------------------
GRANT INSERT ON public.cq_session_controls TO p1_ee01_runtime;
GRANT UPDATE (revision, state, consented, consent_version)
  ON public.cq_sessions TO p1_ee01_runtime;

-- ---------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------
DO $$
DECLARE
  -- Tables the respondent writes as their own evidence, keyed by session_id.
  evidence text[] := ARRAY[
    'cq_consent_events', 'cq_stimulus_deliveries', 'cq_routing_decisions',
    'cq_effective_answers', 'cq_presentations', 'cq_answer_revisions',
    'cq_submission_receipts', 'cq_lifecycle_events', 'cq_render_events',
    'cq_rejected_answer_events', 'cq_session_controls'];
  t text;
BEGIN
  -- 1. The single read widening: a participant sees the campaign they were
  --    invited to. Every other read chain re-evaluates against this policy.
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname='public' AND tablename='cq_campaigns'
                    AND policyname='cq_participant_read') THEN
    CREATE POLICY cq_participant_read ON public.cq_campaigns
      FOR SELECT TO p1_ee01_runtime
      USING (public.cq_actor_is_participant(id));
  END IF;

  -- 2. The respondent advances their own session revision.
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname='public' AND tablename='cq_sessions'
                    AND policyname='cq_respondent_update') THEN
    CREATE POLICY cq_respondent_update ON public.cq_sessions
      FOR UPDATE TO p1_ee01_runtime
      USING (public.cq_session_respondent(id))
      WITH CHECK (public.cq_session_respondent(id));
  END IF;

  -- 3. Withdrawal rewrites the effective answer of the actor's own session.
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname='public' AND tablename='cq_effective_answers'
                    AND policyname='cq_respondent_update') THEN
    CREATE POLICY cq_respondent_update ON public.cq_effective_answers
      FOR UPDATE TO p1_ee01_runtime
      USING (public.cq_session_respondent(session_id))
      WITH CHECK (public.cq_session_respondent(session_id));
  END IF;

  -- 4. Evidence append, one policy per table, identical predicate.
  FOREACH t IN ARRAY evidence LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_policies
                    WHERE schemaname='public' AND tablename=t
                      AND policyname='cq_respondent_insert') THEN
      EXECUTE format(
        'CREATE POLICY cq_respondent_insert ON public.%I FOR INSERT TO p1_ee01_runtime '
        'WITH CHECK (public.cq_session_respondent(session_id))', t);
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- Assertions
-- ---------------------------------------------------------------------
DO $$
DECLARE
  evidence text[] := ARRAY[
    'cq_consent_events', 'cq_stimulus_deliveries', 'cq_routing_decisions',
    'cq_effective_answers', 'cq_presentations', 'cq_answer_revisions',
    'cq_submission_receipts', 'cq_lifecycle_events', 'cq_render_events',
    'cq_rejected_answer_events', 'cq_session_controls'];
  synthetic text[] := ARRAY[
    'synthetic_execution_insert', 'synthetic_execution_read',
    'synthetic_execution_update', 'synthetic_owner_inspection',
    'synthetic_campaign_grant', 'synthetic_owner', 'synthetic_granted_run',
    'synthetic_developer_self'];
  t text; n int;
BEGIN
  -- Every evidence table has a non-synthetic INSERT policy bound to the
  -- respondent predicate.
  FOREACH t IN ARRAY evidence LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_policies
                    WHERE schemaname='public' AND tablename=t
                      AND policyname='cq_respondent_insert' AND cmd='INSERT'
                      AND with_check LIKE '%cq_session_respondent%') THEN
      RAISE EXCEPTION 'respondent INSERT policy missing or unbound on %', t;
    END IF;
    IF NOT has_table_privilege('p1_ee01_runtime', 'public.' || t, 'INSERT') THEN
      RAISE EXCEPTION 'INSERT grant missing on %', t;
    END IF;
  END LOOP;

  -- The UPDATE surface is exactly two tables and stays column-scoped.
  IF NOT has_column_privilege('p1_ee01_runtime', 'public.cq_sessions', 'revision', 'UPDATE')
     OR NOT has_column_privilege('p1_ee01_runtime', 'public.cq_sessions', 'state', 'UPDATE') THEN
    RAISE EXCEPTION 'cq_sessions column UPDATE grant missing';
  END IF;
  IF has_column_privilege('p1_ee01_runtime', 'public.cq_sessions', 'respondent_user_id', 'UPDATE')
     OR has_column_privilege('p1_ee01_runtime', 'public.cq_sessions', 'campaign_id', 'UPDATE')
     OR has_column_privilege('p1_ee01_runtime', 'public.cq_sessions', 'release_id', 'UPDATE') THEN
    RAISE EXCEPTION 'cq_sessions identity columns must not be updatable';
  END IF;

  -- No destructive privilege appears anywhere on the CQ schema.
  SELECT count(*) INTO n
    FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
   WHERE s.nspname='public' AND c.relkind='r' AND c.relname LIKE 'cq\_%'
     AND (has_table_privilege('p1_ee01_runtime', c.oid, 'DELETE')
       OR has_table_privilege('p1_ee01_runtime', c.oid, 'TRUNCATE'));
  IF n > 0 THEN
    RAISE EXCEPTION 'p1_ee01_runtime must hold no DELETE/TRUNCATE on % CQ table(s)', n;
  END IF;

  -- The M2 runtime contract is untouched: read-only on every CQ table.
  SELECT count(*) INTO n
    FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
   WHERE s.nspname='public' AND c.relkind='r' AND c.relname LIKE 'cq\_%'
     AND (has_table_privilege('p1_m2_runtime', c.oid, 'INSERT')
       OR has_table_privilege('p1_m2_runtime', c.oid, 'UPDATE')
       OR has_table_privilege('p1_m2_runtime', c.oid, 'DELETE')
       OR has_table_privilege('p1_m2_runtime', c.oid, 'TRUNCATE'));
  IF n > 0 THEN
    RAISE EXCEPTION 'p1_m2_runtime must remain read-only on % CQ table(s)', n;
  END IF;

  -- Nothing was dropped: every pre-existing synthetic policy survives.
  SELECT count(*) INTO n FROM pg_policies
   WHERE schemaname='public' AND tablename LIKE 'cq\_%'
     AND policyname = ANY (synthetic);
  IF n < 20 THEN
    RAISE EXCEPTION 'synthetic policy set shrank: % present, at least 20 expected', n;
  END IF;

  -- Both predicates are SECURITY DEFINER with a pinned search_path and are
  -- not executable by PUBLIC.
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
   WHERE s.nspname='public'
     AND p.proname IN ('cq_actor_is_participant','cq_session_respondent')
     AND (p.prosecdef IS FALSE OR p.proconfig IS NULL);
  IF n > 0 THEN
    RAISE EXCEPTION '% predicate(s) not SECURITY DEFINER with a pinned search_path', n;
  END IF;
  IF has_function_privilege('public',
       'public.cq_actor_is_participant(uuid)', 'EXECUTE')
     OR has_function_privilege('public',
          'public.cq_session_respondent(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'predicates must not be executable by PUBLIC';
  END IF;
END $$;

INSERT INTO cq_schema_migrations(version, migration_sha256, receipt)
VALUES ('20261124_02', current_setting('project1.cq_migration_sha256'),
        current_setting('project1.cq_migration_receipt'))
ON CONFLICT (version) DO NOTHING;

COMMIT;
