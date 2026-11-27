-- Append-only guard: resolve the cp12 cleanup exemption lazily.
--
-- The defect this fixes
-- ---------------------
-- ``public.m2_bcb_reject_mutation()`` is the trigger function behind the
-- append-only guarantee on every versioned M2/BCB table (m2_answer_revisions,
-- m2_bdj_evaluations, m2_bdj_findings, m2_review_events,
-- m2_confirmation_snapshots, m2_confirmed_uncertainties, m2_clarification_events,
-- m2_business_contexts, m2_candidate_owner_reviews, m2_research_*,
-- m2_review_question_versions, assessment_workflow_projection).
--
-- ``migrations/cp12/dss_up.sql`` replaces its body with a version that permits
-- exactly one exemption: a DELETE issued by the owner of ``cp12.remove_draft``
-- while a matching ``cp12.operations`` row is PREPARED in the current xid. That
-- replacement writes the dependency as a cast:
--
--     current_user = pg_get_userbyid((SELECT proowner FROM pg_proc
--       WHERE oid = 'cp12.remove_draft(uuid,uuid,text)'::regprocedure))
--
-- ``'…'::regprocedure`` is a constant that PostgreSQL folds at PLAN time. It is
-- planned for every UPDATE and DELETE on those tables, not only for the branch
-- that needs it, so on a database that carries the replaced body but not the
-- ``cp12`` schema the trigger raises
--
--     42883  function "cp12.remove_draft(uuid,uuid,text)" does not exist
--
-- instead of
--
--     55000  Versioned M2/BCB source records are append-only
--
-- The protection still holds — the mutation is refused either way — but the
-- diagnostic is wrong, and it is wrong in the direction that matters: an
-- operator reading it concludes a function is missing rather than that the
-- table is immutable. Two behavioural tests assert the message and therefore
-- failed for a reason unrelated to what they test.
--
-- What changes
-- ------------
-- The cast becomes ``to_regprocedure('cp12.remove_draft(uuid,uuid,text)')``,
-- which returns NULL when the function is absent instead of raising, and is not
-- plan-time folded. The condition is otherwise unchanged, including the
-- ``current_setting('cp12.operation')`` match, the PREPARED phase check and the
-- ``cleanup_xid = pg_current_xact_id_if_assigned()`` check, all of which are
-- reached only when ``cp12`` exists.
--
-- Where ``cp12`` is installed the behaviour is identical, including the
-- exemption: the same function is found, the same owner is compared, the same
-- operation row is required. Nothing is widened.
--
-- No table, column, policy or grant changes. CREATE OR REPLACE preserves the
-- function's owner and its existing ACL (REVOKE ALL … FROM PUBLIC from
-- 20261113_01 is untouched).

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
BEGIN
  IF to_regclass('public.m2_candidate_owner_reviews') IS NULL THEN
    RAISE EXCEPTION 'public.m2_candidate_owner_reviews is missing; '
                    'apply 20261115_01 before this migration';
  END IF;
  IF to_regprocedure('public.m2_bcb_reject_mutation()') IS NULL THEN
    RAISE EXCEPTION 'public.m2_bcb_reject_mutation() is missing; '
                    'apply 20261113_01 before this migration';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.m2_bcb_reject_mutation() RETURNS trigger
LANGUAGE plpgsql AS $function$
DECLARE
    cleanup_fn    regprocedure;
    cleanup_owner oid;
BEGIN
    -- Resolve once. to_regprocedure() returns NULL rather than raising when the
    -- cp12 subsystem is absent, so this function no longer depends on a schema
    -- the public M2/BCB tables do not otherwise need.
    cleanup_fn := to_regprocedure('cp12.remove_draft(uuid,uuid,text)');

    IF TG_OP = 'DELETE'
       AND TG_TABLE_SCHEMA = 'public'
       AND TG_TABLE_NAME IN ('m2_answer_revisions', 'assessment_workflow_projection')
       AND cleanup_fn IS NOT NULL
    THEN
        SELECT proowner INTO cleanup_owner FROM pg_proc WHERE oid = cleanup_fn;
        IF current_user = pg_get_userbyid(cleanup_owner)
           AND EXISTS (
               SELECT FROM cp12.operations
                WHERE operation_id::text = current_setting('cp12.operation', true)
                  AND m2_id = OLD.assessment_id
                  AND phase = 'PREPARED'
                  AND cleanup_xid = pg_current_xact_id_if_assigned())
        THEN
            RETURN OLD;
        END IF;
    END IF;

    RAISE EXCEPTION 'Versioned M2/BCB source records are append-only'
        USING ERRCODE = '55000';
END $function$;

-- Prove it inside the same transaction. A silent no-op must not look like success.
DO $verify$
DECLARE
    body text;
BEGIN
    SELECT prosrc INTO body FROM pg_proc
     WHERE oid = 'public.m2_bcb_reject_mutation()'::regprocedure;

    IF body IS NULL THEN
        RAISE EXCEPTION 'm2_bcb_reject_mutation was not replaced';
    END IF;
    IF body LIKE '%::regprocedure)%' AND body NOT LIKE '%to_regprocedure%' THEN
        RAISE EXCEPTION 'the plan-time cp12 cast survived the replacement';
    END IF;
    IF body NOT LIKE '%to_regprocedure%' THEN
        RAISE EXCEPTION 'the lazy cp12 lookup is absent';
    END IF;
    IF body NOT LIKE '%append-only%' THEN
        RAISE EXCEPTION 'the append-only refusal message is absent';
    END IF;
    IF body NOT LIKE '%55000%' THEN
        RAISE EXCEPTION 'the append-only SQLSTATE is absent';
    END IF;

    -- The exemption must still be expressible when cp12 IS installed. This
    -- checks the text of the guard, not the subsystem: it must mention both the
    -- PREPARED phase and the xid match, or the discard path would silently stop
    -- working on databases that do have cp12.
    IF body NOT LIKE '%PREPARED%' OR body NOT LIKE '%cleanup_xid%' THEN
        RAISE EXCEPTION 'the cp12 exemption conditions were dropped';
    END IF;

    -- Every trigger that used the old function must still point at it.
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
         WHERE tgfoid = 'public.m2_bcb_reject_mutation()'::regprocedure
           AND NOT tgisinternal)
    THEN
        RAISE EXCEPTION 'no trigger is bound to m2_bcb_reject_mutation';
    END IF;
END
$verify$;

COMMIT;
