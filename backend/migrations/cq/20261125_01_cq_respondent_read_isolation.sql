-- B-7 / RLS-F1 + RLS-F2 correction — APPLIED 2026-11-25 16:12 to
-- project1_pg18_migrated_tests (isolated), receipt
-- OWNER-AUTHORIZED-20261125-B7-RESPONDENT-ISOLATION.
-- Recorded in cq_schema_migrations as version 20261125_01. Not applied to Dss.
--
-- sha256 96fe55bd80c3902615df5490f04ff74fbbb4ad570a1923a43d7b2cf9d050165c is
-- the hash of the revision that was applied. THIS HEADER WAS AMENDED AFTER
-- APPLICATION to record that fact; the executable body below is unchanged from
-- the applied revision. A byte-hash of the file therefore no longer equals the
-- recorded value, by design. Do not re-apply to "fix" the hash: the statement
-- is idempotent and would be a no-op, but the recorded receipt would be
-- rewritten to describe a run that did not happen.
--
-- One assertion in this file was corrected during application: it required
-- `cq_append_only` on cq_sessions, which is false and must stay false — a
-- session transitions ACTIVE -> SUBMITTED, so it carries cq_session_guard and
-- refresh_cq_workflow instead. See assertion 5.
--
-- Respondent read isolation. Two ALTER POLICY statements close every
-- cross-respondent read path, because all eleven session-keyed evidence tables
-- compose with cq_sessions and therefore inherit this fix without their own
-- policy changing.
--
-- Why ALTER POLICY and not CREATE POLICY: PostgreSQL combines permissive
-- policies with OR, so a defect of over-breadth cannot be narrowed by adding a
-- policy. The existing policy's predicate has to be replaced. ALTER POLICY
-- replaces the predicate in place and leaves the policy's command and role set
-- untouched, so no privilege is widened and no window exists in which the
-- policy is absent.
--
-- Why these predicates and no new mechanism: cq_campaign_owned_by_actor,
-- cq_session_respondent and cq_synthetic_can_read already exist, are already
-- SECURITY DEFINER with a pinned search_path, and are already asserted to be
-- so by 20261124_01:196-204 and 20261124_02:296-310. Running as definers, they
-- bypass RLS internally, so they do not re-enter the policies they are used in.
--
-- REVIEW ONLY. Apply solely to an authorised isolated database.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$ BEGIN
 IF current_setting('project1.cq_migration_target', true) IS DISTINCT FROM current_database()
 OR nullif(current_setting('project1.cq_migration_receipt', true), '') IS NULL
 OR coalesce(current_setting('project1.cq_migration_sha256', true), '') !~ '^[0-9a-f]{64}$' THEN
  RAISE EXCEPTION 'Explicit target, operator receipt and verified migration hash required';
 END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Pre-state guard. Refuse to alter a policy this migration does not recognise,
-- so a drifted or partially-migrated database stops the run instead of being
-- silently rewritten. Idempotent: a database already carrying the corrected
-- predicate is accepted and skipped.
-- ---------------------------------------------------------------------------
DO $$
DECLARE q_sessions text; q_participants text;
BEGIN
 SELECT qual INTO q_sessions FROM pg_policies
  WHERE schemaname='public' AND tablename='cq_sessions' AND policyname='ee01_owner_read';
 SELECT qual INTO q_participants FROM pg_policies
  WHERE schemaname='public' AND tablename='cq_participants' AND policyname='synthetic_execution_read';

 IF q_sessions IS NULL THEN
  RAISE EXCEPTION 'cq_sessions.ee01_owner_read is missing; B-7 correction cannot be applied';
 END IF;
 IF q_participants IS NULL THEN
  RAISE EXCEPTION 'cq_participants.synthetic_execution_read is missing; B-7 correction cannot be applied';
 END IF;

 IF q_sessions NOT LIKE '%cq_session_respondent%'
    AND q_sessions NOT LIKE '%cq_campaigns%' THEN
  RAISE EXCEPTION 'unexpected cq_sessions.ee01_owner_read shape: %', q_sessions;
 END IF;
 IF q_participants NOT LIKE '%respondent_user_id%'
    AND q_participants NOT LIKE '%cq_campaigns%' THEN
  RAISE EXCEPTION 'unexpected cq_participants.synthetic_execution_read shape: %', q_participants;
 END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1. cq_sessions — the load-bearing fix.
--
--   was: campaign_id IN (SELECT id FROM cq_campaigns)
--        i.e. "any session in any campaign I can see". Because a participant
--        can see the campaign they were invited to (cq_participant_read,
--        20261124_02:187), that resolved to "every session in my campaign",
--        including co-participants'.
--
--   now: three disjuncts, one per authorised principal.
--        entrepreneur -> owns the campaign, so all its sessions
--        respondent   -> the session's own respondent_user_id is the actor,
--                        and the invitation still exists
--        synthetic    -> the campaign is a registered synthetic import, so it
--                        holds no real respondent
-- ---------------------------------------------------------------------------
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM pg_policies
             WHERE schemaname='public' AND tablename='cq_sessions'
               AND policyname='ee01_owner_read' AND qual LIKE '%cq_session_respondent%') THEN
  RAISE NOTICE 'cq_sessions.ee01_owner_read already isolated; skipping';
 ELSE
  ALTER POLICY ee01_owner_read ON public.cq_sessions
    USING (
          public.cq_campaign_owned_by_actor(campaign_id)
       OR public.cq_session_respondent(id)
       OR public.cq_synthetic_can_read('cq_campaigns', campaign_id)
    );
 END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. cq_participants — the enumeration fix (RLS-F2).
