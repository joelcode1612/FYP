-- =====================================================================
-- 20261125_04 — authoritative collection state (respondent target + lifecycle)
--
-- Why a new table and not a column on cq_campaigns
--   ``cq_campaigns`` is deliberately insert-once: it holds the release binding
--   and ``PublicationService._bind_campaign`` refuses to rebind a campaign to a
--   different release because that would re-point a questionnaire that may
--   already have respondents (DD-095, supersession is a migration decision).
--   The table therefore carries no UPDATE privilege and no UPDATE policy for
--   either runtime principal. Adding a target column to it would mean granting
--   UPDATE on a row that is otherwise immutable, and a table-level UPDATE grant
--   cannot be restricted to one column by the policy layer — RLS decides *which
--   rows*, not *which columns*. The release binding would become writable.
--   A separate table leaves the campaign row exactly as immutable as it is.
--
-- Why the target is nullable
--   "No target set yet" is a real state that the report gate has to distinguish
--   from "target set and not reached". A NOT NULL default would collapse the
--   two and manufacture a target the entrepreneur never chose.
--
-- Why the row is created lazily
--   Publication is a verified path (DD-116, B-7) and is not modified here.
--   A missing row therefore means "published, collection open, no target set",
--   which is exactly the state a freshly published campaign is in. Readers must
--   treat absence as OPEN; the service does.
--
-- Why lifecycle lives here too (DD-097)
--   ``cq_lifecycle_events`` cannot carry it: its ``action`` check admits only
--   PAUSE and RESUME, its keys are ``UNIQUE(session_id, request_id)`` and
--   ``UNIQUE(session_id, revision)``, and ``session_id`` is NOT NULL with an FK
--   to ``cq_sessions``. It is a per-session timeline. DD-097 described a
--   campaign-level gap and this table is that gap.
--
-- Idempotency
--   ``last_request_id`` records the request that produced the current state, so
--   a repeated End Collection returns the stored state instead of transitioning
--   twice. ``state_revision`` gives optimistic concurrency for the same reason.
--
-- No DELETE is granted to any runtime principal: ending collection must not
-- remove anything, and no path in this migration can.
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
  IF to_regclass('public.cq_campaigns') IS NULL THEN
    RAISE EXCEPTION 'cq_campaigns missing: apply the publication migrations first';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_ee01_runtime') THEN
    RAISE EXCEPTION 'p1_ee01_runtime missing';
  END IF;
  IF to_regclass('public.cq_collection_state') IS NOT NULL THEN
    RAISE EXCEPTION 'cq_collection_state already exists';
  END IF;
  IF EXISTS (SELECT 1 FROM cq_schema_migrations
              WHERE version = '20261125_04'
                AND migration_sha256 <> current_setting('project1.cq_migration_sha256')) THEN
    RAISE EXCEPTION 'Migration hash differs';
  END IF;
END $$;

CREATE TABLE public.cq_collection_state (
    campaign_id       uuid        PRIMARY KEY
                                  REFERENCES public.cq_campaigns(id) ON DELETE RESTRICT,
    -- Nullable on purpose: null means "the entrepreneur has not set a target",
    -- which is a different fact from "target set and not yet reached".
    respondent_target integer     CHECK (respondent_target IS NULL
                                         OR respondent_target BETWEEN 1 AND 9999),
    lifecycle_state   varchar(16) NOT NULL DEFAULT 'OPEN'
                                  CHECK (lifecycle_state IN ('OPEN', 'ENDED')),
    ended_at          timestamptz,
    -- A free-text label supplied by whoever ended collection. Deliberately not
    -- an enum: which reasons are legitimate is a policy decision (DD-097), and
    -- encoding an invented vocabulary here would pre-empt it.
    end_reason        varchar(200),
    ended_by_user_id  uuid,
    state_revision    integer     NOT NULL DEFAULT 1 CHECK (state_revision >= 1),
    last_request_id   uuid,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT cq_collection_state_end_shape CHECK (
        (lifecycle_state = 'OPEN'
         AND ended_at IS NULL AND end_reason IS NULL AND ended_by_user_id IS NULL)
     OR (lifecycle_state = 'ENDED' AND ended_at IS NOT NULL)
    )
);

COMMENT ON TABLE public.cq_collection_state IS
  'One row per campaign: the entrepreneur''s respondent target and the '
  'collection lifecycle. Absence of a row means published, OPEN, no target set.';
COMMENT ON COLUMN public.cq_collection_state.respondent_target IS
  'Planning figure the entrepreneur chose. Never a count of responses received.';
COMMENT ON COLUMN public.cq_collection_state.end_reason IS
  'Operator/owner-supplied label; not a governed vocabulary (DD-097 policy open).';

