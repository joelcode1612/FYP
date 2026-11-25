-- Direct-QG 2.1: the objective-authority relationship (DD-043 / DD-040 / DD-041).
--
-- The defect this closes
-- ----------------------
-- A QG candidate and its single-use authorization both require an
-- ``objective_admission_id`` that is NOT NULL with a foreign key to
-- public.m2_bdj_objective_admissions. Contract 2.1 derives the confirmed-
-- objective relationship from the owner's **approval** instead
-- (sitewise.project1.qg_generation_eligibility.derive_objective_authority), so
-- that column has no value to carry. Three consequences followed: the LIVE
-- route could only answer QG_BINDING_ADMISSION_NOT_FOUND, qg_authorization.issue()
-- could not be called at all, and Stage 5's admitted_objective_count could never
-- rise without the manual admission the owner directive prohibits.
--
-- Why no new table
-- ----------------
-- public.m2_bdj_objective_decisions already *is* a version-bound authority
-- relationship, and an immutable one:
--
--   decision_id          PRIMARY KEY
--   proposal_id          FOREIGN KEY -> m2_bdj_objective_proposals, UNIQUE
--                        (uq_bdj_proposal_decision: one authority per objective)
--   decision             CHECK IN ('APPROVED','REJECTED')
--   decided_by           NOT NULL  -- the entrepreneur
--   decided_at           NOT NULL
--   confirmation_id      NOT NULL  -- revision binding
--   source_fingerprint   NOT NULL  -- source binding
--   context_packet_hash  NOT NULL  -- BCB binding
--
-- It carries every field an admission row duplicated, is unique per objective,
-- and is owned by the person whose approval it records. A separate
-- m2_qg_objective_authorities table would have copied those columns and created
-- a second thing that can drift. So the relationship is expressed as a foreign
-- key to the decision row, and ``decision = 'APPROVED'`` is the authority
-- predicate.
--
-- What this adds
-- --------------
--   objective_decision_id  uuid NULL, FK (objective_decision_id, confirmation_id)
--                          -> m2_bdj_objective_decisions(decision_id, confirmation_id)
--   objective_kind         varchar(40) NULL -- MANDATORY_REGISTRY_OBJECTIVE |
--                                             ADDITIONAL_ASSESSMENT_OBJECTIVE
--   measurement_basis      varchar(32) NULL -- APPROVED_SPECIFICATION |
--                                             PROPOSED_NOT_CONFIRMED
--
-- The foreign key is composite on purpose. Referencing decision_id alone would
-- accept a decision recorded against revision 19 on a candidate that claims
-- revision 24, which is precisely the staleness the derivation refuses in code
-- (QG_OBJECTIVE_REVISION_STALE). Binding the pair makes revision binding a
-- database property rather than a property of one careful caller. Source
-- fingerprint and context-packet binding stay enforced by
-- derive_objective_authority, which names each failure separately
-- (QG_OBJECTIVE_DECISION_BINDING_DRIFT, QG_OBJECTIVE_CONTEXT_NOT_CURRENT) --
-- a reader needs to know *which* binding drifted, and a single FK violation
-- could not say.
--
-- and relaxes three legacy NOT NULLs whose value a 2.1 attempt legitimately does
-- not have:
--
--   objective_admission_id  (both tables)
--   measurement_id          (both tables)
--   measurement_version     (both tables)
--
-- Integrity is not removed with the NOT NULLs. It is replaced by constraints
-- that say what must be true instead of which legacy row must exist:
--
--   *_authority_present          an admission OR a decision, never neither
--   *_authority_declared         a decision-backed row must declare kind + basis
--   *_measurement_basis_check    a proposed basis cannot accompany an approved id
--
-- Historical compatibility
-- ------------------------
-- Every pre-existing row keeps its admission id and its measurement id and is
-- left completely untouched: the new columns stay NULL, which is exactly the
-- "authority not recorded under this contract" state. No row is rewritten and no
-- value is invented. ``objective_kind``/``measurement_basis`` are deliberately
-- NULL for those rows rather than backfilled, because the contract that would
-- have recorded them did not exist when the rows were written.
--
-- Rollback: 20261124_05_objective_authority_rollback.sql
-- Additive apart from three DROP NOT NULL, all of which the rollback restores.
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
    RAISE EXCEPTION 'Refusing to apply the objective-authority relationship to protected database %',
                    current_database();
  END IF;

  IF to_regclass('public.m2_qg_candidates') IS NULL
     OR to_regclass('public.m2_qg_authorizations') IS NULL
     OR to_regclass('public.m2_bdj_objective_decisions') IS NULL THEN
    RAISE EXCEPTION 'm2_qg_candidates, m2_qg_authorizations and '
                    'm2_bdj_objective_decisions are all required';
  END IF;
