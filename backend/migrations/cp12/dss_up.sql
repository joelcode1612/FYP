-- CP-12 REVIEW REQUIRED. No automatic live application; no data cleanup here.
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

CREATE TABLE cp12.original_definition(body text NOT NULL);
INSERT INTO cp12.original_definition SELECT pg_get_functiondef('public.m2_bcb_reject_mutation()'::regprocedure);
CREATE TABLE cp12.policy(singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 approved boolean NOT NULL DEFAULT false, receipt text,
 external_references_verified boolean NOT NULL DEFAULT false);
INSERT INTO cp12.policy DEFAULT VALUES;
CREATE TABLE cp12.target_reviews(
 assessment_id uuid PRIMARY KEY, owner_id uuid NOT NULL,
 retention_receipt text NOT NULL CHECK(length(btrim(retention_receipt))>0),
 external_inventory_receipt text NOT NULL CHECK(length(btrim(external_inventory_receipt))>0));
CREATE TABLE cp12.operations(operation_id uuid PRIMARY KEY, assessment_id uuid NOT NULL UNIQUE,
 owner_id uuid NOT NULL, m2_id uuid UNIQUE,
 phase text NOT NULL CHECK(phase IN ('PREPARED','DSS_REMOVED','COMPLETE')),
 policy_receipt text NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 completed_at timestamptz, cleanup_xid xid8);
CREATE FUNCTION cp12.actor() RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('project1.actor_id',true),'')::uuid $$;
-- Inspect every application relation, including JSON/text semantic references.
-- A permission error aborts; it can never be interpreted as an empty table.
CREATE TABLE cp12.guarded_relations(relation_oid oid PRIMARY KEY);
CREATE FUNCTION cp12.inspect(a uuid) RETURNS uuid LANGUAGE plpgsql
SECURITY DEFINER SET search_path=pg_catalog,public,cp12 AS $$
DECLARE l record; m record; t record; n bigint; mid uuid; needles text[]; filter text;
BEGIN
 IF NOT EXISTS(SELECT FROM cp12.handoff_key) THEN RAISE EXCEPTION 'DISCARD_HANDOFF_NOT_PROVISIONED'; END IF;
 IF NOT EXISTS(SELECT FROM cp12.target_reviews WHERE assessment_id=a AND owner_id=cp12.actor()) THEN RAISE EXCEPTION 'DISCARD_TARGET_RETENTION_UNVERIFIED'; END IF;
 IF NOT EXISTS(SELECT FROM cp12.policy WHERE approved AND external_references_verified AND length(btrim(receipt))>0) THEN RAISE EXCEPTION 'DISCARD_RETENTION_OR_EXTERNAL_REFS_UNVERIFIED'; END IF;
 SELECT * INTO l FROM public.m2_assessment_links WHERE marketplace_assessment_id=a AND revoked_at IS NULL;
 IF NOT FOUND THEN
   IF EXISTS(SELECT FROM public.m2_assessment_links WHERE marketplace_assessment_id=a) THEN RAISE EXCEPTION 'DISCARD_HISTORICAL_LINK_PROTECTED'; END IF;
 ELSE
   IF l.user_id IS DISTINCT FROM cp12.actor() THEN RAISE EXCEPTION 'DISCARD_OWNER_MISMATCH'; END IF;
   SELECT * INTO m FROM public.m2_assessments WHERE id=l.m2_assessment_id;
   IF NOT FOUND OR m.owner_user_id IS DISTINCT FROM cp12.actor() THEN RAISE EXCEPTION 'DISCARD_M2_OWNER_MISMATCH'; END IF;
   IF m.confirmed_revision IS NOT NULL THEN RAISE EXCEPTION 'DISCARD_ALREADY_CONFIRMED'; END IF;
   IF (SELECT count(*) FROM public.m2_assessment_links WHERE m2_assessment_id=m.id)<>1 THEN RAISE EXCEPTION 'DISCARD_SHARED_OR_HISTORICAL_LINK'; END IF;
   mid:=m.id;
 END IF;
 SELECT array_agg('%'||ref::text||'%') INTO needles FROM (
   SELECT a ref UNION SELECT mid WHERE mid IS NOT NULL
   UNION SELECT id FROM public.m2_answer_revisions WHERE assessment_id=mid
   UNION SELECT projection_id FROM public.assessment_workflow_projection WHERE assessment_id=mid
   UNION SELECT link_id FROM public.m2_assessment_links WHERE m2_assessment_id=mid) refs;
 FOR t IN SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema','cp12') AND n.nspname NOT LIKE 'pg_%' AND c.relkind IN ('r','p') LOOP
   IF NOT EXISTS(SELECT FROM cp12.guarded_relations WHERE relation_oid=to_regclass(format('%I.%I',t.nspname,t.relname))) THEN RAISE EXCEPTION 'DISCARD_SCHEMA_INVENTORY_CHANGED'; END IF;
   filter:='true';
   IF t.nspname='public' THEN
     IF t.relname='m2_assessments' THEN filter:='r.id IS DISTINCT FROM $2';
     ELSIF t.relname=ANY(ARRAY['m2_answer_revisions','assessment_workflow_projection']) THEN filter:='r.assessment_id IS DISTINCT FROM $2';
     ELSIF t.relname='m2_assessment_links' THEN filter:='r.m2_assessment_id IS DISTINCT FROM $2'; END IF;
   END IF;
   EXECUTE format('SELECT count(*) FROM %I.%I r WHERE (%s) AND lower(to_jsonb(r)::text) LIKE ANY($1)',t.nspname,t.relname,filter) INTO n USING needles,mid;
   IF n>0 THEN RAISE EXCEPTION 'DISCARD_PROTECTED_OR_UNKNOWN_REFERENCE'; END IF;
 END LOOP;
 RETURN mid;
