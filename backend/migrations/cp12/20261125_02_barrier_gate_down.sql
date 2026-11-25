-- Rollback for migrations/cp12/20261125_02_barrier_gate.sql (DD-116).
--
-- Restores the three function bodies captured verbatim from the isolated
-- database before the gate was installed:
--   var/e2e/pg18/dd116_20261125/before_write_barrier.sql
--   var/e2e/pg18/dd116_20261125/before_reserve.sql
--   var/e2e/pg18/dd116_20261125/before_remove_draft.sql
--
-- This reinstates the deadlock.  It exists so the correction is reversible and
-- so the regression test can be shown to fail with the defect present.
--
-- Same target guard as the forward migration.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$ BEGIN
 IF current_setting('project1.cp12_migration_target', true)
    IS DISTINCT FROM current_database() THEN
  RAISE EXCEPTION
    'project1.cp12_migration_target must equal the current database (is %)',
    current_database();
 END IF;
END $$;

CREATE OR REPLACE FUNCTION cp12.write_barrier() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cp12'
AS $function$
DECLARE v text; data text; o record;
BEGIN
 data:=lower(coalesce(to_jsonb(OLD)::text,'')||coalesce(to_jsonb(NEW)::text,''));
 FOR v IN SELECT DISTINCT x[1] FROM regexp_matches(data,'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})','g') x ORDER BY 1 LOOP
  PERFORM pg_advisory_xact_lock(hashtextextended(v,12));
  SELECT * INTO o FROM cp12.operations WHERE (m2_id=v::uuid OR assessment_id=v::uuid) AND phase IN ('PREPARED','DSS_REMOVED','COMPLETE') LIMIT 1;
  IF FOUND AND NOT coalesce(o.phase='PREPARED' AND o.cleanup_xid=pg_current_xact_id_if_assigned(),false) THEN RAISE EXCEPTION 'DISCARD_IN_PROGRESS'; END IF;
 END LOOP;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION cp12.reserve(k uuid,a uuid,market_proof text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,cp12 AS $$
DECLARE mid uuid; o record;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended(a::text,12));
 SELECT * INTO o FROM cp12.operations WHERE operation_id=k FOR UPDATE;
 IF FOUND THEN
   IF o.assessment_id<>a OR o.owner_id IS DISTINCT FROM cp12.actor() THEN RAISE EXCEPTION 'DISCARD_OWNER_OR_KEY_MISMATCH'; END IF;
   RETURN o.phase;
 END IF;
 IF market_proof IS NULL OR market_proof IS DISTINCT FROM cp12.proof('PREPARED',k,a,cp12.actor()) THEN RAISE EXCEPTION 'DISCARD_HANDOFF_INVALID'; END IF;
 mid:=cp12.inspect(a);
 IF mid IS NOT NULL THEN
  PERFORM pg_advisory_xact_lock(hashtextextended(mid::text,12));
  PERFORM 1 FROM public.m2_assessments WHERE id=mid FOR UPDATE;
  mid:=cp12.inspect(a);
 END IF;
 INSERT INTO cp12.operations(operation_id,assessment_id,owner_id,m2_id,phase,policy_receipt)
 SELECT k,a,cp12.actor(),mid,'PREPARED',receipt FROM cp12.policy;
 RETURN 'PREPARED';
END $$;

CREATE OR REPLACE FUNCTION cp12.remove_draft(k uuid,a uuid,market_proof text) RETURNS text LANGUAGE plpgsql
SECURITY DEFINER SET search_path=pg_catalog,public,cp12 AS $$
DECLARE mid uuid; o record; v text; t record;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended(a::text,12));
 SELECT * INTO o FROM cp12.operations WHERE operation_id=k FOR UPDATE;
 IF FOUND THEN
   IF o.assessment_id<>a OR o.owner_id IS DISTINCT FROM cp12.actor() THEN RAISE EXCEPTION 'DISCARD_OWNER_OR_KEY_MISMATCH'; END IF;
   IF o.phase IN ('DSS_REMOVED','COMPLETE') THEN RETURN cp12.proof('DSS_REMOVED',k,a,o.owner_id); END IF;
 END IF;
 IF market_proof IS NULL OR market_proof IS DISTINCT FROM cp12.proof('PREPARED',k,a,cp12.actor()) THEN RAISE EXCEPTION 'DISCARD_HANDOFF_INVALID'; END IF;
 -- Hold a short table write barrier while scanning semantic child-ID refs.
 -- Lock timeouts roll back this Dss transaction and preserve recoverable intent.
 PERFORM set_config('lock_timeout','3s',true);
 FOR t IN SELECT n.nspname,c.relname FROM cp12.guarded_relations g JOIN pg_class c ON c.oid=g.relation_oid JOIN pg_namespace n ON n.oid=c.relnamespace ORDER BY n.nspname,c.relname LOOP
  EXECUTE format('LOCK TABLE %I.%I IN SHARE ROW EXCLUSIVE MODE',t.nspname,t.relname);
 END LOOP;
 mid:=cp12.inspect(a);
 IF mid IS NOT NULL THEN PERFORM pg_advisory_xact_lock(hashtextextended(mid::text,12)); PERFORM 1 FROM public.m2_assessments WHERE id=mid FOR UPDATE; mid:=cp12.inspect(a); END IF;
 INSERT INTO cp12.operations(operation_id,assessment_id,owner_id,m2_id,phase,policy_receipt)
 SELECT k,a,cp12.actor(),mid,'PREPARED',receipt FROM cp12.policy ON CONFLICT(operation_id) DO NOTHING;
 UPDATE cp12.operations SET cleanup_xid=pg_current_xact_id() WHERE operation_id=k;
 PERFORM set_config('cp12.operation',k::text,true);
 IF mid IS NOT NULL THEN
   DELETE FROM public.assessment_workflow_projection WHERE assessment_id=mid;
   DELETE FROM public.m2_answer_revisions WHERE assessment_id=mid;
   DELETE FROM public.m2_assessment_links WHERE m2_assessment_id=mid AND marketplace_assessment_id=a AND user_id=cp12.actor();
   DELETE FROM public.m2_assessments WHERE id=mid AND owner_user_id=cp12.actor();
 END IF;
 UPDATE cp12.operations SET phase='DSS_REMOVED' WHERE operation_id=k;
 RETURN cp12.proof('DSS_REMOVED',k,a,cp12.actor());
END $$;

DROP FUNCTION IF EXISTS cp12.gate_key();

COMMIT;
