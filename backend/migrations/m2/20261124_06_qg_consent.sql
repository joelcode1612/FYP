-- DD-044: a separate, append-only, revision-bound QG consent record.
--
-- The defect this closes
-- ----------------------
-- QG candidate generation requires an explicit owner permission to send the
-- confirmed business facts to an external model
-- (``ai_processing_consent.QG_CONSENT_VERSION = 'ai-processing-consent-qg/1'``).
-- ``qg_authorization.consent_block()`` looked for that grant in exactly one
-- place: ``m2_confirmation_snapshots.snapshot_json -> 'ai_processing_qg'``.
--
-- No such key exists, and none can be created:
--
--   * 0 of 19 snapshots carry it. The snapshot key list is fixed by
--     ``confirmation_service`` and carries ``ai_processing`` only -- the
--     objective-derivation grant, a different contract with a different
--     purpose.
--   * ``build_qg_consent()`` had no caller, so the key was never written.
--   * No route could write it: the only QG consent endpoints are the two
--     ``ai-processing-disclosure[-qg]`` GETs, which disclose terms and record
--     nothing.
--   * ``cq_consent_events`` is a CQ respondent concept and cannot carry an M2
--     assessment, revision, confirmation or objective binding.
--
-- So generation stopped at ``AI_PROCESSING_QG_CONSENT_ABSENT`` for every
-- assessment, and the only ways forward were to fabricate a grant (writing the
-- block by hand) or to reinterpret the objective-derivation grant as QG
-- permission. Both are refused: a grant for one act is not a grant for another.
--
-- Why a separate store rather than a new snapshot key (owner decision, Option B)
-- -----------------------------------------------------------------------------
-- Adding ``ai_processing_qg`` to ``snapshot_json`` would mean writing a new
-- confirmation snapshot, which means a new M2 revision. A permission to process
-- data must not invalidate the owner's existing approved research objective, so
-- consent has to live somewhere that is *not* part of the declaration record.
-- This table is that place. It is append-only, bound to one confirmed revision,
-- and it touches no business declaration, no snapshot and no approval.
--
-- What this adds
-- --------------
-- ``public.m2_qg_consent_grants``      one row per granted permission
-- ``public.m2_qg_consent_consumptions`` the single attempt a grant authorises
--
-- A grant is bound to every term the owner asked to see:
--
--   owner_user_id          the authenticated entrepreneur who granted it
--   assessment_id +
--   assessment_revision    the confirmed revision it applies to
--   confirmation_id +
--   bcb_digest             the confirmation and the BCB content relied on
--   objective_decision_id  the applicable approved research objective, through
--   objective_kind         the same (decision_id, confirmation_id) unique key
--   objective_id           migration 05 introduced, so a refused objective
--                          cannot authorise anything
--   purpose + scope        the QG act and its disclosure scope (closed
--                          vocabularies)
--   disclosure_purpose +
--   disclosure_scope       the prose and data list the owner was shown
--   provider + model +
--   endpoint               who received it
--   prompt_version +
--   prompt_sha256          what was asked
--   max_attempts           the authorised attempt allowance (pinned to 1)
--   expires_at             when the permission lapses
--   consent_digest +
--   consent_block          the canonical block, re-verified on every read
--
-- Attempt accounting is a second table rather than a counter, so a grant stays
-- immutable once written. ``m2_qg_consent_consumptions.consent_id`` is the
-- PRIMARY KEY, so the database itself permits at most one consumption per
-- grant: reserving the attempt and consuming it are the same INSERT, which
-- either wins or loses. Two concurrent dispatches cannot both reserve it.
--
-- Scope limit, stated rather than implied
-- ---------------------------------------
-- A grant names an *owner-approved proposal decision*
-- (``m2_bdj_objective_decisions``). It does not bind to a registry-objective
-- admission: QG consent is granted from the Stage 4 review surface, which only
-- ever offers owner-approved proposals, and Direct-QG 2.1 authority for
-- generated questions is decision-based. If a registry objective ever needs a
-- QG grant, that is a new consent version with its own terms -- not a widened
-- row here.
--
-- Historical compatibility
-- ------------------------
-- ``consent_block()`` reads this store first and falls back to the snapshot key
-- only when no row exists, so a legacy grant (were one ever written) is never
-- shadowed by this mechanism. Nothing is dropped, retyped or backfilled: no
-- historical consent is invented here.
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

  IF current_database() IN ('Dss', 'Final_Location_Analysis') THEN
    RAISE EXCEPTION 'Refusing to apply QG consent store to protected database %',
                    current_database();
  END IF;

  IF to_regclass('public.m2_confirmation_snapshots') IS NULL
     OR to_regclass('public.m2_bdj_objective_decisions') IS NULL
     OR to_regclass('public.m2_qg_authorizations') IS NULL THEN
    RAISE EXCEPTION 'QG consent depends on m2_confirmation_snapshots, '
                    'm2_bdj_objective_decisions and m2_qg_authorizations';
  END IF;

  -- 20261124_05 introduces the (decision_id, confirmation_id) unique key this
  -- table's composite foreign key needs. Refusing early is better than failing
  -- halfway through a migration that cannot be re-run blindly.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'uq_bdj_decision_confirmation') THEN
    RAISE EXCEPTION 'uq_bdj_decision_confirmation is missing: apply '
                    '20261124_05_objective_authority.sql first';
  END IF;
