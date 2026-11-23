-- Versioned schema: BDJ objective admission (the missing post-confirmation
-- finding-authority record for the v3 declaration-only contract).
-- Migration: 20261122_0400_m2_bdj_objective_admissions
-- Target: disposable cluster only. Never applied to Dss by tooling.
--
-- WHY THIS EXISTS
-- --------------
-- `m2-confirmation/3` is declaration-only by construction: the snapshot pins
-- `unresolved_candidate_findings = []` and `finding_decision_event_refs = {}`,
-- and `pins_match()` actively *rejects* a v3 snapshot that carries findings or a
-- `bdj_evaluation_id`. That was deliberate — confirmation of declarations must
-- not imply confirmation of model findings.
--
-- The consequence is that `confirm_objective(origin='BDJ')` can never satisfy its
-- own precondition, because the finding-authority record it looks for cannot
-- exist in a v3 world. Every APPROVED proposal therefore stops at
-- `M2_UNCERTAINTY_LINK_REQUIRED`.
--
-- The legacy answer was `public.m2_finding_reviews` (S1/A1/P1): an append-only
-- owner decision that a *rule-derived finding* is worth researching. That table
-- cannot serve the objective-proposal path because it is keyed on
-- `finding_id -> public.m2_bdj_findings`, and in v3 no findings are ever
-- produced. Keying an admission to a fabricated finding row would invent
-- provenance, so this table is keyed on the proposal instead.
--
-- WHAT THIS IS
-- ------------
-- The same *shape* of record as m2_finding_reviews, re-pointed at the object
-- that actually exists: one append-only owner decision that the gap cited by a
-- specific proposal is worth researching.
--
-- WHAT THIS IS NOT
-- ----------------
--   * Not a verification. No column can assert truth. It is self-approval and
--     must never be described as independent review.
--   * Not an approval. `APPROVED` already lives in
--     `m2_bdj_objective_decisions`; this record is the *separate* authority step
--     that approval alone does not confer.
--   * Not a QG authorisation. Nothing here authorises QJ or QG; both stay false
--     in the contract regardless of how many rows exist.
--   * Not mutable. UPDATE and DELETE are refused by trigger.
--
-- DECISION VOCABULARY
-- Single value WORTH_RESEARCHING, matching m2_finding_reviews. An unused enum is
-- a promise nobody tested.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $guard$
BEGIN
  -- Same rule as 20261122_0300: protected databases are refused by name, the
  -- protected cluster is refused by port, and only the project1_ namespace is
  -- accepted. A hard-coded database name here made fresh provisioning
  -- impossible for any disposable database with a different name.
  IF current_database() IN ('Dss', 'dss', 'Final_Location_Analysis', 'sitesense', 'postgres') THEN
    RAISE EXCEPTION 'Refusing to add objective admission on protected database %',
      current_database();
  END IF;
  IF inet_server_port() = 5432 THEN
    RAISE EXCEPTION 'Refusing to add objective admission on the protected cluster (port 5432, database %)',
      current_database();
  END IF;
  IF current_database() NOT LIKE 'project1\_%' THEN
    RAISE EXCEPTION 'Unexpected target %: expected a project1_ disposable database on a non-5432 port',
      current_database();
  END IF;
  IF to_regclass('public.m2_bdj_objective_proposals') IS NULL THEN
    RAISE EXCEPTION 'm2_bdj_objective_proposals required';
  END IF;
END
$guard$;

-- Composite identity the admission FK can pin to. Detected by COLUMNS, not by
-- name, so a pre-existing constraint with the same name but different columns
-- cannot make this block skip silently.
DO $key$
BEGIN
  IF NOT EXISTS (
      SELECT 1 FROM pg_constraint c
      WHERE c.conrelid = 'public.m2_bdj_objective_proposals'::regclass
        AND c.contype = 'u'
        AND (SELECT array_agg(a.attname::text ORDER BY a.attname)
             FROM unnest(c.conkey) AS k
             JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k)
            = ARRAY['assessment_id','confirmation_id','proposal_id','source_fingerprint'])
  THEN
    ALTER TABLE public.m2_bdj_objective_proposals
      ADD CONSTRAINT uq_bdj_proposal_admission_identity
        UNIQUE (proposal_id, assessment_id, confirmation_id, source_fingerprint);
  END IF;
