-- =====================================================================
-- 20261124_22_bdj_consumption_owner_guard.sql
--
-- Purpose
--   Close an ownership gap found by the DD-005 database proof.
--
-- The gap
--   ``owner_scope`` compares the row being inserted with the actor bound in the
--   transaction:
--
--       owner_user_id = current_setting('project1.actor_id')
--
--   That proves the writer is consistent with itself, not that the
--   authorization being spent belongs to that writer. A caller could bind its
--   own actor id, set ``owner_user_id`` to the same value, and insert a spend
--   for *another owner's* authorization id. The primary key still holds, so
--   this is not a double-spend and not a disclosure; it is an unauthorized
--   consumption (a denial of service against the rightful owner's single-use
--   grant). Owner decision §1.4 requires unauthorized consumption to be
--   prevented, and §1.6 requires ownership to be revalidated.
--
-- Why a SECURITY DEFINER function
--   The checking principal, ``p1ai_runtime``, deliberately has no privilege and
--   no policy on ``bdj_real_data_authorizations``; that separation is what
--   DD-008 established and it must not be widened. A trigger therefore cannot
--   read the authorization as the invoking user. The function below is the
--   narrowest construct that can answer one question:
--
--       "does this authorization belong to this owner?"
--
--   It is not an unrestricted privileged path: it reads two columns, returns
--   nothing, is invocable only as a trigger (no EXECUTE is granted to any
--   principal), pins ``search_path``, and can only raise.
--
-- Safety
--   Isolated PG18 test database only. No privilege is granted to any principal.
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
    IF to_regclass('project1_ai.bdj_authorization_consumptions') IS NULL THEN
        RAISE EXCEPTION 'consumption table missing; apply 20261124_21 first';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                WHERE c.relname = 'bdj_authorization_consumptions'
                  AND t.tgname = 'bdj_consumption_owner_guard') THEN
        RAISE EXCEPTION 'owner guard already present: reconcile before migrating';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION project1_ai.bdj_consumption_owner_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
-- A definer function without a pinned search_path is a privilege-escalation
-- vector; this one resolves every name explicitly and needs no path at all.
SET search_path TO 'pg_catalog'
AS $function$
DECLARE
    actual_owner uuid;
BEGIN
    SELECT m.owner_user_id
      INTO actual_owner
      FROM project1_ai.bdj_real_data_authorizations a
      JOIN public.m2_assessments m ON m.id = a.assessment_id
     WHERE a.id = NEW.authorization_id;

    IF actual_owner IS NULL THEN
        -- The FK already guarantees the row exists, so this means the
        -- assessment is unreachable. Refuse rather than assume ownership.
        RAISE EXCEPTION 'BDJ_AUTHORIZATION_OWNER_UNRESOLVED'
            USING ERRCODE = '42501';
    END IF;

    IF actual_owner <> NEW.owner_user_id THEN
        RAISE EXCEPTION 'BDJ_AUTHORIZATION_NOT_OWNED_BY_ACTOR'
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END
$function$;

COMMENT ON FUNCTION project1_ai.bdj_consumption_owner_guard() IS
  'Refuses a spend whose owner_user_id is not the owner of the authorization. '
  'Narrow SECURITY DEFINER because p1ai_runtime cannot read the authorization.';

CREATE TRIGGER bdj_consumption_owner_guard
  BEFORE INSERT ON project1_ai.bdj_authorization_consumptions
  FOR EACH ROW EXECUTE FUNCTION project1_ai.bdj_consumption_owner_guard();

-- The function must not be callable by anyone: a trigger fires it regardless of
-- EXECUTE privilege, so revoking keeps it off the SQL surface entirely.
REVOKE ALL ON FUNCTION project1_ai.bdj_consumption_owner_guard() FROM PUBLIC;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                    WHERE c.relname = 'bdj_authorization_consumptions'
                      AND t.tgname = 'bdj_consumption_owner_guard') THEN
        RAISE EXCEPTION 'owner guard trigger was not created';
    END IF;
    -- The append-only trigger from 20261124_21 must still be present.
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                    WHERE c.relname = 'bdj_authorization_consumptions'
                      AND t.tgname = 'bdj_auth_consumption_append_only') THEN
        RAISE EXCEPTION 'append-only trigger disappeared';
    END IF;
    -- No principal may hold EXECUTE on the definer function.
    IF has_function_privilege('p1ai_runtime',
                              'project1_ai.bdj_consumption_owner_guard()', 'EXECUTE')
       OR has_function_privilege('p1_m2_runtime',
                                 'project1_ai.bdj_consumption_owner_guard()', 'EXECUTE') THEN
        RAISE EXCEPTION 'a restricted principal can execute the definer guard directly';
    END IF;
END $$;

COMMIT;