END
$guard$;

-- ---------------------------------------------------------------------------
-- 1. The grant.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.m2_qg_consent_grants (
    consent_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    assessment_id        uuid        NOT NULL,
    assessment_revision  integer     NOT NULL,
    confirmation_id      uuid        NOT NULL,
    bcb_digest           varchar(120) NOT NULL,

    objective_decision_id uuid       NOT NULL,
    objective_kind        varchar(40) NOT NULL,
    objective_id          varchar(64) NOT NULL,

    owner_user_id        uuid        NOT NULL,

    purpose              varchar(64) NOT NULL,
    scope                varchar(64) NOT NULL,
    disclosure_purpose   text        NOT NULL,
    disclosure_scope     jsonb       NOT NULL,
    entire_context_packet boolean    NOT NULL DEFAULT false,

    contract_version     varchar(64) NOT NULL,
    provider             varchar(32) NOT NULL,
    model                varchar(120) NOT NULL,
    endpoint             varchar(120) NOT NULL,
    prompt_version       varchar(64) NOT NULL,
    prompt_sha256        char(64)    NOT NULL,

    max_attempts         smallint    NOT NULL DEFAULT 1,
    expires_at           timestamptz NOT NULL,
    granted_at           timestamptz NOT NULL DEFAULT now(),

    request_id           varchar(120) NOT NULL,
    consent_digest       char(64)    NOT NULL,
    consent_block        jsonb       NOT NULL,

    revoked_at           timestamptz NULL,
    revoked_reason       varchar(200) NULL,

    CONSTRAINT m2_qg_consent_grants_assessment_fkey
        FOREIGN KEY (assessment_id) REFERENCES public.m2_assessments (id)
        ON DELETE RESTRICT,
    CONSTRAINT m2_qg_consent_grants_confirmation_fkey
        FOREIGN KEY (confirmation_id) REFERENCES public.m2_confirmation_snapshots (id)
        ON DELETE RESTRICT,
    -- Composite, so the decision named here must belong to *this* confirmation.
    -- A decision from another confirmation would otherwise be accepted by a
    -- plain single-column foreign key, and the grant would claim an authority
    -- it does not have.
    CONSTRAINT m2_qg_consent_grants_decision_fkey
        FOREIGN KEY (objective_decision_id, confirmation_id)
        REFERENCES public.m2_bdj_objective_decisions (decision_id, confirmation_id)
        ON DELETE RESTRICT,
    CONSTRAINT m2_qg_consent_grants_owner_pair_key
        UNIQUE (consent_id, owner_user_id),
    -- A retried POST is the same request; the database decides, not a race in
    -- the route.
    CONSTRAINT m2_qg_consent_grants_request_key
        UNIQUE (assessment_id, request_id),
    CONSTRAINT m2_qg_consent_grants_objective_kind_check
        CHECK (objective_kind IN ('MANDATORY_REGISTRY_OBJECTIVE',
                                  'ADDITIONAL_ASSESSMENT_OBJECTIVE')),
    CONSTRAINT m2_qg_consent_grants_purpose_check
        CHECK (purpose IN ('SYNTHETIC_QG_RESEARCH_EVALUATION')),
    CONSTRAINT m2_qg_consent_grants_scope_check
        CHECK (scope IN ('QG_FIXED_OPTION_CANDIDATE')),
    CONSTRAINT m2_qg_consent_grants_digest_check
        CHECK (consent_digest ~ '^[0-9a-f]{64}$'),
    CONSTRAINT m2_qg_consent_grants_prompt_sha_check
        CHECK (prompt_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT m2_qg_consent_grants_scope_shape_check
        CHECK (jsonb_typeof(disclosure_scope) = 'array'),
    -- The disclosed allowance is one attempt. A wider allowance is a new
    -- consent version with new terms, not a bigger number in a row the owner
    -- already agreed to.
    CONSTRAINT m2_qg_consent_grants_attempts_check
        CHECK (max_attempts = 1),
    CONSTRAINT m2_qg_consent_grants_expiry_check
        CHECK (expires_at > granted_at),
    CONSTRAINT m2_qg_consent_grants_revocation_pair_check
        CHECK ((revoked_at IS NULL) = (revoked_reason IS NULL))
);

-- ---------------------------------------------------------------------------
-- 2. The attempt. One row per grant, enforced by the primary key.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.m2_qg_consent_consumptions (
    consent_id       uuid PRIMARY KEY,
    owner_user_id    uuid NOT NULL,
    assessment_id    uuid NOT NULL,
    authorization_id uuid NOT NULL,
    candidate_id     uuid NULL,
    consumed_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT m2_qg_consent_consumptions_grant_fkey
        FOREIGN KEY (consent_id, owner_user_id)
        REFERENCES public.m2_qg_consent_grants (consent_id, owner_user_id)
        ON DELETE RESTRICT,
    CONSTRAINT m2_qg_consent_consumptions_authorization_key
        UNIQUE (authorization_id),
    CONSTRAINT m2_qg_consent_consumptions_authorization_fkey
        FOREIGN KEY (authorization_id)
        REFERENCES public.m2_qg_authorizations (authorization_id)
        ON DELETE RESTRICT
);

-- ---------------------------------------------------------------------------
-- 3. Guards. The database, not the caller, decides what a grant may claim.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.m2_qg_consent_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
    decided    varchar(20);
    decider    uuid;
    snap_rev   integer;
    snap_owner uuid;
    snap_digest varchar(120);
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'QG consent grants cannot be deleted'
            USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'INSERT' THEN
        -- The authority must be a genuine approval by this owner, on this
        -- confirmation. Python derives the same facts, but a principal holding
        -- INSERT could bypass Python entirely, so the check is repeated here.
        SELECT d.decision, d.decided_by
          INTO decided, decider
          FROM public.m2_bdj_objective_decisions d
         WHERE d.decision_id = NEW.objective_decision_id
           AND d.confirmation_id = NEW.confirmation_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'QG consent names objective decision % which does not '
                            'belong to confirmation %',
                            NEW.objective_decision_id, NEW.confirmation_id
                USING ERRCODE = '23503';
        END IF;

        IF decided IS DISTINCT FROM 'APPROVED' THEN
            -- A refused objective cannot authorise generation, and therefore
            -- cannot carry a consent grant either.
            RAISE EXCEPTION 'QG consent requires an APPROVED objective decision '
                            '(decision is %)', decided
                USING ERRCODE = '23514';
        END IF;

        IF decider IS DISTINCT FROM NEW.owner_user_id THEN
            RAISE EXCEPTION 'QG consent must be granted by the owner who approved '
                            'the objective'
                USING ERRCODE = '42501';
        END IF;

        SELECT s.assessment_revision, s.actor_user_id, s.snapshot_digest
          INTO snap_rev, snap_owner, snap_digest
          FROM public.m2_confirmation_snapshots s
         WHERE s.id = NEW.confirmation_id
           AND s.assessment_id = NEW.assessment_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'confirmation % does not belong to assessment %',
                            NEW.confirmation_id, NEW.assessment_id
                USING ERRCODE = '23503';
        END IF;

        IF snap_rev IS DISTINCT FROM NEW.assessment_revision THEN
            RAISE EXCEPTION 'QG consent revision % does not match confirmed revision %',
                            NEW.assessment_revision, snap_rev
                USING ERRCODE = '23514';
        END IF;

        IF snap_owner IS DISTINCT FROM NEW.owner_user_id THEN
            RAISE EXCEPTION 'QG consent owner does not own the confirmation'
                USING ERRCODE = '42501';
        END IF;

        IF snap_digest IS DISTINCT FROM NEW.bcb_digest THEN
            RAISE EXCEPTION 'QG consent BCB digest does not match confirmation %',
                            NEW.confirmation_id
                USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
    END IF;

    -- UPDATE. Binding columns are immutable; the one permitted transition is
    -- revocation, which records a withdrawal without erasing the grant.
    IF NEW.consent_id <> OLD.consent_id
       OR NEW.assessment_id <> OLD.assessment_id
       OR NEW.assessment_revision <> OLD.assessment_revision
       OR NEW.confirmation_id <> OLD.confirmation_id
       OR NEW.bcb_digest <> OLD.bcb_digest
       OR NEW.objective_decision_id <> OLD.objective_decision_id
       OR NEW.objective_kind IS DISTINCT FROM OLD.objective_kind
       OR NEW.objective_id IS DISTINCT FROM OLD.objective_id
       OR NEW.owner_user_id <> OLD.owner_user_id
       OR NEW.purpose IS DISTINCT FROM OLD.purpose
       OR NEW.scope IS DISTINCT FROM OLD.scope
       OR NEW.disclosure_purpose IS DISTINCT FROM OLD.disclosure_purpose
       OR NEW.disclosure_scope IS DISTINCT FROM OLD.disclosure_scope
       OR NEW.entire_context_packet IS DISTINCT FROM OLD.entire_context_packet
       OR NEW.contract_version IS DISTINCT FROM OLD.contract_version
       OR NEW.provider IS DISTINCT FROM OLD.provider
       OR NEW.model IS DISTINCT FROM OLD.model
       OR NEW.endpoint IS DISTINCT FROM OLD.endpoint
       OR NEW.prompt_version IS DISTINCT FROM OLD.prompt_version
       OR NEW.prompt_sha256 IS DISTINCT FROM OLD.prompt_sha256
       OR NEW.max_attempts IS DISTINCT FROM OLD.max_attempts
       OR NEW.expires_at IS DISTINCT FROM OLD.expires_at
       OR NEW.granted_at IS DISTINCT FROM OLD.granted_at
       OR NEW.request_id IS DISTINCT FROM OLD.request_id
       OR NEW.consent_digest IS DISTINCT FROM OLD.consent_digest
       OR NEW.consent_block IS DISTINCT FROM OLD.consent_block THEN
        RAISE EXCEPTION 'QG consent binding columns are immutable'
            USING ERRCODE = '55000';
    END IF;

    IF OLD.revoked_at IS NOT NULL THEN
        RAISE EXCEPTION 'QG consent already revoked' USING ERRCODE = '55000';
    END IF;

    IF NEW.revoked_at IS NULL THEN
        RAISE EXCEPTION 'The only permitted update is revocation'
            USING ERRCODE = '55000';
    END IF;

    RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS m2_qg_consent_guard_trg ON public.m2_qg_consent_grants;
CREATE TRIGGER m2_qg_consent_guard_trg
    BEFORE INSERT OR UPDATE OR DELETE ON public.m2_qg_consent_grants
    FOR EACH ROW EXECUTE FUNCTION public.m2_qg_consent_guard();

CREATE OR REPLACE FUNCTION public.m2_qg_consent_consumption_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
    grant_owner uuid;
    grant_scope varchar(64);
    grant_purpose varchar(64);
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'QG consent consumptions are append-only'
            USING ERRCODE = '55000';
    END IF;

    SELECT owner_user_id, scope, purpose
      INTO grant_owner, grant_scope, grant_purpose
      FROM public.m2_qg_consent_grants
     WHERE consent_id = NEW.consent_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'QG consent % does not exist', NEW.consent_id
            USING ERRCODE = '23503';
    END IF;

    IF grant_owner IS DISTINCT FROM NEW.owner_user_id THEN
        RAISE EXCEPTION 'QG consent consumption owner does not own the grant'
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS m2_qg_consent_consumption_guard_trg
    ON public.m2_qg_consent_consumptions;
CREATE TRIGGER m2_qg_consent_consumption_guard_trg
    BEFORE INSERT OR UPDATE OR DELETE ON public.m2_qg_consent_consumptions
    FOR EACH ROW EXECUTE FUNCTION public.m2_qg_consent_consumption_guard();

-- ---------------------------------------------------------------------------
-- 4. Owner-scoped RLS. A foreign assessment yields no grant rather than
--    another owner's permission.
-- ---------------------------------------------------------------------------
ALTER TABLE public.m2_qg_consent_grants       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.m2_qg_consent_consumptions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.m2_qg_consent_grants       FROM PUBLIC;
REVOKE ALL ON public.m2_qg_consent_consumptions FROM PUBLIC;

DROP POLICY IF EXISTS owner_scope ON public.m2_qg_consent_grants;
CREATE POLICY owner_scope ON public.m2_qg_consent_grants
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);

