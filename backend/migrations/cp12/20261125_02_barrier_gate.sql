-- DD-116 correction — one gate, acquired first, in a mode that excludes only
-- the discard coordinator.
--
-- Status: CANDIDATE. Review only. Apply solely to an authorised isolated
-- database, with `project1.cp12_migration_target` set to its exact name and
-- `project1.cp12_migration_receipt` set to the approved receipt.
--
-- ---------------------------------------------------------------------------
-- The defect
-- ---------------------------------------------------------------------------
-- `cp12.write_barrier()` took `pg_advisory_xact_lock(hashtextextended(v,12))`
-- for every UUID in the row, in `ORDER BY 1` over the UUID *text* of that one
-- row.  Sorted-per-row is a total order inside a row, but it is not a total
-- order across the rows of a transaction: row 1 may hold key `Z`, and row 2 may
-- then ask for key `A < Z`.  Two transactions that walk the same two keys in
-- opposite orders form a cycle and PostgreSQL reports `deadlock detected`.
--
-- Measured, six synthetic workers driving disjoint sessions of one campaign:
-- 9 submitted and 11 deadlock errors, against 0 deadlocks serially.  The
-- reproduction is `var/e2e/pg18/dd116_20261125/repro_lock_order.py`; scenario C
-- shows the cycle arising between two respondents of one campaign whose rows
-- share the question bank, which is the recorded production shape.
--
-- ---------------------------------------------------------------------------
-- Why this correction and not another
-- ---------------------------------------------------------------------------
-- The barrier's safeguard is: **a write must not proceed while a discard for
-- that assessment is prepared.**  It is not "writers must exclude each other".
-- Writer-to-writer exclusion is what creates the cycle, and it protects nothing:
--
--   * while a discard is preparing, `remove_draft` already holds
--     `SHARE ROW EXCLUSIVE` on every guarded relation, which excludes writers
--     outright (`dss_up.sql:126-130`);
--   * between `reserve` and `remove_draft`, writers are refused by the
--     `DISCARD_IN_PROGRESS` predicate itself;
--   * and `cp12.inspect()` refuses to run at all unless every application
--     relation is registered in `cp12.guarded_relations`
--     (`DISCARD_SCHEMA_INVENTORY_CHANGED`, `dss_up.sql:67`), so a discard can
--     never prepare in a database where that table lock loop is inert.
--
-- So the correction narrows the lock mode to exactly what the safeguard needs,
-- and adds one ordering anchor:
--
--   1. `cp12.gate_key()` — one fixed 64-bit key, defined once.
--   2. Every barrier invocation takes the gate **shared**, before anything else.
--      Shared mode means two writers never wait for each other, so no cycle can
--      form among them.
--   3. `reserve` and `remove_draft` take the gate **exclusive** as their first
--      statement, so a discard excludes every writer for its whole duration
--      instead of for one key at a time.
--   4. The per-UUID advisory locks are kept, in shared mode.  They are now
--      redundant with the gate, but they are the mechanism the safeguard is
--      written in terms of, and removing them is not required to fix the
--      defect.  Shared mode still conflicts with the discard's exclusive lock
--      on `assessment_id`/`m2_id`, so the per-key exclusion is unchanged.
--   5. The `DISCARD_IN_PROGRESS` predicate is reproduced byte for byte.
--
-- Lock order is therefore a single total order — gate first, always — for every
-- participant, and once an exclusive gate is held no other participant is
-- inside.  A cycle is not possible.
--
-- ---------------------------------------------------------------------------
-- What this does NOT do
-- ---------------------------------------------------------------------------
-- It does not provision CP-12.  `cp12.operations` is empty and
-- `cp12.guarded_relations` is empty in the isolated database, so the discard
-- protocol is inert there and the `DISCARD_IN_PROGRESS` branch cannot fire.
-- This migration changes lock ordering only; it touches no policy, no grant, no
-- table and no row, and it does not change what the barrier refuses.
--
-- `cp12.complete()` is deliberately unchanged: it writes only `cp12.operations`
-- (which carries no barrier), so it neither takes nor needs the gate.
--
-- ---------------------------------------------------------------------------
-- Rollback
-- ---------------------------------------------------------------------------
-- `migrations/cp12/20261125_02_barrier_gate_down.sql` restores the three
-- function bodies captured verbatim in
-- `var/e2e/pg18/dd116_20261125/before_*.sql`.
-- ---------------------------------------------------------------------------

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$ BEGIN
 IF current_setting('project1.cp12_migration_target', true)
    IS DISTINCT FROM current_database() THEN
  RAISE EXCEPTION
    'project1.cp12_migration_target must equal the current database (is %)',
    current_database();
 END IF;
 IF nullif(current_setting('project1.cp12_migration_receipt', true), '') IS NULL THEN
  RAISE EXCEPTION 'project1.cp12_migration_receipt required';
 END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Pre-state guard.  Refuse to rewrite a function this migration does not