END
$guard$;

-- 1. The authority relationship itself, on both tables that need it.
ALTER TABLE public.m2_qg_candidates
    ADD COLUMN IF NOT EXISTS objective_decision_id uuid NULL,
    ADD COLUMN IF NOT EXISTS objective_kind varchar(40) NULL,
    ADD COLUMN IF NOT EXISTS measurement_basis varchar(32) NULL;

ALTER TABLE public.m2_qg_authorizations
    ADD COLUMN IF NOT EXISTS objective_decision_id uuid NULL,
    ADD COLUMN IF NOT EXISTS objective_kind varchar(40) NULL,
    ADD COLUMN IF NOT EXISTS measurement_basis varchar(32) NULL;

-- 1b. Bind the authority to the revision it approved, not merely to a decision
--     id. A single-column FK would accept a decision made about revision 19 on a
--     candidate that claims revision 24; the composite key refuses it. The
--     referenced pair is unique because decision_id is the primary key, so the
--     index is redundant in the strict sense and exists only to be referenceable.
DO $fk$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.m2_bdj_objective_decisions'::regclass
                   AND conname = 'uq_bdj_decision_confirmation') THEN
    ALTER TABLE public.m2_bdj_objective_decisions
      ADD CONSTRAINT uq_bdj_decision_confirmation
      UNIQUE (decision_id, confirmation_id);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.m2_qg_candidates'::regclass
                   AND conname = 'm2_qg_candidates_objective_decision_fkey') THEN
    ALTER TABLE public.m2_qg_candidates
      ADD CONSTRAINT m2_qg_candidates_objective_decision_fkey
      FOREIGN KEY (objective_decision_id, confirmation_id)
      REFERENCES public.m2_bdj_objective_decisions (decision_id, confirmation_id);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.m2_qg_authorizations'::regclass
                   AND conname = 'm2_qg_authorizations_objective_decision_fkey') THEN
    ALTER TABLE public.m2_qg_authorizations
      ADD CONSTRAINT m2_qg_authorizations_objective_decision_fkey
      FOREIGN KEY (objective_decision_id, confirmation_id)
      REFERENCES public.m2_bdj_objective_decisions (decision_id, confirmation_id);
  END IF;
END
$fk$;

-- 2. Relax the legacy NOT NULLs. The replacement constraints are added below in
--    the same transaction, so there is no window in which a row can carry
--    neither authority.
ALTER TABLE public.m2_qg_candidates
    ALTER COLUMN objective_admission_id DROP NOT NULL,
    ALTER COLUMN measurement_id DROP NOT NULL,
    ALTER COLUMN measurement_version DROP NOT NULL;

ALTER TABLE public.m2_qg_authorizations
    ALTER COLUMN objective_admission_id DROP NOT NULL,
    ALTER COLUMN measurement_id DROP NOT NULL,
    ALTER COLUMN measurement_version DROP NOT NULL;