DROP POLICY IF EXISTS owner_scope ON public.m2_qg_consent_consumptions;
CREATE POLICY owner_scope ON public.m2_qg_consent_consumptions
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);

-- ---------------------------------------------------------------------------
-- 5. Least privilege. No DELETE anywhere. UPDATE on the grant exists only for
--    revocation; the consumption table takes INSERT and nothing else.
-- ---------------------------------------------------------------------------
DO $grant$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_m2_runtime') THEN
    GRANT SELECT, INSERT, UPDATE ON public.m2_qg_consent_grants TO p1_m2_runtime;
    GRANT SELECT, INSERT         ON public.m2_qg_consent_consumptions TO p1_m2_runtime;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1ai_engine') THEN
    GRANT SELECT ON public.m2_qg_consent_grants       TO p1ai_engine;
    GRANT SELECT ON public.m2_qg_consent_consumptions TO p1ai_engine;
  END IF;
END
$grant$;

REVOKE DELETE, TRUNCATE ON public.m2_qg_consent_grants       FROM PUBLIC;
REVOKE DELETE, TRUNCATE ON public.m2_qg_consent_consumptions FROM PUBLIC;

COMMENT ON TABLE public.m2_qg_consent_grants IS
  'Append-only QG processing permission, bound to one confirmed revision and one '
  'owner-approved objective. Separate from m2_confirmation_snapshots so granting '
  'it cannot create an M2 revision or invalidate an approved objective (DD-044).';
COMMENT ON COLUMN public.m2_qg_consent_grants.objective_id IS
  'The objective identity recorded by the policy layer (registry id or proposal:{uuid}). '
  'Agreement with derive_objective_authority() is checked in Python; it is not a SQL fact.';
COMMENT ON COLUMN public.m2_qg_consent_grants.bcb_digest IS
  'snapshot_digest of the confirmation relied on, so the grant names specific content.';
COMMENT ON COLUMN public.m2_qg_consent_grants.max_attempts IS
  'The disclosed allowance. Pinned to 1: a wider allowance is a new consent version.';
COMMENT ON TABLE public.m2_qg_consent_consumptions IS
  'The single attempt a grant authorises. consent_id is the primary key, so the '
  'database permits at most one consumption per grant.';

COMMIT;
