-- Versioned schema: BDJ objective proposals (candidate only).
-- Migration: 20261121_0100_m2_bdj_objective_proposals
-- Target: disposable cluster only. Never applied to Dss by tooling.
--
-- Identity is a deterministic proposal_id, not a rule-level unique key: one
-- answer can yield one proposal per contract/prompt, and a retry must land on
-- the same row instead of raising. No rule-level uniqueness anywhere.

CREATE TABLE IF NOT EXISTS public.m2_bdj_objective_proposals (
    proposal_id             uuid        PRIMARY KEY,
    evaluation_id           uuid        NOT NULL,
    assessment_id           uuid        NOT NULL,
    confirmation_id         uuid        NOT NULL,
    confirmation_revision   integer     NOT NULL,
    source_fingerprint      char(64)    NOT NULL,
    context_id              varchar(64) NOT NULL,
    context_packet_hash     char(64)    NOT NULL,
    recommendation_status   varchar(24) NOT NULL
        CHECK (recommendation_status IN ('MOST_SUGGESTED', 'SUGGESTED')),
    problem_type            varchar(48) NOT NULL
        CHECK (problem_type IN ('SOURCE_CONFIRMED_INFORMATION_GAP',
                                'EXPLORATORY_RESEARCH_NEED')),
    problem                 text,
    research_objective      varchar(500) NOT NULL,
    reason                  varchar(1000) NOT NULL,
    evidence_limitation     varchar(1000),
    source_refs             jsonb       NOT NULL DEFAULT '[]'::jsonb,
    contract_version        varchar(64) NOT NULL,
    prompt_version          varchar(64) NOT NULL,
    execution_mode          varchar(16) NOT NULL
        CHECK (execution_mode IN ('LIVE', 'SIMULATED', 'DETERMINISTIC')),
    model_provider          varchar(64),
    model_requested         varchar(128),
    model_returned          varchar(128),
    validation_status       varchar(24) NOT NULL
        CHECK (validation_status IN ('VALID', 'REJECTED', 'NOT_VALIDATED')),
    review_state            varchar(24) NOT NULL DEFAULT 'CANDIDATE'
        CHECK (review_state IN ('CANDIDATE', 'REVIEWED', 'WITHDRAWN')),
    owner_user_id           uuid        NOT NULL,
    created_at              timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_proposal_most_has_source
        CHECK (recommendation_status <> 'MOST_SUGGESTED'
               OR jsonb_array_length(source_refs) >= 1),
    CONSTRAINT ck_proposal_suggested_has_no_problem
        CHECK (recommendation_status <> 'SUGGESTED' OR problem IS NULL),
    CONSTRAINT ck_proposal_refs_array
        CHECK (jsonb_typeof(source_refs) = 'array')
);

CREATE INDEX IF NOT EXISTS ix_bdj_proposals_owner_assessment
    ON public.m2_bdj_objective_proposals (owner_user_id, assessment_id,
                                          confirmation_revision);
CREATE INDEX IF NOT EXISTS ix_bdj_proposals_evaluation
    ON public.m2_bdj_objective_proposals (evaluation_id);