--
--   was: campaign_id IN (SELECT id FROM cq_campaigns)
--        i.e. a respondent could list every co-participant of their campaign.
--
--   now: entrepreneur sees the roster of campaigns it owns; a respondent sees
--        its own participant row only; a synthetic run sees synthetic rosters.
--        The policy keeps its original name so the synthetic-policy-count
--        assertion in 20261124_02:289-294 still holds.
-- ---------------------------------------------------------------------------
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM pg_policies
             WHERE schemaname='public' AND tablename='cq_participants'
               AND policyname='synthetic_execution_read' AND qual LIKE '%respondent_user_id%') THEN
  RAISE NOTICE 'cq_participants.synthetic_execution_read already isolated; skipping';
 ELSE
  ALTER POLICY synthetic_execution_read ON public.cq_participants
    USING (
          public.cq_campaign_owned_by_actor(campaign_id)
       OR respondent_user_id::text = current_setting('project1.actor_id', true)
       OR public.cq_synthetic_can_read('cq_campaigns', campaign_id)
    );
 END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Assertions. The migration is not allowed to report success unless the
-- post-state is the intended one.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  n int;
  session_keyed text[] := ARRAY[
    'cq_consent_events','cq_stimulus_deliveries','cq_presentations','cq_answer_revisions',
    'cq_rejected_answer_events','cq_render_events','cq_session_controls','cq_lifecycle_events',
    'cq_routing_decisions','cq_effective_answers','cq_submission_receipts'];
  t text;
BEGIN
  -- 1. Both corrected policies bind a respondent identity term.
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname='public' AND tablename='cq_sessions'
                    AND policyname='ee01_owner_read' AND cmd='SELECT'
                    AND qual LIKE '%cq_session_respondent%') THEN
    RAISE EXCEPTION 'cq_sessions SELECT policy does not bind the respondent';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname='public' AND tablename='cq_participants'
                    AND policyname='synthetic_execution_read' AND cmd='SELECT'
                    AND qual LIKE '%respondent_user_id%') THEN
    RAISE EXCEPTION 'cq_participants SELECT policy does not bind the respondent';
  END IF;

  -- 2. No SELECT policy anywhere in the respondent path is bounded by campaign
  --    alone. This is the invariant _verify_b7_isolation.py checks statically.
  SELECT count(*) INTO n FROM pg_policies
   WHERE schemaname='public' AND cmd='SELECT'
     AND tablename = ANY (session_keyed)
     AND qual LIKE '%cq_campaigns%'
     AND qual NOT LIKE '%cq_session_respondent%'
     AND qual NOT LIKE '%cq_campaign_owned_by_actor%';
  IF n > 0 THEN
    RAISE EXCEPTION '% session-keyed SELECT policy/policies still campaign-wide only', n;
  END IF;

  -- 3. The policies still target exactly the runtime principal.
  SELECT count(*) INTO n FROM pg_policies
   WHERE schemaname='public' AND policyname IN ('ee01_owner_read','synthetic_execution_read')
     AND tablename IN ('cq_sessions','cq_participants')
     AND roles <> ARRAY['p1_ee01_runtime']::name[];
  IF n > 0 THEN
    RAISE EXCEPTION 'corrected policy/policies changed role set on % relation(s)', n;
  END IF;

  -- 4. No privilege was widened by this migration.
  IF has_table_privilege('p1_ee01_runtime','public.cq_sessions','DELETE')
     OR has_table_privilege('p1_ee01_runtime','public.cq_participants','DELETE')
     OR has_table_privilege('p1_ee01_runtime','public.cq_sessions','TRUNCATE')
     OR has_table_privilege('p1_ee01_runtime','public.cq_participants','TRUNCATE') THEN
    RAISE EXCEPTION 'B-7 correction must not widen privileges';
  END IF;

  -- 5. Write-integrity protection survives on every touched relation.
  --
  --    The two relations are protected differently on purpose, and an earlier
  --    version of this assertion asserted `cq_append_only` on both. That is
  --    false for cq_sessions: a session legitimately transitions ACTIVE ->
  --    SUBMITTED, so it carries `cq_session_guard` (a state-transition guard)
  --    and `refresh_cq_workflow`, not an immutability trigger. Asserting
  --    append-only there would have required adding a trigger that breaks
  --    submission. Assert what is true instead:
  --      * cq_participants stays append-only (an invitation is never rewritten)
  --      * cq_sessions keeps its transition guard and must NOT become
  --        append-only, which would make submission impossible
  --      * both keep the CP12 write barrier
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = 'public.cq_participants'::regclass
                    AND tgname = 'cq_append_only') THEN
    RAISE EXCEPTION 'append-only trigger missing on cq_participants';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = 'public.cq_sessions'::regclass
                    AND tgname = 'cq_session_guard') THEN
    RAISE EXCEPTION 'state-transition guard missing on cq_sessions';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger
              WHERE tgrelid = 'public.cq_sessions'::regclass
                AND tgname = 'cq_append_only') THEN
    RAISE EXCEPTION 'cq_sessions must stay mutable; append-only would block submission';
  END IF;
  FOREACH t IN ARRAY ARRAY['cq_sessions','cq_participants'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgrelid = ('public.' || t)::regclass AND tgname = 'cp12_barrier') THEN
      RAISE EXCEPTION 'CP12 write barrier missing on %', t;
    END IF;
  END LOOP;
END $$;

INSERT INTO cq_schema_migrations(version, migration_sha256, receipt)
VALUES ('20261125_01', current_setting('project1.cq_migration_sha256'),
        current_setting('project1.cq_migration_receipt'))
ON CONFLICT (version) DO NOTHING;

COMMIT;
