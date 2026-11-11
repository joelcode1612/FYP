-- REVIEW CANDIDATE, EXPLICIT OPERATOR EXECUTION ONLY. Never run at startup.
-- Requires a reviewed target and receipt, e.g. SET project1.migration_target='Dss';
-- SET project1.migration_receipt='<actual reviewed change record>';
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';
DO $$
BEGIN
  IF current_database() NOT IN ('Dss', 'project1_workflow_tests')
     OR current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
     OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
    RAISE EXCEPTION 'Explicit reviewed database identity and receipt required';
  END IF;
  IF to_regclass('public.m2_assessments') IS NULL THEN
    RAISE EXCEPTION 'Existing M2 authority required; no cross-database mirror created';
  END IF;
  IF EXISTS (SELECT FROM pg_namespace WHERE nspname='project1_ai') THEN
    RAISE EXCEPTION 'project1_ai exists: reconcile version before migrating';
  END IF;
  IF EXISTS (SELECT FROM pg_roles WHERE rolname IN ('p1ai_owner','p1ai_runtime','p1ai_audit')) THEN
    RAISE EXCEPTION 'Workflow role already exists: reconcile grants before migrating';
  END IF;
END $$;
CREATE ROLE p1ai_owner NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
-- DBA provisions a secret/login separately. Never grant this role to the LLM.
CREATE ROLE p1ai_runtime NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
CREATE ROLE p1ai_audit NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
CREATE SCHEMA project1_ai AUTHORIZATION p1ai_owner;
REVOKE ALL ON SCHEMA project1_ai FROM PUBLIC;
CREATE TABLE project1_ai.schema_versions (
  version text PRIMARY KEY, receipt text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO project1_ai.schema_versions(version,receipt)
VALUES ('20261111_01_candidate',current_setting('project1.migration_receipt'));
CREATE TABLE project1_ai.runs (
  id uuid PRIMARY KEY, owner_user_id uuid NOT NULL,
  assessment_id uuid NOT NULL REFERENCES public.m2_assessments(id),
  assessment_revision integer NOT NULL CHECK (assessment_revision>=0),
  source_fingerprint text NOT NULL CHECK (source_fingerprint ~ '^[a-f0-9]{64}$'),
  policy_fingerprint text NOT NULL CHECK (policy_fingerprint ~ '^[a-f0-9]{64}$'),
  work_identity text NOT NULL CHECK (work_identity ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(id,owner_user_id), UNIQUE(owner_user_id,work_identity)
);
CREATE TABLE project1_ai.attempts (
  run_id uuid NOT NULL, owner_user_id uuid NOT NULL,
  attempt_no integer NOT NULL CHECK (attempt_no BETWEEN 1 AND 6),
  stage text NOT NULL CHECK (stage IN ('BDJ','QJ','QG')),
  prompt_version text NOT NULL, prompt_hash text NOT NULL CHECK (prompt_hash ~ '^[a-f0-9]{64}$'),
  request_hash text NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  reserved_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(run_id,attempt_no), UNIQUE(run_id,stage), UNIQUE(run_id,owner_user_id,attempt_no),
  FOREIGN KEY(run_id,owner_user_id) REFERENCES project1_ai.runs(id,owner_user_id)
);
CREATE TABLE project1_ai.attempt_receipts (
  run_id uuid NOT NULL, owner_user_id uuid NOT NULL, attempt_no integer NOT NULL,
  outcome text NOT NULL CHECK (outcome IN ('returned','rejected','unknown_outcome')),
  output_digest text CHECK (output_digest ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(run_id,attempt_no),
  FOREIGN KEY(run_id,owner_user_id,attempt_no)
    REFERENCES project1_ai.attempts(run_id,owner_user_id,attempt_no)
);
-- No proposed WF/ST/FD/SCI/OWN/FIELD codes are silently made database enums.
-- No raw source, prompt, completion, key or JWT storage in the metadata ledger.
CREATE FUNCTION project1_ai.deny_mutation() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog AS $$ BEGIN
  RAISE EXCEPTION 'Workflow history is append-only';
END $$;
REVOKE ALL ON FUNCTION project1_ai.deny_mutation() FROM PUBLIC;
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['runs','attempts','attempt_receipts'] LOOP
    EXECUTE format('ALTER TABLE project1_ai.%I OWNER TO p1ai_owner',t);
    EXECUTE format('ALTER TABLE project1_ai.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE project1_ai.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY owner_scope ON project1_ai.%I USING
      (owner_user_id = nullif(current_setting(''project1.actor_id'',true),'''')::uuid)
      WITH CHECK (owner_user_id = nullif(current_setting(''project1.actor_id'',true),'''')::uuid)',t);
    EXECUTE format('CREATE TRIGGER immutable_history BEFORE UPDATE OR DELETE ON project1_ai.%I
      FOR EACH ROW EXECUTE FUNCTION project1_ai.deny_mutation()',t);
    EXECUTE format('REVOKE ALL ON project1_ai.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT, INSERT ON project1_ai.%I TO p1ai_runtime',t);
    EXECUTE format('CREATE POLICY technical_audit_read ON project1_ai.%I
      FOR SELECT TO p1ai_audit USING (true)',t);
    EXECUTE format('GRANT SELECT ON project1_ai.%I TO p1ai_audit',t);
  END LOOP;
END $$;
ALTER TABLE project1_ai.schema_versions OWNER TO p1ai_owner;
ALTER FUNCTION project1_ai.deny_mutation() OWNER TO p1ai_owner;
GRANT USAGE ON SCHEMA project1_ai TO p1ai_runtime;
GRANT USAGE ON SCHEMA project1_ai TO p1ai_audit;
-- Needed for SELECT FOR UPDATE serialization; UPDATE trigger rejects mutations.
GRANT UPDATE(id) ON project1_ai.runs TO p1ai_runtime;
COMMIT;