END $$;

-- Writers serialize on all UUID references in a row, including JSON references.
-- This avoids assuming that all downstream references have native FKs.
CREATE FUNCTION cp12.write_barrier() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,cp12 AS $$
DECLARE v text; data text; o record;
BEGIN
 data:=lower(coalesce(to_jsonb(OLD)::text,'')||coalesce(to_jsonb(NEW)::text,''));
 FOR v IN SELECT DISTINCT x[1] FROM regexp_matches(data,'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})','g') x ORDER BY 1 LOOP
  PERFORM pg_advisory_xact_lock(hashtextextended(v,12));
  SELECT * INTO o FROM cp12.operations WHERE (m2_id=v::uuid OR assessment_id=v::uuid) AND phase IN ('PREPARED','DSS_REMOVED','COMPLETE') LIMIT 1;
  IF FOUND AND NOT coalesce(o.phase='PREPARED' AND o.cleanup_xid=pg_current_xact_id_if_assigned(),false) THEN RAISE EXCEPTION 'DISCARD_IN_PROGRESS'; END IF;
 END LOOP;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $$;
CREATE FUNCTION cp12.reserve(k uuid,a uuid,market_proof text) RETURNS text
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
CREATE FUNCTION cp12.remove_draft(k uuid,a uuid,market_proof text) RETURNS text LANGUAGE plpgsql
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
-- Only the two draft tables get a bounded exception to append-only deletion.
-- All other mutations keep the exact original rejection semantics.
CREATE OR REPLACE FUNCTION public.m2_bcb_reject_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' AND TG_TABLE_SCHEMA='public' AND TG_TABLE_NAME IN ('m2_answer_revisions','assessment_workflow_projection')
 AND current_user=pg_get_userbyid((SELECT proowner FROM pg_proc WHERE oid='cp12.remove_draft(uuid,uuid,text)'::regprocedure))
 AND EXISTS(SELECT FROM cp12.operations WHERE operation_id::text=current_setting('cp12.operation',true) AND m2_id=OLD.assessment_id AND phase='PREPARED' AND cleanup_xid=pg_current_xact_id_if_assigned()) THEN RETURN OLD; END IF;
 RAISE EXCEPTION 'Versioned M2/BCB source records are append-only' USING ERRCODE='55000';
END $$;
CREATE FUNCTION cp12.complete(k uuid,a uuid,market_proof text) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,cp12 AS $$
DECLARE o record;
BEGIN
 SELECT * INTO o FROM cp12.operations WHERE operation_id=k FOR UPDATE;
 IF NOT FOUND OR o.owner_id IS DISTINCT FROM cp12.actor() OR o.assessment_id<>a THEN RAISE EXCEPTION 'DISCARD_OWNER_OR_KEY_MISMATCH'; END IF;
 IF market_proof IS NULL OR market_proof IS DISTINCT FROM cp12.proof('COMPLETE',k,a,o.owner_id) THEN RAISE EXCEPTION 'DISCARD_HANDOFF_INVALID'; END IF;
 IF o.m2_id IS NOT NULL AND (EXISTS(SELECT FROM public.m2_assessments WHERE id=o.m2_id) OR EXISTS(SELECT FROM public.m2_assessment_links WHERE m2_assessment_id=o.m2_id) OR EXISTS(SELECT FROM public.m2_answer_revisions WHERE assessment_id=o.m2_id)) THEN RAISE EXCEPTION 'DISCARD_DSS_POSTCONDITION'; END IF;
 UPDATE cp12.operations SET phase='COMPLETE',completed_at=coalesce(completed_at,clock_timestamp()) WHERE operation_id=k;
 RETURN 'COMPLETE';
END $$;
DO $$ DECLARE t record; BEGIN
 FOR t IN SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema','cp12') AND n.nspname NOT LIKE 'pg_%' AND c.relkind IN ('r','p') LOOP
 EXECUTE format('CREATE TRIGGER cp12_barrier BEFORE INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION cp12.write_barrier()',t.nspname,t.relname);
 INSERT INTO cp12.guarded_relations VALUES(to_regclass(format('%I.%I',t.nspname,t.relname))) ON CONFLICT DO NOTHING;
 END LOOP;
END $$;
REVOKE ALL ON SCHEMA cp12 FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA cp12 FROM PUBLIC;
GRANT USAGE ON SCHEMA cp12 TO p1_m2_runtime;
GRANT EXECUTE ON FUNCTION cp12.inspect(uuid),cp12.reserve(uuid,uuid,text),cp12.remove_draft(uuid,uuid,text),cp12.complete(uuid,uuid,text),cp12.actor() TO p1_m2_runtime;
-- Barrier reads are owner-scoped. Other writer roles need separately reviewed
-- SELECT/USAGE grants before deployment; lack of access refuses writes.
ALTER TABLE cp12.operations ENABLE ROW LEVEL SECURITY;
CREATE POLICY owner_scope ON cp12.operations FOR SELECT TO p1_m2_runtime USING(owner_id=cp12.actor());
GRANT SELECT ON cp12.operations TO p1_m2_runtime;
COMMIT;