END
$key$;

CREATE TABLE IF NOT EXISTS public.m2_bdj_objective_admissions (
    admission_id           uuid        PRIMARY KEY,
    proposal_id            uuid        NOT NULL,
    assessment_id          uuid        NOT NULL,
    confirmation_id        uuid        NOT NULL,
    confirmation_revision  integer     NOT NULL CHECK (confirmation_revision >= 0),
    source_fingerprint     char(64)    NOT NULL,
    context_packet_hash    char(64)    NOT NULL,
    -- The owner who made this decision. RLS scopes every read and write to it.
    actor_user_id          uuid        NOT NULL,
    -- S1 only. Authority over a gap is not a claim that the gap is true.
    decision               varchar(24) NOT NULL
        CHECK (decision = 'WORTH_RESEARCHING'),
    -- SHA-256 over the proposal content at admission time, so a later reader can
    -- prove the decision was made about THIS objective and not a substituted row.
    proposal_hash          char(64)    NOT NULL
        CHECK (proposal_hash ~ '^[a-f0-9]{64}$'),
    -- Replay guard: one request id may not record two admissions.
    request_id             uuid        NOT NULL,
    created_at             timestamptz NOT NULL DEFAULT now(),

    -- The admission must describe the proposal it names, at the same assessment,
    -- confirmation and source fingerprint. Not "a proposal", this one.
    CONSTRAINT fk_admission_proposal_identity
        FOREIGN KEY (proposal_id, assessment_id, confirmation_id, source_fingerprint)
        REFERENCES public.m2_bdj_objective_proposals
                   (proposal_id, assessment_id, confirmation_id, source_fingerprint),

    -- One admission per proposal. A second admission is a different proposal or
    -- a new confirmation, never an overwrite.
    CONSTRAINT uq_admission_once UNIQUE (proposal_id),
    CONSTRAINT uq_admission_request UNIQUE (assessment_id, request_id)
);

COMMENT ON TABLE public.m2_bdj_objective_admissions IS
  'Append-only owner decision that the information gap cited by a specific BDJ '
  'objective proposal is worth researching. This is the post-confirmation '
  'finding-authority record that m2-confirmation/3 deliberately omits. It is '
  'self-approval, NOT independent review, and authorises neither QJ nor QG.';

COMMENT ON COLUMN public.m2_bdj_objective_admissions.proposal_hash IS
  'SHA-256 over the proposal content at admission time. The row is append-only, '
  'so a mismatch means the admission referred to something that is no longer '
  'what it described.';

CREATE INDEX IF NOT EXISTS ix_bdj_admissions_confirmation
    ON public.m2_bdj_objective_admissions (confirmation_id, created_at);

CREATE INDEX IF NOT EXISTS ix_bdj_admissions_actor
    ON public.m2_bdj_objective_admissions (actor_user_id, assessment_id);

CREATE OR REPLACE FUNCTION public.m2_bdj_admission_reject_mutation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Objective admissions are append-only' USING ERRCODE = '55000';
END $$;

DROP TRIGGER IF EXISTS m2_bdj_admission_append_only
    ON public.m2_bdj_objective_admissions;
CREATE TRIGGER m2_bdj_admission_append_only
    BEFORE UPDATE OR DELETE ON public.m2_bdj_objective_admissions
    FOR EACH ROW EXECUTE FUNCTION public.m2_bdj_admission_reject_mutation();

ALTER TABLE public.m2_bdj_objective_admissions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.m2_bdj_objective_admissions FROM PUBLIC;
DROP POLICY IF EXISTS owner_scope ON public.m2_bdj_objective_admissions;
CREATE POLICY owner_scope ON public.m2_bdj_objective_admissions
  USING (actor_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (actor_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);

DO $grant$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_m2_runtime') THEN
    GRANT SELECT, INSERT ON public.m2_bdj_objective_admissions TO p1_m2_runtime;
  END IF;
END
$grant$;

COMMIT;
