-- CP-10 — identity verification returning a VERDICT, never an email
--
-- STATUS: PREPARED ONLY. NOT APPLIED TO Dss. Awaiting Owner approval.
-- Replaces the withdrawn 20261118_08_m2_actor_email_function.sql.
--
-- WHY THE PREVIOUS DESIGN WAS REJECTED
--   The withdrawn function returned the actor's email. It was parameterless, which
--   looked safe, but the actor is taken from the session setting project1.actor_id,
--   and any role may set a custom GUC:
--
--       SET ROLE p1_m2_runtime;
--       SET project1.actor_id='11111111-1111-4111-8111-111111111111';
--       SELECT public.m2_actor_email();   -- -> cp02.synthetic@example.test
--
--   Measured in an isolated copy. So "parameterless" proves nothing about
--   authenticity, and the function was equivalent to handing over the users table
--   for any UUID the caller names.
--
-- WHAT CHANGED
--   The function now takes the caller's *expected* email (which the backend already
--   holds from the verified JWT) and returns one of three verdicts:
--
--       'MATCH'      the stored email equals the expected one
--       'COLLISION'  a user exists under this subject but the email differs
--       'MISSING'    no user row for this subject, or no expected email supplied
--
--   No email, and no other column, is ever returned. A caller who can spoof the
--   actor setting gains nothing it did not already supply: to obtain 'MATCH' it
--   must already know the stored address. The function is a confirmation oracle at
--   worst, not a disclosure.
--
-- WHAT THIS DOES **NOT** PROVE
--   It does not authenticate the actor. Nothing database-side can, because the GUC
--   is writable by the calling role. Actor authenticity comes from the backend,
--   which sets project1.actor_id from the verified JWT subject and never from a
--   request body. This function must be read as "does the stored identity agree
--   with the token the backend just verified", not as "prove who is calling".
--
--   The authorisation boundary for M2 data remains the existing RLS policies, which
--   have exactly the same trust assumption.

BEGIN;

-- Remove the withdrawn variant if a previous experiment installed it.
DROP FUNCTION IF EXISTS public.m2_actor_email();

CREATE OR REPLACE FUNCTION public.m2_identity_status(p_expected_email text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_email text;
BEGIN
    IF p_expected_email IS NULL OR btrim(p_expected_email) = '' THEN
        RETURN 'MISSING';
    END IF;

    SELECT u.email
      INTO v_email
      FROM public.users u
     WHERE u.user_id = (NULLIF(current_setting('project1.actor_id', true), ''))::uuid;

    IF NOT FOUND OR v_email IS NULL OR btrim(v_email) = '' THEN
        RETURN 'MISSING';
    END IF;

    IF lower(btrim(v_email)) = lower(btrim(p_expected_email)) THEN
        RETURN 'MATCH';
    END IF;

    RETURN 'COLLISION';
END
$$;

REVOKE ALL ON FUNCTION public.m2_identity_status(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.m2_identity_status(text) TO p1_m2_runtime;

COMMIT;