-- recognise, so a drifted database stops the run instead of being silently
-- redefined.  Idempotent: a database that already carries the gate is accepted.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  b_owner name; b_secdef boolean; b_body text;
  r_owner name; r_secdef boolean;
  d_owner name; d_secdef boolean;
  ops_before bigint;
BEGIN
  SELECT pg_get_userbyid(proowner), prosecdef, prosrc INTO b_owner, b_secdef, b_body
    FROM pg_proc WHERE oid = 'cp12.write_barrier()'::regprocedure;
  SELECT pg_get_userbyid(proowner), prosecdef INTO r_owner, r_secdef
    FROM pg_proc WHERE oid = 'cp12.reserve(uuid,uuid,text)'::regprocedure;
  SELECT pg_get_userbyid(proowner), prosecdef INTO d_owner, d_secdef
    FROM pg_proc WHERE oid = 'cp12.remove_draft(uuid,uuid,text)'::regprocedure;

  IF b_owner IS NULL OR r_owner IS NULL OR d_owner IS NULL THEN
    RAISE EXCEPTION 'cp12 barrier functions missing; apply cp12/dss_up.sql first';
  END IF;
  IF NOT (b_secdef AND r_secdef AND d_secdef) THEN
    RAISE EXCEPTION 'cp12 barrier functions must stay SECURITY DEFINER';
  END IF;
  IF b_owner IS DISTINCT FROM r_owner OR b_owner IS DISTINCT FROM d_owner THEN
    RAISE EXCEPTION 'cp12 barrier functions have diverged owners (%, %, %)',
      b_owner, r_owner, d_owner;
  END IF;
  -- The refusal this migration must preserve, exactly once.
  IF position('DISCARD_IN_PROGRESS' in b_body) = 0 THEN
    RAISE EXCEPTION 'write_barrier() no longer contains the DISCARD_IN_PROGRESS refusal';
  END IF;
  IF position('cp12.operations' in b_body) = 0 THEN
    RAISE EXCEPTION 'write_barrier() no longer consults cp12.operations';
  END IF;

  SELECT count(*) INTO ops_before FROM cp12.operations;
  RAISE NOTICE 'DD-116 pre-state: owner=%, operations rows=%', b_owner, ops_before;
END $$;

-- ---------------------------------------------------------------------------
-- The single ordering anchor.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cp12.gate_key() RETURNS bigint
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT hashtextextended('cp12.write-gate/1', 12) $$;

-- Same posture as every other function in this schema: no PUBLIC EXECUTE.
REVOKE ALL ON FUNCTION cp12.gate_key() FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 1. The barrier.  Gate first, shared; per-UUID locks retained in shared mode;
--    the DISCARD_IN_PROGRESS predicate byte-identical to dss_up.sql:88-89.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cp12.write_barrier() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'cp12'
AS $function$
DECLARE v text; data text; o record;
BEGIN
 -- DD-116: one gate, always acquired first, and only in shared mode.  Writers
 -- must not exclude each other; they must only be excluded by a discard.
 PERFORM pg_advisory_xact_lock_shared(cp12.gate_key());
 data:=lower(coalesce(to_jsonb(OLD)::text,'')||coalesce(to_jsonb(NEW)::text,''));
 FOR v IN SELECT DISTINCT x[1] FROM regexp_matches(data,'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})','g') x ORDER BY 1 LOOP
  PERFORM pg_advisory_xact_lock_shared(hashtextextended(v,12));
  SELECT * INTO o FROM cp12.operations WHERE (m2_id=v::uuid OR assessment_id=v::uuid) AND phase IN ('PREPARED','DSS_REMOVED','COMPLETE') LIMIT 1;
  IF FOUND AND NOT coalesce(o.phase='PREPARED' AND o.cleanup_xid=pg_current_xact_id_if_assigned(),false) THEN RAISE EXCEPTION 'DISCARD_IN_PROGRESS'; END IF;
 END LOOP;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $function$;

