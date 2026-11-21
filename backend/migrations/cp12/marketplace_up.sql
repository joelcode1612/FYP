-- CP-12 REVIEW REQUIRED. Apply only on clone until separately authorized.
BEGIN;
DO $$ BEGIN
 IF current_setting('project1.cp12_migration_target',true) IS DISTINCT FROM current_database()
 OR nullif(current_setting('project1.cp12_migration_receipt',true),'') IS NULL THEN
 RAISE EXCEPTION 'CP12_MIGRATION_APPROVAL_REQUIRED'; END IF;
END $$;
CREATE SCHEMA cp12;
-- Authenticated cross-database stage handoff. Secret never leaves an operator
-- provisioning connection; the application transports only per-operation MACs.
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;
DO $$ BEGIN
 IF (SELECT extnamespace FROM pg_extension WHERE extname='pgcrypto') <> 'public'::regnamespace THEN RAISE EXCEPTION 'CP12_PGCRYPTO_SCHEMA_UNVERIFIED'; END IF;
END $$;
CREATE TABLE cp12.handoff_key(singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton), secret bytea NOT NULL CHECK(octet_length(secret)=32));
-- Deliberately no default key. Operator must provision the same random key in
-- both databases after migration approval; missing key refuses every mutation.
CREATE FUNCTION cp12.proof(stage text,k uuid,a uuid,actor uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,cp12 AS $$
 SELECT encode(public.hmac(convert_to(stage||':'||k::text||':'||a::text||':'||actor::text,'UTF8'),secret,'sha256'),'hex') FROM cp12.handoff_key
$$;

CREATE TABLE cp12.policy(singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 approved boolean NOT NULL DEFAULT false, receipt text);
INSERT INTO cp12.policy DEFAULT VALUES;
CREATE TABLE cp12.target_reviews(
 assessment_id uuid PRIMARY KEY, owner_id uuid NOT NULL,
 retention_receipt text NOT NULL CHECK(length(btrim(retention_receipt))>0),
 external_inventory_receipt text NOT NULL CHECK(length(btrim(external_inventory_receipt))>0));
CREATE TABLE cp12.operations(
 operation_id uuid PRIMARY KEY, assessment_id uuid NOT NULL UNIQUE,
 owner_id uuid NOT NULL, property_id text NOT NULL,
 phase text NOT NULL CHECK(phase IN ('PREPARED','COMPLETE')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(), completed_at timestamptz, cleanup_xid xid8);
CREATE FUNCTION cp12.actor() RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('project1.actor_id',true),'')::uuid $$;
CREATE FUNCTION cp12.prepare(k uuid,a uuid) RETURNS text LANGUAGE plpgsql
SECURITY DEFINER SET search_path=pg_catalog,public,cp12 AS $$
DECLARE r record; o record; t record; n bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended(a::text,12));
 SELECT * INTO o FROM cp12.operations WHERE operation_id=k;
 IF FOUND THEN
   IF o.owner_id IS DISTINCT FROM cp12.actor() OR o.assessment_id<>a THEN RAISE EXCEPTION 'DISCARD_OWNER_OR_KEY_MISMATCH'; END IF;
   RETURN cp12.proof('PREPARED',k,a,o.owner_id);
 END IF;
 IF NOT EXISTS(SELECT FROM cp12.handoff_key) THEN RAISE EXCEPTION 'DISCARD_HANDOFF_NOT_PROVISIONED'; END IF;
 IF NOT EXISTS(SELECT FROM cp12.target_reviews WHERE assessment_id=a AND owner_id=cp12.actor()) THEN RAISE EXCEPTION 'DISCARD_TARGET_RETENTION_UNVERIFIED'; END IF;
 IF NOT EXISTS(SELECT FROM cp12.policy WHERE approved AND length(btrim(receipt))>0) THEN RAISE EXCEPTION 'DISCARD_RETENTION_POLICY_UNVERIFIED'; END IF;
 SELECT * INTO r FROM public.assessment WHERE assessment_id=a FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DISCARD_MARKETPLACE_ABSENT_ORPHAN_RECOVERY_REQUIRED'; END IF;
 IF r.user_id IS DISTINCT FROM cp12.actor() THEN RAISE EXCEPTION 'DISCARD_OWNER_MISMATCH'; END IF;
 IF r.status<>'in_progress' OR r.evidence_reviewed_at IS NOT NULL OR r.explanation_reviewed_at IS NOT NULL OR r.report_generated_at IS NOT NULL THEN RAISE EXCEPTION 'DISCARD_PROTECTED_LIFECYCLE'; END IF;
 -- Inspect all physical tables for explicit and semantic references.
 FOR t IN SELECT ns.nspname,c.relname FROM pg_class c JOIN pg_namespace ns ON ns.oid=c.relnamespace WHERE ns.nspname NOT IN ('pg_catalog','information_schema','cp12') AND ns.nspname NOT LIKE 'pg_%' AND c.relkind IN ('r','p') ORDER BY ns.nspname,c.relname LOOP
   IF NOT EXISTS(SELECT FROM cp12.guarded_relations WHERE relation_oid=to_regclass(format('%I.%I',t.nspname,t.relname))) THEN RAISE EXCEPTION 'DISCARD_SCHEMA_INVENTORY_CHANGED'; END IF;
   IF t.nspname='public' AND t.relname='assessment' THEN CONTINUE; END IF;
   EXECUTE format('SELECT count(*) FROM %I.%I r WHERE lower(to_jsonb(r)::text) LIKE $1',t.nspname,t.relname) INTO n USING '%'||a::text||'%';
   IF n>0 THEN RAISE EXCEPTION 'DISCARD_PROTECTED_OR_UNKNOWN_REFERENCE'; END IF;
 END LOOP;
 INSERT INTO cp12.operations(operation_id,assessment_id,owner_id,property_id,phase)
 VALUES(k,a,r.user_id,r.property_id,'PREPARED');
 RETURN cp12.proof('PREPARED',k,a,r.user_id);
