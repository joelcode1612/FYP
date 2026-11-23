-- PROJECT1 Phase 3B/4A: controlled measurement specifications, per-assessment
-- QG authorization, and persisted fixed-option QG candidates.
-- Migration: 20261122_0600_measurement_and_qg_candidate
-- Target: disposable cluster only. Never applied to Dss / Final_Location_Analysis.
--
-- WHY THIS EXISTS
-- ---------------
-- Three capabilities in the Phase 3A/3B/4A directive have no storage at all on
-- the disposable cluster:
--
--   1. A *measurement specification* — the versioned object that says which
--      construct, population, stimulus slots, response format and denominator a
--      fieldable question must use. `project1_qgb` (20261118_01_question_bank)
--      is a QUESTION authority: it stores item versions and independent
--      reviewer/approver lifecycle events for questions that already exist. It
--      is not a measurement specification and it is not provisioned here. A
--      measurement spec is the input to question generation, so it is a
--      different object rather than a duplicate registry.
--
--   2. A per-assessment QG authorization row. The owner decision (OD-18) is
--      explicit: authorization is a DB row scoped to one assessment, one
--      confirmed revision, one source fingerprint, one objective and one
--      measurement version — not a global flag file.
--
--   3. Persisted candidate versions. The directive requires a generated
--      candidate to survive as a reviewable, versioned object with its
--      provenance and its separate structural / semantic / provenance
--      dispositions.
--
-- WHAT THIS IS NOT
-- ----------------
--   * Not an approval. No row here can mark a measurement scientifically
--     approved without a decision row from a SCIENTIFIC_REVIEWER at
--     PRODUCTION scope, and none exists. Coverage therefore stays 0/6.
--   * Not a fielding right. `m2_qg_candidates` carries no publication or
--     fielding column at all, so a candidate cannot be read as a released
--     question.
--   * Not a bypass. The unconditional production hold
--     (`QG_FIXED_OPTION_ADMISSION_UNAVAILABLE`) is a code path, not a table
--     flag; nothing here removes it.
--
-- APPEND-ONLY DISCIPLINE
-- ----------------------
--   specs, decisions and candidates are append-only (UPDATE/DELETE refused by
--   trigger). Authorizations permit exactly one transition — setting
--   `consumed_at`/`consumed_candidate_id` once — enforced by trigger so the
--   binding columns can never be rewritten after issue.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $guard$
BEGIN
  IF current_database() IN ('Dss', 'dss', 'Final_Location_Analysis', 'sitesense', 'postgres') THEN
    RAISE EXCEPTION 'Refusing to add measurement/QG tables on protected database %',
      current_database();
  END IF;
  IF inet_server_port() = 5432 THEN
    RAISE EXCEPTION 'Refusing to add measurement/QG tables on the protected cluster (port 5432, database %)',
      current_database();
  END IF;
  IF current_database() NOT LIKE 'project1\_%' THEN
    RAISE EXCEPTION 'Unexpected target %: expected a project1_ disposable database on a non-5432 port',
      current_database();
  END IF;
  IF to_regclass('public.m2_bdj_objective_admissions') IS NULL THEN
    RAISE EXCEPTION 'm2_bdj_objective_admissions required (apply 20261122_0400 first)';
  END IF;
END
$guard$;

