-- =====================================================================
-- 20261124_21_bdj_authorization_consumptions.sql
--
-- Purpose
--   Make "one authorization -> at most one provider attempt" a database
--   invariant rather than an inference (DD-005).
--
-- Why a new table instead of UPDATE ... SET consumed_at
--   ``project1_ai.bdj_real_data_authorizations`` is deliberately immutable:
--   a trigger refuses any change to its binding columns. Spending a
--   permission by mutating it would turn an audit artefact into mutable
--   state. This table records the spend as an append-only EVENT, which is
--   also how the attempt ledger already works.
--
-- Why the PRIMARY KEY is the guarantee
--   ``authorization_id`` is the primary key, so the second INSERT for the
--   same authorization cannot succeed. The insert happens inside the same
--   transaction as the attempt reservation (ledger.reserve), so a duplicate
--   rolls back the attempt row too: no attempt is consumed and no dispatch
--   can follow. That is atomicity without a two-phase protocol.
--
-- Target: the isolated PG18 test database only.
-- =====================================================================

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF current_database() <> 'project1_pg18_migrated_tests' THEN
        RAISE EXCEPTION
            'refusing to run outside the isolated PG18 test database (current=%)',
            current_database();
    END IF;
    IF to_regclass('project1_ai.bdj_real_data_authorizations') IS NULL THEN
        RAISE EXCEPTION 'bdj_real_data_authorizations missing; apply 20261121_06 first';
    END IF;
    IF to_regclass('project1_ai.bdj_authorization_consumptions') IS NOT NULL THEN
        RAISE EXCEPTION 'bdj_authorization_consumptions exists: reconcile before migrating';
    END IF;
END $$;

CREATE TABLE project1_ai.bdj_authorization_consumptions (
  -- One row per authorization, ever. The second insert is a conflict.
  authorization_id uuid PRIMARY KEY
    REFERENCES project1_ai.bdj_real_data_authorizations (id),
  run_id           uuid NOT NULL,
  owner_user_id    uuid NOT NULL,
  attempt_no       integer NOT NULL CHECK (attempt_no >= 1),
  consumed_at      timestamptz NOT NULL DEFAULT now(),
  receipt          text NOT NULL CHECK (length(btrim(receipt)) > 0)
);

COMMENT ON TABLE project1_ai.bdj_authorization_consumptions IS
  'Append-only record that one BDJ authorization was spent by one attempt. '
  'The primary key on authorization_id is the single-use guarantee.';

-- Spend history is queried by run as well as by authorization.
CREATE INDEX ix_bdj_auth_consumption_run
  ON project1_ai.bdj_authorization_consumptions (run_id);

-- Append-only: the existing runs table uses the same helper.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'project1_ai' AND p.proname = 'deny_mutation') THEN
        EXECUTE 'CREATE TRIGGER bdj_auth_consumption_append_only '
             || 'BEFORE UPDATE OR DELETE ON project1_ai.bdj_authorization_consumptions '
             || 'FOR EACH ROW EXECUTE FUNCTION project1_ai.deny_mutation()';
    END IF;
END $$;

-- Row-level security: the same posture as every other project1_ai ledger
-- table (attempts, runs, attempt_receipts), not an unprotected island.
-- ``attempts`` is the closest analogue: p1ai_runtime writes it, the owner
-- reads it, and FORCE keeps the table owner subject to the policy too.
ALTER TABLE project1_ai.bdj_authorization_consumptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE project1_ai.bdj_authorization_consumptions FORCE ROW LEVEL SECURITY;

-- owner_scope is the only path to a row for any principal. It is keyed on the
-- transaction-local actor that ledger._scope binds via bind_m2_actor(), so an
-- INSERT whose owner_user_id is not the bound actor is refused by WITH CHECK,
-- and a SELECT cannot see another owner's spend.
CREATE POLICY owner_scope ON project1_ai.bdj_authorization_consumptions
  FOR ALL
  USING (owner_user_id = (NULLIF(current_setting('project1.actor_id', true), ''))::uuid)
  WITH CHECK (owner_user_id = (NULLIF(current_setting('project1.actor_id', true), ''))::uuid);

-- The reservation runs as p1ai_runtime (ledger._scope). INSERT is what the
-- spend needs; SELECT lets the same principal read back its own evidence.
GRANT INSERT, SELECT ON project1_ai.bdj_authorization_consumptions TO p1ai_runtime;

-- The authorization LOOKUP runs as p1_m2_runtime (see real_data_authorization).
-- It must be able to see whether a row has already been spent, otherwise a
-- consumed authorization would still be returned as live: the legacy
-- ``consumed_at`` column is never written by mechanism B. SELECT only.
GRANT SELECT ON project1_ai.bdj_authorization_consumptions TO p1_m2_runtime;

DO $$
BEGIN
    IF NOT has_table_privilege('p1ai_runtime',
                               'project1_ai.bdj_authorization_consumptions', 'INSERT') THEN
        RAISE EXCEPTION 'p1ai_runtime lacks INSERT on the consumption table';
    END IF;
    IF NOT has_table_privilege('p1_m2_runtime',
                               'project1_ai.bdj_authorization_consumptions', 'SELECT') THEN
        RAISE EXCEPTION 'p1_m2_runtime lacks SELECT on the consumption table';
    END IF;
    -- No mutation path may be acquired by either restricted principal.
    IF has_table_privilege('p1ai_runtime',
                           'project1_ai.bdj_authorization_consumptions', 'UPDATE')
       OR has_table_privilege('p1ai_runtime',
                              'project1_ai.bdj_authorization_consumptions', 'DELETE')
       OR has_table_privilege('p1_m2_runtime',
                              'project1_ai.bdj_authorization_consumptions', 'UPDATE')
       OR has_table_privilege('p1_m2_runtime',
                              'project1_ai.bdj_authorization_consumptions', 'DELETE') THEN
        RAISE EXCEPTION 'a restricted principal acquired a mutation privilege on consumption';
    END IF;
    -- The authorization binding must still be immutable.
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                    WHERE c.relname = 'bdj_real_data_authorizations'
                      AND t.tgname = 'bdj_real_auth_binding_immutable') THEN
        RAISE EXCEPTION 'authorization binding immutability trigger is missing';
    END IF;
    -- RLS must be on and forced, exactly as on the other ledger tables.
    IF NOT EXISTS (SELECT 1 FROM pg_class
                    WHERE oid = 'project1_ai.bdj_authorization_consumptions'::regclass
                      AND relrowsecurity AND relforcerowsecurity) THEN
        RAISE EXCEPTION 'consumption table must have RLS enabled and forced';
    END IF;
    -- No policy may be an unconditional allow: that is what owner_scope exists
    -- to prevent. A future migration that adds USING (true) fails here first.
    IF EXISTS (SELECT 1 FROM pg_policy
                WHERE polrelid = 'project1_ai.bdj_authorization_consumptions'::regclass
                  AND (polqual IS NULL OR polqual::text = 'true')) THEN
        RAISE EXCEPTION 'a policy on the consumption table is unconditional';
    END IF;
END $$;

COMMIT;