-- ---------------------------------------------------------------------------
-- 2. The discard coordinator.  Exclusive gate first, so no writer is inside
--    while a discard prepares.  Everything after the gate is unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cp12.reserve(k uuid,a uuid,market_proof text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,cp12 AS $$
DECLARE mid uuid; o record;
BEGIN
 PERFORM pg_advisory_xact_lock(cp12.gate_key());
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
 PERFORM pg_advisory_xact_lock(cp12.gate_key());
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

-- ---------------------------------------------------------------------------
-- Post-state assertions.  Each one is a property this migration claims.
-- ---------------------------------------------------------------------------
DO $$
DECLARE b_body text; r_body text; d_body text; b_secdef boolean; ops_after bigint;
BEGIN
  SELECT prosrc, prosecdef INTO b_body, b_secdef
    FROM pg_proc WHERE oid = 'cp12.write_barrier()'::regprocedure;
  SELECT prosrc INTO r_body FROM pg_proc WHERE oid = 'cp12.reserve(uuid,uuid,text)'::regprocedure;
  SELECT prosrc INTO d_body FROM pg_proc WHERE oid = 'cp12.remove_draft(uuid,uuid,text)'::regprocedure;

  -- 1. The safeguard's refusal is intact, exactly once.
  IF (length(b_body) - length(replace(b_body, 'DISCARD_IN_PROGRESS', ''))) / 18 <> 1 THEN
    RAISE EXCEPTION 'assertion 1: DISCARD_IN_PROGRESS refusal missing or duplicated';
  END IF;
  -- 2. The operations lookup is intact.
  IF position('FROM cp12.operations' in b_body) = 0 THEN
    RAISE EXCEPTION 'assertion 2: write_barrier no longer consults cp12.operations';
  END IF;
  -- 3. Gate first, shared, in the barrier.
  IF position('pg_advisory_xact_lock_shared(cp12.gate_key())' in b_body) = 0 THEN
    RAISE EXCEPTION 'assertion 3: write_barrier does not take the shared gate';
  END IF;
  -- 4. No writer takes an exclusive advisory lock any more (that was the cycle).
  IF position('pg_advisory_xact_lock(hashtextextended' in b_body) > 0 THEN
    RAISE EXCEPTION 'assertion 4: write_barrier still takes an exclusive per-key lock';
  END IF;
  -- 5. The discard coordinator takes the gate exclusively, before its own keys.
  IF position('pg_advisory_xact_lock(cp12.gate_key())' in r_body) = 0
     OR position('pg_advisory_xact_lock(cp12.gate_key())' in d_body) = 0 THEN
    RAISE EXCEPTION 'assertion 5: reserve/remove_draft do not take the exclusive gate';
  END IF;
  IF position('pg_advisory_xact_lock(cp12.gate_key())' in r_body)
     > position('pg_advisory_xact_lock(hashtextextended(a::text,12))' in r_body) THEN
    RAISE EXCEPTION 'assertion 5b: reserve takes the gate after the assessment key';
  END IF;
  IF position('pg_advisory_xact_lock(cp12.gate_key())' in d_body)
     > position('pg_advisory_xact_lock(hashtextextended(a::text,12))' in d_body) THEN
    RAISE EXCEPTION 'assertion 5c: remove_draft takes the gate after the assessment key';
  END IF;
  -- 6. Still SECURITY DEFINER: the barrier reads cp12.operations, which the
  --    invoking role may not be able to read itself.
  IF NOT b_secdef THEN
    RAISE EXCEPTION 'assertion 6: write_barrier is no longer SECURITY DEFINER';
  END IF;
  -- 7. No row was touched.
  SELECT count(*) INTO ops_after FROM cp12.operations;
  IF ops_after <> 0 THEN
    RAISE EXCEPTION 'assertion 7: cp12.operations changed (% rows)', ops_after;
  END IF;
  -- 8. Coverage unchanged: every trigger that existed still exists.
  IF (SELECT count(*) FROM pg_trigger WHERE tgname='cp12_barrier' AND NOT tgisinternal) <> 92 THEN
    RAISE EXCEPTION 'assertion 8: cp12_barrier coverage changed';
  END IF;

  RAISE NOTICE 'DD-116 post-state: gate installed, safeguards intact, 92 triggers';
END $$;

COMMIT;