-- ---------------------------------------------------------------------------
-- 1. Versioned measurement specification.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.m2_measurement_specs (
    measurement_id      varchar(64)  NOT NULL,
    measurement_version varchar(32)  NOT NULL,
    -- The fixed objective this measurement is intended to answer.
    objective_id        varchar(8)   NOT NULL
        CHECK (objective_id IN ('O1','O2','O3','O4','O5','O6')),
    construct           varchar(500) NOT NULL CHECK (length(btrim(construct)) > 0),
    population          varchar(500) NOT NULL CHECK (length(btrim(population)) > 0),
    -- DRAFT / CANDIDATE_REVIEW / APPROVED / RETIRED / SUPERSEDED.
    -- APPROVED is only ever *derived* on read from m2_measurement_decisions;
    -- this column records the declared lifecycle, never a self-granted right.
    status              varchar(24)  NOT NULL
        CHECK (status IN ('DRAFT','CANDIDATE_REVIEW','APPROVED','RETIRED','SUPERSEDED')),
    response_format     varchar(32)  NOT NULL
        CHECK (response_format IN ('SINGLE_CHOICE','BINARY_CHOICE','MULTIPLE_CHOICE',
                                   'ORDERED_SCALE','NUMERIC_RANGE_OPTIONS')),
    allowed_parameter_names text[]   NOT NULL DEFAULT '{}',
    spec_json           jsonb        NOT NULL,
    -- SHA-256 over canonical(spec_json). A later reader can prove the spec was
    -- not substituted under the same version label.
    content_digest      char(64)     NOT NULL CHECK (content_digest ~ '^[a-f0-9]{64}$'),
    owner_user_id       uuid         NOT NULL,
    created_at          timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT pk_measurement_spec PRIMARY KEY (measurement_id, measurement_version)
);

COMMENT ON TABLE public.m2_measurement_specs IS
  'Versioned measurement specification (construct, population, stimulus slots, '
  'response format, denominator). Candidate specifications may be authored; only '
  'an independent SCIENTIFIC_REVIEWER decision at PRODUCTION scope makes one '
  'fieldable, and none exists.';

CREATE TABLE IF NOT EXISTS public.m2_measurement_decisions (
    decision_id         uuid         PRIMARY KEY,
    measurement_id      varchar(64)  NOT NULL,
    measurement_version varchar(32)  NOT NULL,
    decision            varchar(16)  NOT NULL
        CHECK (decision IN ('APPROVE','REJECT','RETIRE')),
    -- Independent review and owner approval are different authorities; a single
    -- actor may not satisfy both for the same measurement.
    authority           varchar(24)  NOT NULL
        CHECK (authority IN ('SCIENTIFIC_REVIEWER','OWNER_APPROVER')),
    actor_user_id       uuid         NOT NULL,
    scope               varchar(16)  NOT NULL
        CHECK (scope IN ('SYNTHETIC_TEST','PRODUCTION')),
    content_digest      char(64)     NOT NULL CHECK (content_digest ~ '^[a-f0-9]{64}$'),
    rationale           varchar(1000) NOT NULL CHECK (length(btrim(rationale)) > 0),
    decided_at          timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT fk_measurement_decision_spec
        FOREIGN KEY (measurement_id, measurement_version)
        REFERENCES public.m2_measurement_specs (measurement_id, measurement_version)
);

COMMENT ON TABLE public.m2_measurement_decisions IS
  'Append-only measurement lifecycle decisions. A PRODUCTION APPROVE from a '
  'SCIENTIFIC_REVIEWER is the only thing that can make a measurement fieldable. '
  'SYNTHETIC_TEST decisions never raise the approved coverage count.';

CREATE INDEX IF NOT EXISTS ix_measurement_specs_objective
    ON public.m2_measurement_specs (objective_id, status);
CREATE INDEX IF NOT EXISTS ix_measurement_decisions_measure
    ON public.m2_measurement_decisions (measurement_id, measurement_version, decided_at);

-- ---------------------------------------------------------------------------
-- 2. Per-assessment QG authorization (owner decision OD-18).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.m2_qg_authorizations (
    authorization_id    uuid         PRIMARY KEY,
    assessment_id       uuid         NOT NULL,
    confirmation_id     uuid         NOT NULL,
    assessment_revision integer      NOT NULL CHECK (assessment_revision >= 0),
    source_fingerprint  char(64)     NOT NULL CHECK (source_fingerprint ~ '^[a-f0-9]{64}$'),
    context_id          uuid         NOT NULL,
    context_packet_hash char(64)     NOT NULL CHECK (context_packet_hash ~ '^[a-f0-9]{64}$'),
    objective_id        varchar(64)  NOT NULL CHECK (length(btrim(objective_id)) > 0),
    -- The admission this authorization depends on. Never a bare objective id:
    -- an authorization that cannot name its admission cannot be checked.
    objective_admission_id uuid      NOT NULL
        REFERENCES public.m2_bdj_objective_admissions (admission_id),
    measurement_id      varchar(64)  NOT NULL,
    measurement_version varchar(32)  NOT NULL,
    prompt_version      varchar(64)  NOT NULL,
    prompt_sha256       char(64)     NOT NULL CHECK (prompt_sha256 ~ '^[a-f0-9]{64}$'),
    issued_by           uuid         NOT NULL,
    issued_at           timestamptz  NOT NULL DEFAULT now(),
    expires_at          timestamptz  NOT NULL,
    consumed_at         timestamptz,
    consumed_candidate_id uuid,
    request_id          uuid         NOT NULL,
    CONSTRAINT ck_qg_auth_expiry CHECK (expires_at > issued_at),
    CONSTRAINT uq_qg_auth_request UNIQUE (assessment_id, request_id)
);

