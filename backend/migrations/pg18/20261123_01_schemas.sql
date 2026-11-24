-- PROJECT1 PG18 isolated environment — schema surface
-- Migration: 20261123_01_schemas
-- Target:    project1_pg18_* @ 127.0.0.1:5544
--
-- The schema surface is measured from `Dss`, not assumed. A read-only catalog
-- query on 5432 returns exactly three namespaces holding relations:
--
--     public        86 tables, 2 views, 170 indexes
--     project1_ai   11 tables
--     cp12           6 tables
--
-- Three schemas the application references do NOT exist in `Dss` at all:
--
--     fyp     18 tables — present only in the untracked var/e2e/fyp_clean.sql
--     ee01    EE-01 foundation — created via ORM create_all, never versioned
--     fnb_a   — created via ORM create_all, never versioned
--
-- That absence is the G1 gap recorded in
-- PROJECT1_DATABASE_ARCHITECTURE_ADVERSARIAL_REVIEW.md §2.3. This migration
-- deliberately does NOT invent them: fabricating a schema from an untracked
-- dump would reproduce the exact defect the review blocks on. They stay absent
-- until their DDL is versioned, and the assertion at the bottom keeps that
-- absence visible instead of silent.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $$
BEGIN
    IF current_database() IN ('Dss', 'Final_Location_Analysis') THEN
        RAISE EXCEPTION 'REFUSED: % is a protected database', current_database();
    END IF;
    IF current_database() NOT LIKE 'project1\_pg18\_%' THEN
        RAISE EXCEPTION 'REFUSED: expected a project1_pg18_* database, connected to %',
            current_database();
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS project1_ai;
CREATE SCHEMA IF NOT EXISTS cp12;

COMMENT ON SCHEMA project1_ai IS
    'Project-1 AI ledger: schema_versions, attempts, receipts. Rebuilt from versioned DDL only.';
COMMENT ON SCHEMA cp12 IS
    'Checkpoint-12 staging objects. Rebuilt from versioned DDL only.';

-- Record the deliberate omissions as machine-readable facts, so a later check
-- can distinguish "not yet versioned" from "silently dropped".
DO $$
DECLARE present text;
BEGIN
    SELECT string_agg(nspname, ', ') INTO present
    FROM pg_namespace
    WHERE nspname IN ('fyp', 'ee01', 'fnb_a');
    IF present IS NOT NULL THEN
        RAISE EXCEPTION
            'REFUSED: unversioned schemas appeared without DDL: % — version them first', present;
    END IF;
END $$;

COMMIT;
