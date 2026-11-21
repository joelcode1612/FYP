-- S1: record that an owner decided a finding is worth researching.
--
-- WHY THIS EXISTS
-- Decision S1/A1/P1 (2026-11-21) authorises exactly one meaning for approval:
-- "this gap is worth researching". It does NOT authorise "the finding is true"
-- and it does NOT authorise VERIFIED. public.m2_bdj_findings is append-only, so
-- approval can never be an UPDATE of review_state; it must be a separate event.
--
-- WHAT THIS IS NOT
--   * Not a verification. No column here can assert truth, and no code path may
--     present a row in this table as independent review (A1 is self-approval).
--   * Not a replacement for m2_clarification_events. That table's decision CHECK
--     is KEEP_ORIGINAL/REVIEW_LATER and it has no confirmation binding; reusing
--     it would silently overload "acknowledged" to mean "approved".
--   * Not mutable. An approval recorded in error cannot be withdrawn by UPDATE;
--     the only remedy is a later event that supersedes it, which does not exist
--     yet and is deliberately not invented here.
--
-- DECISION VOCABULARY
-- Single value WORTH_RESEARCHING. A second value (e.g. REJECTED) is not added
-- until someone needs it: an unused enum is a promise nobody tested.
--
-- STATUS: PROPOSED. NOT APPLIED. Refuses the protected database by name.
--
-- Explicit operator execution only. Never run at application startup.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $guard$
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required';
  END IF;

  IF current_database() = 'Dss' THEN
    RAISE EXCEPTION 'Refusing to add finding review on protected database %', current_database();
  END IF;

  IF to_regclass('public.m2_bdj_findings') IS NULL
     OR to_regclass('public.m2_confirmation_snapshots') IS NULL THEN
    RAISE EXCEPTION 'finding and confirmation tables required';
  END IF;

  IF to_regclass('public.m2_finding_reviews') IS NOT NULL THEN
    RAISE EXCEPTION 'm2_finding_reviews exists: reconcile version before migrating';
  END IF;
END
$guard$;

-- The composite FK below needs a unique key on (id, assessment_id,
-- assessment_revision). Migration 20261113_01 normally creates it as
-- uq_m2_finding_source. Ensure it exists so this file does not silently depend
-- on migration ordering; if 20261113_01 already ran, this is a no-op.
DO $key$
BEGIN
  -- Detect by COLUMNS, not by name. D3 already creates a constraint called
  -- uq_m2_finding_source, and it covers a different column set; matching on the
  -- name would make this block skip and the FK below fail.
  IF NOT EXISTS (
      SELECT 1 FROM pg_constraint c
      WHERE c.conrelid = 'public.m2_bdj_findings'::regclass AND c.contype = 'u'
        AND (SELECT array_agg(a.attname::text ORDER BY a.attname)
             FROM unnest(c.conkey) AS k
             JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k)
            = ARRAY['assessment_id','assessment_revision','id'])
  THEN
    ALTER TABLE public.m2_bdj_findings
      ADD CONSTRAINT uq_m2_finding_identity_revision
        UNIQUE (id, assessment_id, assessment_revision);
  END IF;
  IF NOT EXISTS (
      SELECT 1 FROM pg_constraint c
      WHERE c.conrelid = 'public.m2_confirmation_snapshots'::regclass AND c.contype = 'u'
        AND (SELECT array_agg(a.attname::text ORDER BY a.attname)
             FROM unnest(c.conkey) AS k
             JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k)
            = ARRAY['actor_user_id','assessment_id','assessment_revision','id'])
  THEN
    ALTER TABLE public.m2_confirmation_snapshots
      ADD CONSTRAINT uq_m2_confirmation_identity_revision
        UNIQUE (id, assessment_id, assessment_revision, actor_user_id);
  END IF;
END
$key$;

CREATE TABLE public.m2_finding_reviews (
  id                  uuid PRIMARY KEY,
  finding_id          uuid NOT NULL,
  assessment_id       uuid NOT NULL,
  assessment_revision integer NOT NULL CHECK (assessment_revision >= 0),
  -- Bound to the confirmation the owner was looking at, not to "latest".
  confirmation_id     uuid NOT NULL,
  actor_user_id       uuid NOT NULL,
  -- S1 only. Never add VERIFIED here: authority over a finding is not a decision.
  decision            text NOT NULL CHECK (decision = 'WORTH_RESEARCHING'),
  -- Hash of the finding row at review time, so a later reader can prove the
  -- decision was made about THIS content and not a substituted row.
  finding_hash        text NOT NULL CHECK (finding_hash ~ '^[a-f0-9]{64}$'),
  -- Replay guard: the same request id may not record two decisions.
  request_id          uuid NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  -- The finding must exist at the revision this decision names.
  FOREIGN KEY (finding_id, assessment_id, assessment_revision)
    REFERENCES public.m2_bdj_findings (id, assessment_id, assessment_revision),
  FOREIGN KEY (confirmation_id, assessment_id, assessment_revision, actor_user_id)
    REFERENCES public.m2_confirmation_snapshots (id, assessment_id, assessment_revision, actor_user_id),
  -- One decision per finding per confirmation. A second decision is a different
  -- confirmation or a new finding, never an overwrite.
  CONSTRAINT uq_m2_finding_review_once UNIQUE (confirmation_id, finding_id),
  CONSTRAINT uq_m2_finding_review_request UNIQUE (assessment_id, request_id)
);

COMMENT ON TABLE public.m2_finding_reviews IS
  'Append-only record of an owner decision that a BDJ finding is worth '
  'researching (decision S1/A1/P1). Self-approval: it is NOT independent review '
  'and must never be described as verification. The finding row itself is '
  'untouched and stays CANDIDATE.';

COMMENT ON COLUMN public.m2_finding_reviews.finding_hash IS
  'SHA-256 over the finding row at review time. Lets a reader prove the decision '
  'was about this exact content. The row is append-only, so a mismatch means the '
  'decision referred to something that is no longer what it described.';

CREATE INDEX ix_m2_finding_reviews_confirmation
  ON public.m2_finding_reviews (confirmation_id, created_at);

CREATE FUNCTION public.m2_finding_review_reject_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Finding reviews are append-only' USING ERRCODE='55000'; END $$;

CREATE TRIGGER m2_finding_review_append_only
  BEFORE UPDATE OR DELETE ON public.m2_finding_reviews
  FOR EACH ROW EXECUTE FUNCTION public.m2_finding_review_reject_mutation();

ALTER TABLE public.m2_finding_reviews ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.m2_finding_reviews FROM PUBLIC;
CREATE POLICY owner_scope ON public.m2_finding_reviews
  USING (actor_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (actor_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);
GRANT SELECT, INSERT ON public.m2_finding_reviews TO p1_m2_runtime;

COMMIT;
