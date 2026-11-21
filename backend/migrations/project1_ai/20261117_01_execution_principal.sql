-- PROJECT1 restricted execution-principal contract.
--
-- Intent: allow the governed ModelRunner/ledger to write project1_ai history
-- WITHOUT making the restricted execution role p1ai_runtime directly LOGIN.
--
-- Design (matches the existing SET LOCAL ROLE pattern used for p1_ee01_runtime):
--   * p1ai_runtime stays NOLOGIN: it can never authenticate directly.
--   * A dedicated LOGIN principal p1ai_engine is created, NOINHERIT/NOSUPERUSER/
--     NOBYPASSRLS, and granted membership in p1ai_runtime.
--   * The ledger connection authenticates as p1ai_engine and issues
--     SET LOCAL ROLE p1ai_runtime so every statement executes as p1ai_runtime.
--   * PostgresAttemptLedger._scope enforces BOTH:
--       session_user == 'p1ai_engine' (non-superuser, no BYPASSRLS), and
--       current_user == 'p1ai_runtime' after SET ROLE.
--   * p1ai_audit remains the separate read-only principal (unchanged).
--
-- The password for p1ai_engine is NOT set here. It is provisioned separately from
-- PROJECT1_RUNTIME_DATABASE_URL by the operator and never committed.

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'p1ai_engine') THEN
    RAISE NOTICE 'p1ai_engine already exists; reconciling attributes and membership';
  ELSE
    CREATE ROLE p1ai_engine LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
END $$;

-- Ensure attributes are correct even if the role pre-existed.
ALTER ROLE p1ai_engine LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;

-- Membership lets p1ai_engine SET ROLE p1ai_runtime. NOINHERIT on both roles
-- means the privileges are NOT active until an explicit SET ROLE.
GRANT p1ai_runtime TO p1ai_engine;

-- p1ai_engine must NOT have direct access to project1_ai; it only reaches the
-- tables after SET LOCAL ROLE p1ai_runtime (which carries the INSERT/SELECT
-- grants from the candidate-ledger migration). Explicitly withhold direct grants.
REVOKE ALL ON SCHEMA project1_ai FROM p1ai_engine;
REVOKE ALL ON ALL TABLES IN SCHEMA project1_ai FROM p1ai_engine;

-- Read-only audit principal. p1ai_audit stays NOLOGIN; a dedicated LOGIN
-- principal p1ai_auditor is its only member and reaches the tables only after
-- SET LOCAL ROLE p1ai_audit (SELECT-only, no writes).
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'p1ai_auditor') THEN
    CREATE ROLE p1ai_auditor LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
END $$;
ALTER ROLE p1ai_auditor LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
GRANT p1ai_audit TO p1ai_auditor;
REVOKE ALL ON SCHEMA project1_ai FROM p1ai_auditor;
REVOKE ALL ON ALL TABLES IN SCHEMA project1_ai FROM p1ai_auditor;