ALTER TABLE public.cq_collection_state ENABLE ROW LEVEL SECURITY;

-- The campaign row is the authority for ownership. Reading it inside the
-- policy is safe: cq_campaigns has its own owner-scoped SELECT policy, so the
-- EXISTS can only match a campaign the actor may already see.
CREATE POLICY cq_collection_state_owner_read ON public.cq_collection_state
    FOR SELECT TO p1_ee01_runtime
    USING (EXISTS (SELECT 1 FROM public.cq_campaigns c
                    WHERE c.id = campaign_id
                      AND c.owner_user_id::text
                          = current_setting('project1.actor_id', true)));

CREATE POLICY cq_collection_state_owner_insert ON public.cq_collection_state
    FOR INSERT TO p1_ee01_runtime
    WITH CHECK (EXISTS (SELECT 1 FROM public.cq_campaigns c
                         WHERE c.id = campaign_id
                           AND c.owner_user_id::text
                               = current_setting('project1.actor_id', true)));

CREATE POLICY cq_collection_state_owner_update ON public.cq_collection_state
    FOR UPDATE TO p1_ee01_runtime
    USING (EXISTS (SELECT 1 FROM public.cq_campaigns c
                    WHERE c.id = campaign_id
                      AND c.owner_user_id::text
                          = current_setting('project1.actor_id', true)))
    WITH CHECK (EXISTS (SELECT 1 FROM public.cq_campaigns c
                         WHERE c.id = campaign_id
                           AND c.owner_user_id::text
                               = current_setting('project1.actor_id', true)));

-- The publisher may read the state it must report on, but never write it:
-- publishing starts a collection, it does not configure one.
CREATE POLICY cq_collection_state_publisher_read ON public.cq_collection_state
    FOR SELECT TO p1_cq_publisher
    USING (EXISTS (SELECT 1 FROM public.cq_campaigns c
                    WHERE c.id = campaign_id
                      AND c.owner_user_id::text
                          = current_setting('project1.actor_id', true)));

GRANT SELECT, INSERT, UPDATE ON public.cq_collection_state TO p1_ee01_runtime;
GRANT SELECT ON public.cq_collection_state TO p1_cq_publisher;

DO $$
BEGIN
  -- Post-state: the surface is exactly what the service needs.
  IF NOT has_table_privilege('p1_ee01_runtime',
                             'public.cq_collection_state', 'SELECT')
     OR NOT has_table_privilege('p1_ee01_runtime',
                                'public.cq_collection_state', 'INSERT')
     OR NOT has_table_privilege('p1_ee01_runtime',
                                'public.cq_collection_state', 'UPDATE') THEN
    RAISE EXCEPTION 'ee01 runtime lacks the collection-state write surface';
  END IF;
  IF has_table_privilege('p1_ee01_runtime',
                         'public.cq_collection_state', 'DELETE') THEN
    RAISE EXCEPTION 'ending collection must not be able to delete state';
  END IF;
  IF has_table_privilege('p1_cq_publisher',
                         'public.cq_collection_state', 'INSERT')
     OR has_table_privilege('p1_cq_publisher',
                            'public.cq_collection_state', 'UPDATE')
     OR has_table_privilege('p1_cq_publisher',
                            'public.cq_collection_state', 'DELETE') THEN
    RAISE EXCEPTION 'publishing must not configure collection';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class
           WHERE oid = 'public.cq_collection_state'::regclass) THEN
    RAISE EXCEPTION 'RLS is not enabled on cq_collection_state';
  END IF;
  IF (SELECT count(*) FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'cq_collection_state') <> 4 THEN
    RAISE EXCEPTION 'expected exactly four policies on cq_collection_state';
  END IF;
  -- The campaign row must remain insert-once. This migration adds no privilege
  -- to it; assert that rather than assume it.
  IF has_table_privilege('p1_ee01_runtime', 'public.cq_campaigns', 'UPDATE')
     OR has_table_privilege('p1_cq_publisher', 'public.cq_campaigns', 'UPDATE') THEN
    RAISE EXCEPTION 'cq_campaigns gained UPDATE: the release binding is no longer immutable';
  END IF;
  -- And the target must have exactly one home.
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND column_name = 'respondent_target'
                AND table_name <> 'cq_collection_state') THEN
    RAISE EXCEPTION 'respondent_target exists outside cq_collection_state';
  END IF;
END $$;

INSERT INTO cq_schema_migrations(version, migration_sha256, receipt)
VALUES ('20261125_04', current_setting('project1.cq_migration_sha256'),
        current_setting('project1.cq_migration_receipt'))
ON CONFLICT (version) DO NOTHING;

COMMIT;
