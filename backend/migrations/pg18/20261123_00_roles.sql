-- PROJECT1 PG18 isolated environment — restricted role set
-- Migration: 20261123_00_roles
-- Target:    project1_pg18_* @ 127.0.0.1:5544  (Owner Decision 1/2, 2026-11-23)
--
-- Purpose
-- -------
-- Reconstruct the least-privilege principal set measured on `Dss` (read-only
-- catalog inspection) so the PG18 environment can run the application without
-- carrying production's two weakest grants:
--
--   1. Every `p1*` role is NOSUPERUSER and NOBYPASSRLS, matching Dss.
--   2. `service_role` in Dss holds BYPASSRLS. A clean build must NOT reproduce
--      that: it is the single grant that makes RLS advisory rather than
--      enforced. Here `service_role` is created NOLOGIN and NOBYPASSRLS.
--
-- Deliberately absent: `p1_ee01_runtime` is created LOGIN (as it is live on
-- Dss) but its grants are withheld until the EE-01 schema exists. Creating the
-- role without grants is the fail-closed default: the app gets a permission
-- error instead of an unowned surface.
--
-- Passwords are dev-only local values for the disposable cluster, matching the
-- convention already used by `var/e2e/app.env`. They are not production
-- secrets and this cluster is loopback-only.
--
-- Idempotent: existing roles are left untouched and reported, never altered.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $$
BEGIN
    IF current_database() IN ('Dss', 'Final_Location_Analysis') THEN
        RAISE EXCEPTION 'REFUSED: % is a protected database', current_database();
    END IF;
    IF inet_server_port() IN (5432, 5433) THEN
        RAISE EXCEPTION 'REFUSED: port % is a protected or legacy cluster', inet_server_port();
    END IF;
    IF current_database() NOT LIKE 'project1\_pg18\_%' THEN
        RAISE EXCEPTION 'REFUSED: expected a project1_pg18_* database, connected to %',
            current_database();
    END IF;
END $$;

DO $$
DECLARE
    spec record;
    inherit_clause text;
BEGIN
    FOR spec IN
        SELECT * FROM (VALUES
            -- application / analytics principal (ORM writes only here)
            ('sitewise_e2e',       'LOGIN',   'INHERIT',   'sitewise_e2e_dev_only'),
            -- M2/BCB runtime: NOINHERIT so group grants are not ambient
            ('p1_m2_runtime',      'LOGIN',   'NOINHERIT', 'm2_runtime_dev_only'),
            -- Project-1 AI engine (ledger writer)
            ('p1ai_engine',        'LOGIN',   'NOINHERIT', 'p1ai_engine_dev_only'),
            ('p1_ee01_runtime',    'LOGIN',   'NOINHERIT', 'ee01_runtime_dev_only'),
            ('p1ai_auditor',       'LOGIN',   'NOINHERIT', 'p1ai_auditor_dev_only'),
            ('p1_schema_reader',   'LOGIN',   'INHERIT',   'schema_reader_dev_only'),
            ('p1_cq_syn50_reader', 'LOGIN',   'INHERIT',   'cq_reader_dev_only'),
            ('p1_cq_syn50_writer', 'LOGIN',   'INHERIT',   'cq_writer_dev_only'),
            ('p1uc_stage_human',   'LOGIN',   'NOINHERIT', 'p1uc_human_dev_only'),
            ('p1uc_stage_llm',     'LOGIN',   'NOINHERIT', 'p1uc_llm_dev_only'),
            ('p1uc_stage_qj',      'LOGIN',   'NOINHERIT', 'p1uc_qj_dev_only'),
            -- non-login group roles
            ('p1ai_runtime',       'NOLOGIN', 'INHERIT',   NULL),
            ('p1ai_audit',         'NOLOGIN', 'INHERIT',   NULL),
            ('p1ai_owner',         'NOLOGIN', 'INHERIT',   NULL),
            ('p1_qgb_admin',       'NOLOGIN', 'INHERIT',   NULL),
            ('p1_qgb_issuer',      'NOLOGIN', 'INHERIT',   NULL),
            ('p1_qgb_runtime',     'NOLOGIN', 'INHERIT',   NULL),
            -- Supabase-compatible principals
            ('anon',               'NOLOGIN', 'INHERIT',   NULL),
            ('authenticated',      'NOLOGIN', 'INHERIT',   NULL),
            -- clean-build divergence: Dss grants BYPASSRLS here; we do not
            ('service_role',       'NOLOGIN', 'INHERIT',   NULL)
        ) AS v(rolname, login_mode, inh, pw)
    LOOP
        CONTINUE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = spec.rolname);
        inherit_clause := CASE spec.inh WHEN 'NOINHERIT' THEN 'NOINHERIT' ELSE 'INHERIT' END;
        EXECUTE format(
            'CREATE ROLE %I %s NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS %s %s',
            spec.rolname,
            spec.login_mode,
            inherit_clause,
            CASE WHEN spec.pw IS NULL THEN '' ELSE format('PASSWORD %L', spec.pw) END
        );
    END LOOP;
END $$;

-- Fail closed: no *managed* principal in this cluster may carry an escalation
-- path. The bootstrap `postgres` superuser is excluded by name and by design —
-- it exists to provision the cluster and is never used by the application.
DO $$
DECLARE bad text;
BEGIN
    SELECT string_agg(rolname, ', ') INTO bad
    FROM pg_roles
    WHERE (rolsuper OR rolbypassrls)
      AND rolname <> 'postgres'
      AND rolname NOT LIKE 'pg\_%';
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'REFUSED: managed principal with escalation path: %', bad;
    END IF;
END $$;

-- Positive assertion: the three principals the application actually logs in as
-- must exist and must not be privileged.
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n
    FROM pg_roles
    WHERE rolname IN ('sitewise_e2e', 'p1_m2_runtime', 'p1ai_engine')
      AND rolcanlogin
      AND NOT rolsuper
      AND NOT rolbypassrls;
    IF n <> 3 THEN
        RAISE EXCEPTION 'REFUSED: expected 3 unprivileged login principals, found %', n;
    END IF;
END $$;

COMMIT;
