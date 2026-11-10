-- Rollback: restores the ORIGINAL (broken) definition captured before the fix.
-- Only use if the corrected function must be reverted verbatim.
CREATE OR REPLACE FUNCTION public.sitewise_audit_user_role_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
    v_actor uuid;
    v_action text;
    v_old_role text;
    v_old_status text;
BEGIN
    v_actor := auth.uid();

    IF TG_OP = 'INSERT' THEN
        v_action := 'initial_role_assigned';
        v_old_role := NULL;
        v_old_status := NULL;
    ELSE
        v_old_role := OLD.role::text;
        v_old_status := OLD.account_status::text;
        IF OLD.role IS DISTINCT FROM NEW.role THEN
            v_action := 'role_changed';
        ELSIF OLD.account_status IS DISTINCT FROM NEW.account_status THEN
            v_action := CASE
                WHEN NEW.account_status = 'suspended' THEN 'account_suspended'
                WHEN OLD.account_status = 'suspended' AND NEW.account_status = 'active' THEN 'account_reactivated'
                ELSE 'account_status_changed'
            END;
        ELSE
            RETURN NEW;
        END IF;
    END IF;

    INSERT INTO public.role_change_audit (
        user_id_affected,
        affected_email_snapshot,
        changed_by_user_id,
        old_role,
        new_role,
        old_account_status,
        new_account_status,
        action,
        metadata
    ) VALUES (
        NEW.user_id,
        NEW.email,
        CASE WHEN EXISTS (SELECT 1 FROM public.users u WHERE u.user_id = v_actor) THEN v_actor ELSE NULL END,
        v_old_role,
        NEW.role::text,
        v_old_status,
        NEW.account_status::text,
        v_action,
        jsonb_build_object('audit_source', CASE WHEN v_actor IS NULL THEN 'system_or_service_backend' ELSE 'authenticated_session' END)
    );

    RETURN NEW;
END;
$function$
;
