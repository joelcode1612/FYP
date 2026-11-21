-- Rollback for 20261118_01_question_bank.sql.
--
-- Drops every object created by the forward migration, in reverse dependency
-- order, then the schema. Safe to run twice: every statement is IF EXISTS and
-- the final DROP SCHEMA is CASCADE.
--
-- Cluster roles (p1_qgb_issuer / p1_qgb_runtime / p1_qgb_admin) are deliberately
-- NOT dropped. Roles are cluster-wide and may be referenced by other databases;
-- removing them here would be a blast radius larger than this migration.
--
-- Explicit operator execution only.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
BEGIN
  IF current_setting('project1.qgb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.qgb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required '
                    '(project1.qgb_migration_target must equal current_database(); '
                    'project1.qgb_migration_receipt must be non-empty)';
  END IF;
  IF current_database() IN ('Dss', 'Final_Location_Analysis') THEN
    RAISE EXCEPTION 'Refusing to roll back the question-bank schema on protected database %',
                    current_database();
  END IF;
END
$guard$;

-- Views first: they depend on the tables.
DROP VIEW IF EXISTS project1_qgb.accepted_bank_snapshot_item;
DROP VIEW IF EXISTS project1_qgb.accepted_bank_snapshot;
DROP VIEW IF EXISTS project1_qgb.approved_question_item_version;
DROP VIEW IF EXISTS project1_qgb.bank_snapshot_state;
DROP VIEW IF EXISTS project1_qgb.question_item_version_state;

-- Then tables, children before parents.
DROP TABLE IF EXISTS project1_qgb.comparison_review_item;
DROP TABLE IF EXISTS project1_qgb.comparison_receipt;
DROP TABLE IF EXISTS project1_qgb.bank_snapshot_item;
DROP TABLE IF EXISTS project1_qgb.bank_snapshot_event;
DROP TABLE IF EXISTS project1_qgb.bank_snapshot;
DROP TABLE IF EXISTS project1_qgb.item_lifecycle_event;
DROP TABLE IF EXISTS project1_qgb.question_item_version;
DROP TABLE IF EXISTS project1_qgb.question_item;

DROP FUNCTION IF EXISTS project1_qgb.refuse_rewrite();

-- Catch-all for anything unforeseen; CASCADE makes a second run harmless.
DROP SCHEMA IF EXISTS project1_qgb CASCADE;

DO $verify$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'project1_qgb') THEN
    RAISE EXCEPTION 'schema project1_qgb still present after rollback';
  END IF;
END
$verify$;

COMMIT;
