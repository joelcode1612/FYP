-- Rollback for 20261126_01_append_only_guard_lazy_cp12.sql
--
-- Restores the body that ``migrations/cp12/dss_up.sql`` installed, i.e. the one
-- with the plan-time ``'cp12.remove_draft(uuid,uuid,text)'::regprocedure`` cast.
--
-- This rollback is deliberately NOT a return to the pre-cp12 body from
-- 20261113_01. On a database where cp12 is installed the two are not
-- equivalent: the cp12 body carries the discard exemption, and restoring the
-- simple body would break ``cp12.remove_draft`` by making every DELETE it issues
-- refuse. The rollback therefore restores exactly what the forward migration
-- replaced, and refuses to run when the cp12 schema is absent, because in that
-- state there is nothing meaningful to restore.

BEGIN;

DO $guard$
BEGIN
    IF to_regprocedure('cp12.remove_draft(uuid,uuid,text)') IS NULL THEN
        RAISE EXCEPTION 'cp12.remove_draft is absent; the forward migration '
                        'replaced nothing that can be restored here';
    END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.m2_bcb_reject_mutation() RETURNS trigger
LANGUAGE plpgsql AS $function$
BEGIN
 IF TG_OP='DELETE' AND TG_TABLE_SCHEMA='public' AND TG_TABLE_NAME IN ('m2_answer_revisions','assessment_workflow_projection')
 AND current_user=pg_get_userbyid((SELECT proowner FROM pg_proc WHERE oid='cp12.remove_draft(uuid,uuid,text)'::regprocedure))
 AND EXISTS(SELECT FROM cp12.operations WHERE operation_id::text=current_setting('cp12.operation',true) AND m2_id=OLD.assessment_id AND phase='PREPARED' AND cleanup_xid=pg_current_xact_id_if_assigned()) THEN RETURN OLD; END IF;
 RAISE EXCEPTION 'Versioned M2/BCB source records are append-only' USING ERRCODE='55000';
END $function$;

COMMIT;
