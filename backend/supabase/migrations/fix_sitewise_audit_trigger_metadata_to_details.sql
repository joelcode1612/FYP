-- ---------------------------------------------------------------------------
-- Sitewise LIVE FIX — public.sitewise_audit_user_role_status()
--
-- CONFIRMED DEFECT (reproduced on the live project):
--   insert into auth.users (...) ->
--   column "metadata" of relation "role_change_audit" does not exist
--
-- The audit trigger on public.users writes to a column named `metadata`, but
-- the live `public.role_change_audit` table has `details` (jsonb NOT NULL,
-- default '{}'). Because the trigger fires on EVERY public.users insert, both
-- GoTrue user creation (Supabase invite) and the backend's identity upsert
-- failed — surfacing as "Database error saving new user" and a 502 on
-- POST /api/v1/staff/agents.
--
-- CHANGE: exactly one column name, `metadata` -> `details`. Function body,
-- SECURITY DEFINER, search_path and all audit semantics are otherwise
-- unchanged. No table, column, policy, RLS or data is modified.
-- Rollback: supabase/migrations/rollback_sitewise_audit_user_role_status.sql
-- ---------------------------------------------------------------------------

begin;

create or replace function public.sitewise_audit_user_role_status()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'auth', 'pg_temp'
as $function$
declare
    v_actor uuid;
    v_action text;
    v_old_role text;
    v_old_status text;
begin
    v_actor := auth.uid();

    if tg_op = 'INSERT' then
        v_action := 'initial_role_assigned';
        v_old_role := null;
        v_old_status := null;
    else
        v_old_role := old.role::text;
        v_old_status := old.account_status::text;
        if old.role is distinct from new.role then
            v_action := 'role_changed';
        elsif old.account_status is distinct from new.account_status then
            v_action := case
                when new.account_status = 'suspended' then 'account_suspended'
                when old.account_status = 'suspended' and new.account_status = 'active' then 'account_reactivated'
                else 'account_status_changed'
            end;
        else
            return new;
        end if;
    end if;

    insert into public.role_change_audit (
        user_id_affected,
        affected_email_snapshot,
        changed_by_user_id,
        old_role,
        new_role,
        old_account_status,
        new_account_status,
        action,
        details            -- was: metadata  (column does not exist)
    ) values (
        new.user_id,
        new.email,
        case when exists (select 1 from public.users u where u.user_id = v_actor) then v_actor else null end,
        v_old_role,
        new.role::text,
        v_old_status,
        new.account_status::text,
        v_action,
        jsonb_build_object('audit_source', case when v_actor is null then 'system_or_service_backend' else 'authenticated_session' end)
    );

    return new;
end;
$function$;

commit;
