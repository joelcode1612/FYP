-- =====================================================================
-- 20261125_05 — collection closure record and the closed-campaign predicate
--
-- Why this exists (Task 4 of the 2026-11-25 assignment)
--   ``20261125_04`` gave a campaign an OPEN/ENDED state but recorded only the
--   instant and the actor. The assignment requires the closure record to carry
--   the **decision**, the **evidence cutoff** and enough of the situation at
--   closure to prove later what was decided. Those cannot be reconstructed
--   afterwards: the counts keep moving while collection is open, and the target
--   is a mutable planning figure until closure freezes it.
--
-- Why the cutoff is a separate column and not ``ended_at``
--   They are usually equal, but they are different facts. ``ended_at`` is when
--   the owner closed collection; ``evidence_cutoff`` is the last instant that
--   counts as evidence. An owner who closes after noticing that the last
--   response arrived earlier may legitimately set an earlier cutoff. Recording
--   only ``ended_at`` would silently equate the two and make the distinction
--   unrecoverable.
--
-- Why ``cq_collection_closed()`` is SECURITY DEFINER
--   The respondent who starts a session must be refused when collection has
--   ended, but a respondent is not the campaign owner, so the owner-scoped RLS
--   policy on ``cq_collection_state`` shows them **no row at all**. A plain
--   SELECT would therefore read "not closed" and admit the respondent into a
--   closed campaign. The function returns a boolean and nothing else: it never
--   exposes the target, and it does not widen the policy surface.
--
-- Additive only: five nullable columns, one constraint, one function. No column
-- is dropped, no existing constraint is replaced, no grant is removed.
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
  IF to_regclass('public.cq_collection_state') IS NULL THEN
    RAISE EXCEPTION 'cq_collection_state missing: apply 20261125_04 first';
  END IF;
  IF to_regprocedure('public.cq_collection_closed(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'cq_collection_closed(uuid) already exists';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'cq_collection_state'
                AND column_name = 'evidence_cutoff') THEN
    RAISE EXCEPTION 'evidence_cutoff already exists';
  END IF;
  IF EXISTS (SELECT 1 FROM cq_schema_migrations
              WHERE version = '20261125_05'
                AND migration_sha256 <> current_setting('project1.cq_migration_sha256')) THEN
    RAISE EXCEPTION 'Migration hash differs';
  END IF;
  -- The new shape constraint is added and validated in this transaction, so it
  -- must already hold for every existing row. Only OPEN rows exist today; assert
  -- it rather than assume it.
  IF EXISTS (SELECT 1 FROM public.cq_collection_state
              WHERE lifecycle_state <> 'OPEN') THEN
    RAISE EXCEPTION 'existing non-OPEN rows need a backfill decision first';
  END IF;
END $$;

ALTER TABLE public.cq_collection_state
    -- The last instant that counts as evidence. See the header.
    ADD COLUMN evidence_cutoff          timestamptz,
    -- Which completion policy the owner closed under. Nullable only while OPEN.
    ADD COLUMN completion_policy        varchar(32),
    -- How sessions that were still ACTIVE at closure are treated. A one-value
    -- vocabulary today, on purpose: it records what was actually decided, so a
    -- future disposition needs a migration rather than a silent behaviour change.
    ADD COLUMN in_progress_disposition  varchar(32),
    -- The situation at closure, frozen so it can be inspected later. The target
    -- is nullable because a campaign may be closed without one ever being set.
    ADD COLUMN target_at_closure        integer,
    ADD COLUMN reached_at_closure       integer;

COMMENT ON COLUMN public.cq_collection_state.evidence_cutoff IS
  'Last instant that counts as evidence for this collection. Usually ended_at, '
  'but recorded separately so an earlier cutoff can be stated explicitly.';
COMMENT ON COLUMN public.cq_collection_state.completion_policy IS
  'The completion policy the owner closed under: TARGET_REACHED_ONLY or OWNER_DISCRETION.';
COMMENT ON COLUMN public.cq_collection_state.in_progress_disposition IS
  'How ACTIVE sessions were treated at closure. LEAVE_OPEN is the only '
  'supported value: cq_sessions_check1 forbids withdrawing a consented session, '
  'so terminating in-progress respondents is not expressible without a schema '
  'change to cq_sessions.state.';
