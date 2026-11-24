-- =====================================================================
-- 20261123_06_cp12_market_barrier.sql
-- =====================================================================
-- Purpose
--   Recreate ``cp12.market_barrier()`` in the isolated PG18 cluster, then
--   attach the ``cp12_barrier`` triggers the restored ``demand_gen`` tables
--   declare. The schema-only dump of demand_gen carries the triggers but not
--   the function, because the function lives in the ``cp12`` schema, which
--   this cluster already owns from 20261123_01_schemas.sql.
--
-- Behaviour (copied verbatim from Final_Location_Analysis)
--   BEFORE INSERT/UPDATE/DELETE row trigger. It scans OLD||NEW for UUIDs,
--   takes an advisory lock per UUID, and raises DISCARD_IN_PROGRESS only when
--   ``cp12.operations`` holds a live cleanup row for that UUID. With an empty
--   ``cp12.operations`` it is a no-op that returns the row unchanged — which
--   is the state of this test database.
--
-- Safety
--   Same guard discipline as the rest of migrations/pg18: only a
--   ``project1_pg18_%`` database on port 5544 may run this file.
-- =====================================================================

DO $$
DECLARE
    db   text := current_database();
    port int  := inet_server_port();
BEGIN
    IF db NOT LIKE 'project1\_pg18\_%' THEN
        RAISE EXCEPTION 'REFUSED: % is not a project1_pg18_* database', db;
    END IF;
    IF port <> 5544 THEN
        RAISE EXCEPTION 'REFUSED: port % is not the isolated PG18 cluster (5544)', port;
    END IF;
    IF to_regclass('cp12.operations') IS NULL THEN
        RAISE EXCEPTION 'REFUSED: cp12.operations is missing; apply 20261123_01_schemas.sql first';
    END IF;
    RAISE NOTICE 'market_barrier target accepted: % on port %', db, port;
END
$$;

CREATE OR REPLACE FUNCTION cp12.market_barrier()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cp12'
AS $function$
DECLARE v text; o record;
BEGIN
 FOR v IN SELECT DISTINCT x[1] FROM regexp_matches(lower(coalesce(to_jsonb(OLD)::text,'')||coalesce(to_jsonb(NEW)::text,'')),'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})','g') x ORDER BY 1 LOOP
  PERFORM pg_advisory_xact_lock(hashtextextended(v,12));
  SELECT * INTO o FROM cp12.operations WHERE assessment_id=v::uuid;
  IF FOUND AND NOT coalesce(o.cleanup_xid=pg_current_xact_id_if_assigned(),false) THEN RAISE EXCEPTION 'DISCARD_IN_PROGRESS'; END IF;
 END LOOP;
 IF TG_TABLE_SCHEMA='public' AND TG_TABLE_NAME='assessment' AND TG_OP='DELETE' THEN
  IF NOT EXISTS(SELECT FROM cp12.operations WHERE assessment_id=OLD.assessment_id AND cleanup_xid=pg_current_xact_id_if_assigned()) THEN RAISE EXCEPTION 'DISCARD_COORDINATOR_REQUIRED'; END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $function$
;
-- ---------------------------------------------------------------------
-- Triggers. Each is dropped first so the file is re-runnable.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'demand_gen.dedup_audit',
        'demand_gen.features',
        'demand_gen.pois_master',
        'demand_gen.pois_raw',
        'demand_gen.states',
        'demand_gen.subject_poi_pairs',
        'demand_gen.subjects'
    ]
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS cp12_barrier ON %s', t);
        EXECUTE format(
            'CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON %s '
            'FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier()', t);
    END LOOP;
END
$$;