DO $constraints$
DECLARE
  tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['m2_qg_candidates', 'm2_qg_authorizations'] LOOP
    -- An authority must exist. Either the legacy admission row or the decision
    -- row it is derived from; "neither" is the state this migration exists to
    -- make impossible.
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = ('public.' || tbl)::regclass
                     AND conname = tbl || '_authority_present') THEN
      EXECUTE format(
        'ALTER TABLE public.%I ADD CONSTRAINT %I CHECK '
        '(objective_admission_id IS NOT NULL OR objective_decision_id IS NOT NULL)',
        tbl, tbl || '_authority_present');
    END IF;

    -- A decision-backed row must declare what it is and on what measurement
    -- basis, so a reader can never mistake a proposal for an approval.
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = ('public.' || tbl)::regclass
                     AND conname = tbl || '_authority_declared') THEN
      EXECUTE format(
        'ALTER TABLE public.%I ADD CONSTRAINT %I CHECK '
        '(objective_decision_id IS NULL OR '
        ' (objective_kind IS NOT NULL AND measurement_basis IS NOT NULL))',
        tbl, tbl || '_authority_declared');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = ('public.' || tbl)::regclass
                     AND conname = tbl || '_objective_kind_check') THEN
      EXECUTE format(
        'ALTER TABLE public.%I ADD CONSTRAINT %I CHECK '
        '(objective_kind IS NULL OR objective_kind IN '
        '(''MANDATORY_REGISTRY_OBJECTIVE'', ''ADDITIONAL_ASSESSMENT_OBJECTIVE''))',
        tbl, tbl || '_objective_kind_check');
    END IF;

    -- A proposed basis can never sit beside an approved measurement id, and an
    -- approved id can never be labelled proposed. This is the constraint that
    -- keeps "generation does not require scientific approval" from quietly
    -- becoming "generation claims scientific approval".
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = ('public.' || tbl)::regclass
                     AND conname = tbl || '_measurement_basis_check') THEN
      EXECUTE format(
        'ALTER TABLE public.%I ADD CONSTRAINT %I CHECK '
        '(measurement_basis IS NULL OR '
        ' ((measurement_id IS NOT NULL) = '
        '  (measurement_basis = ''APPROVED_SPECIFICATION'')))',
        tbl, tbl || '_measurement_basis_check');
    END IF;
  END LOOP;
END
$constraints$;

-- 3. The authorization guard must treat the new binding column as immutable,
--    and must compare the now-nullable legacy columns with IS DISTINCT FROM so a
--    NULL -> value rewrite cannot slip past a NULL comparison.
CREATE OR REPLACE FUNCTION public.m2_qg_authorization_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'QG authorizations cannot be deleted' USING ERRCODE = '55000';
  END IF;
  IF NEW.authorization_id IS DISTINCT FROM OLD.authorization_id
     OR NEW.assessment_id IS DISTINCT FROM OLD.assessment_id
     OR NEW.confirmation_id IS DISTINCT FROM OLD.confirmation_id
     OR NEW.assessment_revision IS DISTINCT FROM OLD.assessment_revision
     OR NEW.source_fingerprint IS DISTINCT FROM OLD.source_fingerprint
     OR NEW.context_id IS DISTINCT FROM OLD.context_id
     OR NEW.context_packet_hash IS DISTINCT FROM OLD.context_packet_hash
     OR NEW.objective_id IS DISTINCT FROM OLD.objective_id
     OR NEW.objective_admission_id IS DISTINCT FROM OLD.objective_admission_id
     OR NEW.measurement_id IS DISTINCT FROM OLD.measurement_id
     OR NEW.measurement_version IS DISTINCT FROM OLD.measurement_version
     OR NEW.prompt_version IS DISTINCT FROM OLD.prompt_version
     OR NEW.prompt_sha256 IS DISTINCT FROM OLD.prompt_sha256
     OR NEW.issued_at IS DISTINCT FROM OLD.issued_at
     OR NEW.expires_at IS DISTINCT FROM OLD.expires_at
     OR NEW.purpose IS DISTINCT FROM OLD.purpose
     OR NEW.scope IS DISTINCT FROM OLD.scope
     OR NEW.consent_version IS DISTINCT FROM OLD.consent_version
     OR NEW.consent_digest IS DISTINCT FROM OLD.consent_digest
     -- Added by 20261124_05. Without these a caller could re-point a live
     -- authorization at a different approval, which is the defect this
     -- migration exists to close.
     OR NEW.objective_decision_id IS DISTINCT FROM OLD.objective_decision_id
     OR NEW.objective_kind IS DISTINCT FROM OLD.objective_kind
     OR NEW.measurement_basis IS DISTINCT FROM OLD.measurement_basis THEN
    RAISE EXCEPTION 'QG authorization binding columns are immutable'
      USING ERRCODE = '55000';
  END IF;
  IF OLD.consumed_at IS NOT NULL THEN
    RAISE EXCEPTION 'QG authorization already consumed' USING ERRCODE = '55000';
  END IF;
  IF NEW.consumed_at IS NULL THEN
    RAISE EXCEPTION 'The only permitted update is consumption' USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END