COMMENT ON COLUMN public.cq_collection_state.target_at_closure IS
  'The respondent target as it stood when collection closed. Null means no target was ever set.';
COMMENT ON COLUMN public.cq_collection_state.reached_at_closure IS
  'Eligible submitted respondents counted at closure, under the same definition '
  'the progress endpoint reports.';

ALTER TABLE public.cq_collection_state
    ADD CONSTRAINT cq_collection_state_policy_check CHECK (
        completion_policy IS NULL
        OR completion_policy IN ('TARGET_REACHED_ONLY', 'OWNER_DISCRETION')),
    ADD CONSTRAINT cq_collection_state_disposition_check CHECK (
        in_progress_disposition IS NULL
        OR in_progress_disposition IN ('LEAVE_OPEN')),
    ADD CONSTRAINT cq_collection_state_closure_record CHECK (
        (lifecycle_state = 'OPEN'
         AND evidence_cutoff IS NULL AND completion_policy IS NULL
         AND in_progress_disposition IS NULL AND target_at_closure IS NULL
         AND reached_at_closure IS NULL)
     OR (lifecycle_state = 'ENDED'
         AND evidence_cutoff IS NOT NULL AND completion_policy IS NOT NULL
         AND in_progress_disposition IS NOT NULL AND reached_at_closure IS NOT NULL));

-- The predicate a respondent's session start consults. Returns a boolean and
-- nothing else, so it cannot be used to read the owner's target, and it does not
-- depend on the caller being able to see the row through RLS.
CREATE FUNCTION public.cq_collection_closed(p_campaign_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.cq_collection_state
         WHERE campaign_id = p_campaign_id
           AND lifecycle_state = 'ENDED')
$$;

REVOKE ALL ON FUNCTION public.cq_collection_closed(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cq_collection_closed(uuid) TO p1_ee01_runtime;

DO $$
BEGIN
  -- Post-state: the columns the service writes must all be present and nullable.
  IF (SELECT count(*) FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'cq_collection_state'
         AND column_name IN ('evidence_cutoff', 'completion_policy',
                             'in_progress_disposition', 'target_at_closure',
                             'reached_at_closure')) <> 5 THEN
    RAISE EXCEPTION 'closure columns missing';
  END IF;
  IF (SELECT count(*) FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'cq_collection_state'
         AND column_name IN ('evidence_cutoff', 'completion_policy',
                             'in_progress_disposition', 'target_at_closure',
                             'reached_at_closure')
         AND is_nullable = 'NO') <> 0 THEN
    RAISE EXCEPTION 'closure columns must stay nullable: OPEN rows carry none';
  END IF;
  -- The predicate must be callable by the runtime and by nobody else.
  IF NOT has_function_privilege('p1_ee01_runtime',
                                'public.cq_collection_closed(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'runtime cannot execute cq_collection_closed';
  END IF;
  IF has_function_privilege('p1_cq_publisher',
                            'public.cq_collection_closed(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'publisher must not execute the closure predicate';
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc
           WHERE oid = 'public.cq_collection_closed(uuid)'::regprocedure) THEN
    RAISE EXCEPTION 'cq_collection_closed must be SECURITY DEFINER';
  END IF;
  IF (SELECT proconfig FROM pg_proc
       WHERE oid = 'public.cq_collection_closed(uuid)'::regprocedure)
     IS DISTINCT FROM ARRAY['search_path=pg_catalog, public'] THEN
    RAISE EXCEPTION 'cq_collection_closed must pin its search_path';
  END IF;
  -- Ending collection still must not be able to delete anything.
  IF has_table_privilege('p1_ee01_runtime',
                         'public.cq_collection_state', 'DELETE') THEN
    RAISE EXCEPTION 'DELETE appeared on cq_collection_state';
  END IF;
  -- And the campaign row must still be insert-once.
  IF has_table_privilege('p1_ee01_runtime', 'public.cq_campaigns', 'UPDATE')
     OR has_table_privilege('p1_cq_publisher', 'public.cq_campaigns', 'UPDATE') THEN
    RAISE EXCEPTION 'cq_campaigns gained UPDATE';
  END IF;
END $$;

INSERT INTO cq_schema_migrations(version, migration_sha256, receipt)
VALUES ('20261125_05', current_setting('project1.cq_migration_sha256'),
        current_setting('project1.cq_migration_receipt'))
ON CONFLICT (version) DO NOTHING;

COMMIT;
