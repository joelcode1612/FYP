-- =====================================================================
-- 20261124_23_bdj_consumption_guard_expiry.sql
--
-- Purpose
--   Make the owner guard the authoritative "still spendable" check, so expiry
--   and legacy consumption are enforced INSIDE the reservation transaction
--   rather than only by an application read on another connection.
--
-- Why this is needed
--   The DD-005 proof showed the database accepted a spend against an
--   authorization that had already expired (expires_at 04:24:20, spend attempted
--   at 04:59). ``load()`` filters ``expires_at > now()`` and the disclosure
--   re-checks it, but both run as ``p1_m2_runtime`` on a different connection
--   from the ``p1ai_runtime`` reservation, so a row that expires in between is
--   still spendable. §1.6 requires expiry to be revalidated, and the only place
--   that can be atomic is this trigger.
--
-- What the guard now refuses
--   1. the authorization does not belong to the spending owner  (42501)
--   2. the authorization has expired                            (42501)
--   3. the authorization was already spent by the legacy mechanism, i.e.
--      ``consumed_at`` is set — a pre-mechanism-B row must not be spendable
--      a second time through the new table                    (42501)
--
-- Scope is unchanged: the function reads four columns, returns nothing, can only
-- raise, is not callable from SQL, and EXECUTE stays revoked from PUBLIC.
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
    IF to_regprocedure('project1_ai.bdj_consumption_owner_guard()') IS NULL THEN
        RAISE EXCEPTION 'owner guard missing; apply 20261124_22 first';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION project1_ai.bdj_consumption_owner_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog'
AS $function$
DECLARE
    actual_owner  uuid;
    row_expires   timestamptz;
    legacy_spent  timestamptz;
BEGIN
    SELECT m.owner_user_id, a.expires_at, a.consumed_at
      INTO actual_owner, row_expires, legacy_spent
      FROM project1_ai.bdj_real_data_authorizations a
      JOIN public.m2_assessments m ON m.id = a.assessment_id
     WHERE a.id = NEW.authorization_id;

    IF actual_owner IS NULL THEN
        RAISE EXCEPTION 'BDJ_AUTHORIZATION_OWNER_UNRESOLVED'
            USING ERRCODE = '42501';
    END IF;

    IF actual_owner <> NEW.owner_user_id THEN
        RAISE EXCEPTION 'BDJ_AUTHORIZATION_NOT_OWNED_BY_ACTOR'
            USING ERRCODE = '42501';
    END IF;

    -- Expiry is checked here, not only in load(), because this is the only
    -- place that shares a transaction with the attempt reservation.
    --
    -- clock_timestamp(), not now(): now() is the TRANSACTION START time, so a
    -- long-running transaction would compare expiry against a timestamp from
    -- before the row expired and accept it. clock_timestamp() is the actual
    -- wall clock at the moment of the insert.
    IF row_expires IS NULL OR row_expires <= clock_timestamp() THEN
        RAISE EXCEPTION 'BDJ_AUTHORIZATION_EXPIRED'
            USING ERRCODE = '42501';
    END IF;

    -- A row spent before mechanism B existed must not be spendable again
    -- through the new table: that would be a second use of one authorization.
    IF legacy_spent IS NOT NULL THEN
        RAISE EXCEPTION 'BDJ_AUTHORIZATION_ALREADY_CONSUMED'
            USING ERRCODE = '23505';
    END IF;

    RETURN NEW;
END
$function$;

COMMENT ON FUNCTION project1_ai.bdj_consumption_owner_guard() IS
  'Refuses a spend when the authorization is not owned by the actor, has '
  'expired, or was already spent by the legacy consumed_at mechanism.';

DO $$
BEGIN
    IF has_function_privilege('p1ai_runtime',
                              'project1_ai.bdj_consumption_owner_guard()', 'EXECUTE')
       OR has_function_privilege('p1_m2_runtime',
                                 'project1_ai.bdj_consumption_owner_guard()', 'EXECUTE') THEN
        RAISE EXCEPTION 'a restricted principal can execute the definer guard directly';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                    WHERE c.relname = 'bdj_authorization_consumptions'
                      AND t.tgname = 'bdj_consumption_owner_guard') THEN
        RAISE EXCEPTION 'owner guard trigger disappeared';
    END IF;
END $$;

COMMIT;