$function$;

-- 4. A foreign key proves the decision exists. It does not prove the decision
--    is an approval, and it does not prove it is *this owner's* approval. Both
--    gaps matter:
--
--      * citing a REJECTED decision would satisfy *_authority_present while
--        authorising generation the owner explicitly refused;
--      * referential-integrity checks bypass RLS, so the FK alone would let a
--        runtime bind a candidate to another entrepreneur's decision.
--
--    derive_objective_authority already refuses both in code
--    (QG_OBJECTIVE_DECISION_NOT_APPROVED, QG_OBJECTIVE_DECIDED_BY_OTHER). This
--    makes them properties of the table rather than of one careful caller.
--
--    SECURITY DEFINER is deliberate: the lookup must be able to distinguish
--    "no such decision" from "somebody else's decision", and under the caller's
--    own RLS view both look like zero rows. The function reads one row by
--    primary key and raises; it writes nothing.
CREATE OR REPLACE FUNCTION public.m2_qg_objective_authority_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  row_owner  uuid;
  decision   text;
  decided_by uuid;
BEGIN
  IF NEW.objective_decision_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'm2_qg_candidates' THEN
    row_owner := NEW.owner_user_id;
  ELSE
    row_owner := NEW.issued_by;
  END IF;

  SELECT d.decision, d.decided_by
    INTO decision, decided_by
    FROM public.m2_bdj_objective_decisions d
   WHERE d.decision_id = NEW.objective_decision_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'objective_decision_id % does not name a decision',
                    NEW.objective_decision_id USING ERRCODE = '23503';
  END IF;
  IF decision IS DISTINCT FROM 'APPROVED' THEN
    RAISE EXCEPTION 'objective decision % is %, not APPROVED: a refused '
                    'objective cannot authorise generation',
                    NEW.objective_decision_id, decision USING ERRCODE = '23514';
  END IF;
  IF decided_by IS DISTINCT FROM row_owner THEN
    RAISE EXCEPTION 'objective decision % was made by another owner; an '
                    'approval authorises only the person who gave it',
                    NEW.objective_decision_id USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END
$function$;

DO $trg$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.m2_qg_candidates'::regclass
                   AND tgname = 'm2_qg_candidates_authority_guard') THEN
    CREATE TRIGGER m2_qg_candidates_authority_guard
      BEFORE INSERT ON public.m2_qg_candidates
      FOR EACH ROW EXECUTE FUNCTION public.m2_qg_objective_authority_guard();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.m2_qg_authorizations'::regclass
                   AND tgname = 'm2_qg_authorizations_authority_guard') THEN
    CREATE TRIGGER m2_qg_authorizations_authority_guard
      BEFORE INSERT ON public.m2_qg_authorizations
      FOR EACH ROW EXECUTE FUNCTION public.m2_qg_objective_authority_guard();
  END IF;
END
$trg$;

COMMENT ON COLUMN public.m2_qg_candidates.objective_decision_id IS
  'The immutable owner decision that authorises generation for this candidate. '
  'Exactly one of this and objective_admission_id is present.';
COMMENT ON COLUMN public.m2_qg_authorizations.objective_decision_id IS
  'The immutable owner decision this authorization was issued against.';
COMMENT ON COLUMN public.m2_qg_candidates.objective_kind IS
  'MANDATORY_REGISTRY_OBJECTIVE or ADDITIONAL_ASSESSMENT_OBJECTIVE. NULL only '
  'for rows written before contract 2.1, where it was never recorded.';
COMMENT ON COLUMN public.m2_qg_candidates.measurement_basis IS
  'PROPOSED_NOT_CONFIRMED means generation ran without a scientifically '
  'approved specification. It never means the measurement was approved.';

COMMIT;
