-- CP-10A (rev.2) — compatibility binding between a marketplace assessment and an M2 assessment
--
-- STATUS: PREPARED ONLY. NOT APPLIED TO Dss.
-- Applying this file requires separate Owner authorisation (directive §7).
--
-- REV.2 CHANGE
--   The owner column is named `user_id`, per the narrowed directive, not `owner_user_id`.
--   `m2_assessments.owner_user_id` is NOT renamed: the M2 ownership model is unchanged.
--   The composite foreign key still reads across the two names:
--       m2_assessment_links.(m2_assessment_id, user_id)
--         REFERENCES m2_assessments.(id, owner_user_id)
--   That is legal because a FK names the target columns explicitly.
--
-- WHY THE TABLE LIVES IN Dss
--   The marketplace assessment is written to Final_Location_Analysis; the M2 assessment is
--   written to Dss. PostgreSQL cannot enforce a foreign key across databases, so the link is
--   placed on the authoritative side where one half can still be constrained.
--
-- WHY A COMPOSITE FOREIGN KEY (and not just user_id -> users)
--   `user_id REFERENCES users(user_id)` proves only that the user exists. It does not prove
--   the user owns the linked M2 assessment. `m2_assessments` already carries
--   `uq_m2_assessment_owner UNIQUE (id, owner_user_id)`, which makes the composite FK below
--   possible and turns "this link's user owns this assessment" into a database fact.
--
-- CARDINALITY
--   Partial unique indexes over the *active* rows give 1:0..1 in both directions, while
--   revoked rows remain as history and do not block re-binding.
--
-- ROLLBACK
--   20261118_05_assessment_binding_links_rollback.sql — archives before dropping.

BEGIN;

CREATE TABLE IF NOT EXISTS public.m2_assessment_links (
    link_id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Authoritative side. Composite FK below proves ownership, not just existence.
    m2_assessment_id          uuid        NOT NULL,

    -- Legacy side. Cross-database, therefore application-verified only (documented gap).
    marketplace_assessment_id uuid        NOT NULL,

    -- Authenticated entrepreneur. FK -> users, and half of the composite ownership FK.
    user_id                   uuid        NOT NULL,

    created_at                timestamptz NOT NULL DEFAULT now(),
    created_by                uuid        NOT NULL,

    -- Revocation instead of deletion: history is preserved and the pair can be re-bound.
    revoked_at                timestamptz,
    revoked_by                uuid,
    revoke_reason             text,

    CONSTRAINT ck_m2_link_distinct_ids
        CHECK (m2_assessment_id <> marketplace_assessment_id),

    -- Either fully active, or fully revoked with a reason. No half-revoked rows.
    CONSTRAINT ck_m2_link_revocation_state CHECK (
           (revoked_at IS NULL     AND revoked_by IS NULL     AND revoke_reason IS NULL)
        OR (revoked_at IS NOT NULL AND revoked_by IS NOT NULL
            AND revoke_reason IS NOT NULL AND length(btrim(revoke_reason)) > 0)
    ),

    -- The link's user must own the M2 assessment. This is the constraint that makes
    -- `user_id REFERENCES users` insufficient on its own.
    CONSTRAINT fk_m2_link_assessment_user
        FOREIGN KEY (m2_assessment_id, user_id)
        REFERENCES public.m2_assessments (id, owner_user_id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_m2_link_user
        FOREIGN KEY (user_id) REFERENCES public.users (user_id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_m2_link_created_by
        FOREIGN KEY (created_by) REFERENCES public.users (user_id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_m2_link_revoked_by
        FOREIGN KEY (revoked_by) REFERENCES public.users (user_id)
        ON DELETE RESTRICT
);

-- 1:0..1 in both directions, counting only active rows.
CREATE UNIQUE INDEX IF NOT EXISTS uq_m2_link_m2_active
    ON public.m2_assessment_links (m2_assessment_id)
    WHERE revoked_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_m2_link_marketplace_active
    ON public.m2_assessment_links (marketplace_assessment_id)
    WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_m2_link_user
    ON public.m2_assessment_links (user_id);

-- Same owner-scoped RLS shape as every other M2 table. FORCE so the table owner is not
-- silently exempt either.
ALTER TABLE public.m2_assessment_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.m2_assessment_links FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS owner_scope ON public.m2_assessment_links;
CREATE POLICY owner_scope ON public.m2_assessment_links
    USING (user_id = (NULLIF(current_setting('project1.actor_id', true), ''))::uuid)
    WITH CHECK (user_id = (NULLIF(current_setting('project1.actor_id', true), ''))::uuid);

-- Least privilege: INSERT to bind, UPDATE to revoke, SELECT to read. No DELETE, no TRUNCATE.
GRANT SELECT, INSERT, UPDATE ON public.m2_assessment_links TO p1_m2_runtime;
REVOKE DELETE, TRUNCATE ON public.m2_assessment_links FROM p1_m2_runtime;

COMMIT;