COMMENT ON TABLE public.m2_qg_authorizations IS
  'Exact-bound, per-assessment QG authorization: one assessment, one confirmed '
  'revision, one source fingerprint, one context, one admitted objective, one '
  'measurement version, one prompt hash. Single use. This is an owner decision '
  'to spend one generation attempt, NOT scientific approval and NOT fielding '
  'authorization.';

CREATE INDEX IF NOT EXISTS ix_qg_auth_binding
    ON public.m2_qg_authorizations
       (assessment_id, objective_id, measurement_id, measurement_version,
        source_fingerprint, prompt_version);

-- ---------------------------------------------------------------------------
-- 3. Persisted fixed-option QG candidate.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.m2_qg_candidates (
    candidate_id        uuid         PRIMARY KEY,
    assessment_id       uuid         NOT NULL,
    confirmation_id     uuid         NOT NULL,
    assessment_revision integer      NOT NULL CHECK (assessment_revision >= 0),
    source_fingerprint  char(64)     NOT NULL CHECK (source_fingerprint ~ '^[a-f0-9]{64}$'),
    context_id          uuid         NOT NULL,
    context_packet_hash char(64)     NOT NULL CHECK (context_packet_hash ~ '^[a-f0-9]{64}$'),
    objective_id        varchar(64)  NOT NULL,
    objective_admission_id uuid      NOT NULL
        REFERENCES public.m2_bdj_objective_admissions (admission_id),
    measurement_id      varchar(64)  NOT NULL,
    measurement_version varchar(32)  NOT NULL,
    qg_authorization_id uuid         NOT NULL
        REFERENCES public.m2_qg_authorizations (authorization_id),
    -- Ledger correlation. Nullable only because a deterministic (non-provider)
    -- candidate has no attempt; a provider-dispatched candidate must carry one.
    run_id              uuid,
    attempt_no          integer,
    prompt_version      varchar(64)  NOT NULL,
    prompt_sha256       char(64)     NOT NULL CHECK (prompt_sha256 ~ '^[a-f0-9]{64}$'),
    request_sha256      char(64)     NOT NULL CHECK (request_sha256 ~ '^[a-f0-9]{64}$'),
    output_sha256       char(64)     NOT NULL CHECK (output_sha256 ~ '^[a-f0-9]{64}$'),
    execution_mode      varchar(16)  NOT NULL
        CHECK (execution_mode IN ('LIVE','SIMULATED','DETERMINISTIC')),
    model_provider      varchar(64),
    model_requested     varchar(64),
    model_returned      varchar(64),
    response_format     varchar(32)  NOT NULL
        CHECK (response_format IN ('SINGLE_CHOICE','BINARY_CHOICE','MULTIPLE_CHOICE',
                                   'ORDERED_SCALE','NUMERIC_RANGE_OPTIONS')),
    -- Candidate lifecycle: GENERATED / STRUCTURALLY_VALID / VALIDATED /
    -- INVALID / ABSTAINED / UNDER_REVIEW / APPROVED / REJECTED / SUPERSEDED.
    candidate_state     varchar(24)  NOT NULL
        CHECK (candidate_state IN ('GENERATED','STRUCTURALLY_VALID','VALIDATED',
                                   'INVALID','ABSTAINED','UNDER_REVIEW',
                                   'APPROVED','REJECTED','SUPERSEDED')),
    structural_status   varchar(24)  NOT NULL,
    semantic_status     varchar(24)  NOT NULL,
    provenance_status   varchar(24)  NOT NULL,
    contract_version    varchar(64)  NOT NULL,
    adapter_version     varchar(64)  NOT NULL,
    candidate_json      jsonb        NOT NULL,
    owner_user_id       uuid         NOT NULL,
    created_at          timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.m2_qg_candidates IS
  'Append-only persisted QG candidate versions with separate structural, '
  'semantic and provenance dispositions. APPROVED here means the owner accepted '
  'a candidate for further review; it does not mean fielded, published or '
  'statistically validated.';

CREATE INDEX IF NOT EXISTS ix_qg_candidates_assessment
    ON public.m2_qg_candidates (assessment_id, objective_id, created_at);
CREATE INDEX IF NOT EXISTS ix_qg_candidates_authorization
    ON public.m2_qg_candidates (qg_authorization_id);

-- ---------------------------------------------------------------------------
-- 4. Append-only enforcement.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.m2_phase3b_reject_mutation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Table % is append-only', TG_TABLE_NAME USING ERRCODE = '55000';
END $$;

DROP TRIGGER IF EXISTS m2_measurement_specs_append_only ON public.m2_measurement_specs;
CREATE TRIGGER m2_measurement_specs_append_only
    BEFORE UPDATE OR DELETE ON public.m2_measurement_specs
    FOR EACH ROW EXECUTE FUNCTION public.m2_phase3b_reject_mutation();

DROP TRIGGER IF EXISTS m2_measurement_decisions_append_only ON public.m2_measurement_decisions;
CREATE TRIGGER m2_measurement_decisions_append_only
    BEFORE UPDATE OR DELETE ON public.m2_measurement_decisions
    FOR EACH ROW EXECUTE FUNCTION public.m2_phase3b_reject_mutation();

DROP TRIGGER IF EXISTS m2_qg_candidates_append_only ON public.m2_qg_candidates;
CREATE TRIGGER m2_qg_candidates_append_only
    BEFORE UPDATE OR DELETE ON public.m2_qg_candidates
    FOR EACH ROW EXECUTE FUNCTION public.m2_phase3b_reject_mutation();

-- An authorization permits exactly one transition: consumption. Every binding
-- column is frozen, and the transition is one-way.
CREATE OR REPLACE FUNCTION public.m2_qg_authorization_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'QG authorizations cannot be deleted' USING ERRCODE = '55000';
  END IF;
  IF NEW.authorization_id <> OLD.authorization_id
     OR NEW.assessment_id <> OLD.assessment_id
     OR NEW.confirmation_id <> OLD.confirmation_id
     OR NEW.assessment_revision <> OLD.assessment_revision
     OR NEW.source_fingerprint <> OLD.source_fingerprint
     OR NEW.context_id <> OLD.context_id
     OR NEW.context_packet_hash <> OLD.context_packet_hash
     OR NEW.objective_id <> OLD.objective_id
     OR NEW.objective_admission_id <> OLD.objective_admission_id
     OR NEW.measurement_id <> OLD.measurement_id
     OR NEW.measurement_version <> OLD.measurement_version
     OR NEW.prompt_version <> OLD.prompt_version
     OR NEW.prompt_sha256 <> OLD.prompt_sha256
     OR NEW.issued_at <> OLD.issued_at
     OR NEW.expires_at <> OLD.expires_at THEN
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
END $$;

DROP TRIGGER IF EXISTS m2_qg_authorization_guard_trg ON public.m2_qg_authorizations;
CREATE TRIGGER m2_qg_authorization_guard_trg
    BEFORE UPDATE OR DELETE ON public.m2_qg_authorizations
    FOR EACH ROW EXECUTE FUNCTION public.m2_qg_authorization_guard();

-- ---------------------------------------------------------------------------
-- 5. Owner-scoped RLS. Every table is scoped to the acting owner, and the
--    spec/decision tables additionally require the spec's own owner.
-- ---------------------------------------------------------------------------
ALTER TABLE public.m2_measurement_specs      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.m2_measurement_decisions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.m2_qg_authorizations      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.m2_qg_candidates          ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.m2_measurement_specs     FROM PUBLIC;
REVOKE ALL ON public.m2_measurement_decisions FROM PUBLIC;
REVOKE ALL ON public.m2_qg_authorizations     FROM PUBLIC;
REVOKE ALL ON public.m2_qg_candidates         FROM PUBLIC;

DROP POLICY IF EXISTS owner_scope ON public.m2_measurement_specs;
CREATE POLICY owner_scope ON public.m2_measurement_specs
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);

