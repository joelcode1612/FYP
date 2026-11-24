-- N04-B Task B: attach a Stage 4 review to a persisted Direct-QG candidate.
--
-- The gap this closes
-- -------------------
-- public.m2_qg_candidates is the authoritative record of a generated
-- Direct-QG question. Stage 4 has nowhere to record an owner's judgement about
-- one, because public.m2_candidate_owner_reviews.candidate_id is bound by
-- FK(candidate_id, reviewer_id) -> public.m2_candidate_review_assignments, which
-- in turn references public.m2_review_question_versions(id) -- a uuid-keyed
-- table that holds no Direct-QG rows at all.
--
-- Two ways out exist. The rejected one is to project every candidate into
-- public.m2_review_question_versions, which would create two independently
-- mutable copies of one generated question and make "which one did the reviewer
-- judge?" ambiguous. The chosen one is additive: one new table keyed by the
-- candidate that already exists.
--
-- Why no new identity column
-- --------------------------
-- public.m2_qg_candidates.objective_admission_id already names the admitted
-- objective uniquely. The admission row carries assessment_id, confirmation_id,
-- confirmation_revision, context_packet_hash, objective_id (the O1..O6 code, or
-- NULL for an optional BDJ objective), proposal_id, proposal_hash and the
-- policy identity. Joining candidate -> admission therefore yields every
-- traceability property the directive lists, for both the fixed-objective case
-- and the optional-BDJ case, without a second identity system and without
-- changing an existing column type.
--
-- Additive only: one CREATE TABLE, one index, one grant, one RLS policy. No
-- existing table, column, constraint or row is touched.
--
-- Explicit operator execution only. Never run at application startup.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required '
                    '(project1.m2_bcb_migration_target must equal current_database(); '
                    'project1.m2_bcb_migration_receipt must be non-empty)';
  END IF;

  -- Hard safety by name: the protected databases are refused even if a caller
  -- sets the guard setting to one of them by mistake.
  IF current_database() IN ('Dss', 'Final_Location_Analysis') THEN
    RAISE EXCEPTION 'Refusing to apply QG candidate review to protected database %',
                    current_database();
  END IF;

  IF to_regclass('public.m2_qg_candidates') IS NULL THEN
    RAISE EXCEPTION 'public.m2_qg_candidates is missing; apply the QG candidate DDL first';
  END IF;
END
$guard$;

CREATE TABLE IF NOT EXISTS public.m2_qg_candidate_reviews (
    candidate_id         uuid        NOT NULL
        REFERENCES public.m2_qg_candidates (candidate_id) ON DELETE RESTRICT,
    -- Denormalised from the candidate so the existing owner_scope RLS shape
    -- applies unchanged. The writer copies it from the candidate row; a request
    -- body can never set it.
    owner_user_id        uuid        NOT NULL,
    reviewer_id          uuid        NOT NULL,
    -- NULL until the reviewer records a decision. A row may legitimately hold
    -- only an expected answer, because recording an expectation and judging the
    -- question are separate acts.
    decision             text        NULL,
    rationale            text        NOT NULL DEFAULT '',
    -- The entrepreneur's expectation about the answer. Never a respondent
    -- answer, and never read by a CQ or EE-01 calculation.
    expected_option_code text        NULL,
    -- The confirmation snapshot digest the judgement was made against, so a
    -- later reader can tell which context the reviewer saw.
    context_hash         varchar(64) NULL,
    recorded_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT m2_qg_candidate_reviews_pkey PRIMARY KEY (candidate_id, reviewer_id),
    -- Must agree with the vocabulary the existing owner-review endpoint accepts.
    CONSTRAINT m2_qg_candidate_reviews_decision_check CHECK (
        decision IS NULL
        OR decision IN ('APPROVE_FOR_REVIEW', 'REJECT', 'REQUEST_REVISION')),
    CONSTRAINT m2_qg_candidate_reviews_rationale_len CHECK (char_length(rationale) <= 1000),
    CONSTRAINT m2_qg_candidate_reviews_context_hash_format CHECK (
        context_hash IS NULL OR context_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT m2_qg_candidate_reviews_expected_code_len CHECK (
        expected_option_code IS NULL OR char_length(expected_option_code) BETWEEN 1 AND 100)
);

CREATE INDEX IF NOT EXISTS m2_qg_candidate_reviews_reviewer_idx
    ON public.m2_qg_candidate_reviews (reviewer_id);

ALTER TABLE public.m2_qg_candidate_reviews ENABLE ROW LEVEL SECURITY;

DO $policy$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname = 'public'
                   AND tablename = 'm2_qg_candidate_reviews'
                   AND policyname = 'owner_scope') THEN
    -- Identical shape to public.m2_qg_candidates.owner_scope: the restricted
    -- principal sees only rows whose owner matches the bound actor GUC, so a
    -- missing or empty setting yields zero rows rather than an error.
    CREATE POLICY owner_scope ON public.m2_qg_candidate_reviews
      USING (owner_user_id = (NULLIF(current_setting('project1.actor_id', true), ''))::uuid)
      WITH CHECK (owner_user_id = (NULLIF(current_setting('project1.actor_id', true), ''))::uuid);
  END IF;
END
$policy$;

GRANT SELECT, INSERT, UPDATE ON public.m2_qg_candidate_reviews TO p1_m2_runtime;

COMMIT;