END $$;
CREATE FUNCTION cp12.finish(k uuid,a uuid,dss_proof text) RETURNS text LANGUAGE plpgsql
SECURITY DEFINER SET search_path=pg_catalog,public,cp12 AS $$
DECLARE o record;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended(a::text,12));
 SELECT * INTO o FROM cp12.operations WHERE operation_id=k FOR UPDATE;
 IF NOT FOUND OR o.owner_id IS DISTINCT FROM cp12.actor() OR o.assessment_id<>a THEN RAISE EXCEPTION 'DISCARD_OWNER_OR_KEY_MISMATCH'; END IF;
 IF dss_proof IS NULL OR dss_proof IS DISTINCT FROM cp12.proof('DSS_REMOVED',k,a,o.owner_id) THEN RAISE EXCEPTION 'DISCARD_HANDOFF_INVALID'; END IF;
 UPDATE cp12.operations SET cleanup_xid=pg_current_xact_id() WHERE operation_id=k;
 PERFORM set_config('cp12.operation',k::text,true);
 DELETE FROM public.assessment WHERE assessment_id=a AND user_id=o.owner_id AND status='in_progress';
 IF EXISTS(SELECT FROM public.assessment WHERE assessment_id=a) THEN RAISE EXCEPTION 'DISCARD_MARKETPLACE_POSTCONDITION'; END IF;
 UPDATE cp12.operations SET phase='COMPLETE',completed_at=coalesce(completed_at,clock_timestamp()) WHERE operation_id=k;
 RETURN cp12.proof('COMPLETE',k,a,o.owner_id);
END $$;
CREATE TABLE cp12.guarded_relations(relation_oid oid PRIMARY KEY);
CREATE FUNCTION cp12.market_barrier() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,cp12 AS $$
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
END $$;
DO $$ DECLARE t record; BEGIN
 FOR t IN SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema','cp12') AND n.nspname NOT LIKE 'pg_%' AND c.relkind IN ('r','p') LOOP
 EXECUTE format('CREATE TRIGGER cp12_barrier BEFORE INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier()',t.nspname,t.relname);
 INSERT INTO cp12.guarded_relations VALUES(to_regclass(format('%I.%I',t.nspname,t.relname)));
 END LOOP;
END $$;
REVOKE ALL ON SCHEMA cp12 FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA cp12 FROM PUBLIC;
-- The actual marketplace login is postgres. Do not grant a new unrestricted role.
COMMIT;