DROP POLICY IF EXISTS owner_scope ON public.m2_measurement_decisions;
CREATE POLICY owner_scope ON public.m2_measurement_decisions
  USING (actor_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (actor_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);

DROP POLICY IF EXISTS owner_scope ON public.m2_qg_authorizations;
CREATE POLICY owner_scope ON public.m2_qg_authorizations
  USING (issued_by = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (issued_by = nullif(current_setting('project1.actor_id', true), '')::uuid);

DROP POLICY IF EXISTS owner_scope ON public.m2_qg_candidates;
CREATE POLICY owner_scope ON public.m2_qg_candidates
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);

-- ---------------------------------------------------------------------------
-- 6. Least-privilege grants. No DELETE anywhere; no UPDATE except the single
--    controlled authorization transition.
-- ---------------------------------------------------------------------------
DO $grant$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_m2_runtime') THEN
    GRANT SELECT, INSERT ON public.m2_measurement_specs     TO p1_m2_runtime;
    GRANT SELECT, INSERT ON public.m2_measurement_decisions TO p1_m2_runtime;
    GRANT SELECT, INSERT, UPDATE ON public.m2_qg_authorizations TO p1_m2_runtime;
    GRANT SELECT, INSERT ON public.m2_qg_candidates         TO p1_m2_runtime;
  END IF;
END
$grant$;

REVOKE DELETE, TRUNCATE ON public.m2_measurement_specs     FROM PUBLIC;
REVOKE DELETE, TRUNCATE ON public.m2_measurement_decisions FROM PUBLIC;
REVOKE DELETE, TRUNCATE ON public.m2_qg_authorizations     FROM PUBLIC;
REVOKE DELETE, TRUNCATE ON public.m2_qg_candidates         FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 7. Post-conditions.
-- ---------------------------------------------------------------------------
DO $post$
DECLARE missing text := '';
BEGIN
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.m2_measurement_specs'::regclass) THEN
    missing := missing || ' specs:rls';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.m2_qg_authorizations'::regclass) THEN
    missing := missing || ' auth:rls';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.m2_qg_candidates'::regclass) THEN
    missing := missing || ' candidates:rls';
  END IF;
  IF (SELECT count(*) FROM pg_trigger
      WHERE tgname IN ('m2_measurement_specs_append_only',
                       'm2_measurement_decisions_append_only',
                       'm2_qg_candidates_append_only',
                       'm2_qg_authorization_guard_trg')) <> 4 THEN
    missing := missing || ' triggers';
  END IF;
  IF (SELECT count(*) FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename IN ('m2_measurement_specs','m2_measurement_decisions',
                          'm2_qg_authorizations','m2_qg_candidates')
        AND policyname = 'owner_scope') <> 4 THEN
    missing := missing || ' policies:owner_scope';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_m2_runtime') THEN
    IF has_table_privilege('p1_m2_runtime','public.m2_qg_candidates','DELETE') THEN
      missing := missing || ' candidates:unexpected-delete';
    END IF;
    IF NOT has_table_privilege('p1_m2_runtime','public.m2_qg_candidates','INSERT') THEN
      missing := missing || ' candidates:missing-insert';
    END IF;
  END IF;
  IF missing <> '' THEN
    RAISE EXCEPTION 'POSTCONDITION_FAILED:%', missing;
  END IF;
END
$post$;

COMMIT;
