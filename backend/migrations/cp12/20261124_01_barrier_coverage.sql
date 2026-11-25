-- =====================================================================
-- 20261124_01_barrier_coverage.sql
-- =====================================================================
-- Purpose
--   Attach the `cp12_barrier` write barrier to every relation that does not
--   yet carry it, and record it in `cp12.guarded_relations`.
--
-- Reason
--   `cp12/dss_up.sql` attaches the barrier to whatever tables exist at the
--   moment it runs, and **no later migration re-runs that loop**. A clean
--   install therefore has two possible outcomes, both wrong:
--
--     * CP12 first  -> CQ/EE-01 tables created afterwards are unguarded;
--     * CP12 last   -> impossible, because `m2/20261115_02` declares a trigger
--                      on `public.m2_bcb_reject_mutation()`, which dss_up
--                      creates, so CP12 must precede it.
--
--   This migration closes the gap without changing `dss_up.sql` (whose hash is
--   already recorded in production ledgers). It is idempotent: relations
--   already guarded are skipped, so running it after any later migration
--   restores coverage.
--
-- Constraint
--   Additive only. It never drops a trigger, never alters a table, and never
--   touches `cp12.operations`, `cp12.policy` or `cp12.target_reviews`. It is a
--   no-op on a database whose coverage is already complete.
--
--   Guarded to disposable `project1_cq_*` databases on the disposable cluster.
--   Applying it to `project1_pg18_migrated_tests` requires separate approval
--   and a different target guard.
-- =====================================================================

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
  IF current_database() NOT LIKE 'project1\_cq\_%' THEN
    RAISE EXCEPTION
      'refusing to run outside a project1_cq_* database (current=%)',
      current_database();
  END IF;
  IF inet_server_port() <> 5433 THEN
    RAISE EXCEPTION 'refusing to run outside the disposable cluster (port=%)',
      inet_server_port();
  END IF;
  IF to_regclass('cp12.guarded_relations') IS NULL THEN
    RAISE EXCEPTION 'cp12.guarded_relations missing; apply cp12/dss_up.sql first';
  END IF;
  IF to_regprocedure('cp12.write_barrier()') IS NULL THEN
    RAISE EXCEPTION 'cp12.write_barrier() missing; apply cp12/dss_up.sql first';
  END IF;
END $$;

DO $$
DECLARE
  t record;
  attached int := 0;
BEGIN
  FOR t IN
    SELECT n.nspname, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'cp12')
      AND n.nspname NOT LIKE 'pg\_%'
      AND c.relkind IN ('r', 'p')
      AND NOT EXISTS (
        SELECT 1 FROM pg_trigger tg
        WHERE tg.tgrelid = c.oid
          AND tg.tgname = 'cp12_barrier'
          AND NOT tg.tgisinternal)
    ORDER BY n.nspname, c.relname
  LOOP
    EXECUTE format(
      'CREATE TRIGGER cp12_barrier BEFORE INSERT OR UPDATE OR DELETE ON %I.%I '
      'FOR EACH ROW EXECUTE FUNCTION cp12.write_barrier()',
      t.nspname, t.relname);
    INSERT INTO cp12.guarded_relations
      VALUES (to_regclass(format('%I.%I', t.nspname, t.relname)))
      ON CONFLICT DO NOTHING;
    attached := attached + 1;
  END LOOP;
  RAISE NOTICE 'cp12_barrier attached to % relation(s)', attached;
END $$;

COMMIT;
