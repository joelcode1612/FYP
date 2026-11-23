-- Versioned schema: entrepreneur decisions on BDJ objective proposals.
-- Migration: 20261121_0200_m2_bdj_objective_decisions
-- Append-only. A rejection never deletes the proposal; it records an outcome.
--
-- One decision per proposal (UNIQUE proposal_id). A repeat of the same decision
-- by the same actor is idempotent; a different decision is refused, so an
-- approval cannot be silently overwritten by a later rejection or vice versa.

CREATE TABLE IF NOT EXISTS public.m2_bdj_objective_decisions (
    decision_id          uuid        PRIMARY KEY,
    proposal_id          uuid        NOT NULL
        REFERENCES public.m2_bdj_objective_proposals (proposal_id),
    decision             varchar(16) NOT NULL
        CHECK (decision IN ('APPROVED', 'REJECTED')),
    decided_by           uuid        NOT NULL,
    decided_at           timestamptz NOT NULL DEFAULT now(),
    source_fingerprint   char(64)    NOT NULL,
    confirmation_id      uuid        NOT NULL,
    context_packet_hash  char(64)    NOT NULL,
    note                 varchar(500),
    CONSTRAINT uq_bdj_proposal_decision UNIQUE (proposal_id)
);

CREATE INDEX IF NOT EXISTS ix_bdj_decisions_proposal
    ON public.m2_bdj_objective_decisions (proposal_id);
CREATE INDEX IF NOT EXISTS ix_bdj_decisions_actor
    ON public.m2_bdj_objective_decisions (decided_by, decided_at);

-- The proposal's review_state now reflects the decision outcome. Drop whichever
-- auto-named check guarded review_state, then install one explicit constraint.
DO $$
DECLARE c record;
BEGIN
    FOR c IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'public.m2_bdj_objective_proposals'::regclass
          AND contype = 'c'
          AND pg_get_constraintdef(oid) LIKE '%review_state%'
    LOOP
        EXECUTE format('ALTER TABLE public.m2_bdj_objective_proposals '
                       'DROP CONSTRAINT %I', c.conname);
    END LOOP;
END $$;

ALTER TABLE public.m2_bdj_objective_proposals
    ADD CONSTRAINT ck_proposal_review_state
    CHECK (review_state IN ('CANDIDATE', 'APPROVED', 'REJECTED',
                            'REVIEWED', 'WITHDRAWN'));
