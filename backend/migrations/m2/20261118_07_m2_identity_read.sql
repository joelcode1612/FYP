-- CP-10 P2 — least-privilege read for the M2 identity check
--
-- STATUS: PREPARED ONLY. NOT APPLIED TO Dss.
--
-- MEASURED PROBLEM
--   p1_m2_runtime holds no privilege at all on public.users in Dss:
--     information_schema.role_table_grants   -> no rows
--     information_schema.column_privileges   -> no rows
--   AssessmentLinkService must answer two questions before creating anything:
--     1. does a Dss identity exist for this verified subject?
--     2. does its stored email agree with the token's verified email?
--   Without a grant it can answer neither, and it fails closed with
--   IDENTITY_CHECK_UNAVAILABLE.
--
-- LEAST-PRIVILEGE CHOICE
--   Column-level SELECT on exactly two columns, not table-level SELECT.
--   The service never reads role, account_status, password material or any
--   other column of public.users, so it must not be able to.
--
-- WHY NOT SKIP THE CHECK
--   The FK fk_m2_owner_user already proves the user exists at INSERT time, but
--   it cannot detect the case where the same UUID carries a different email in
--   the two databases. That is the collision the directive requires refusing
--   with IDENTITY_COLLISION, and it needs the email column.

BEGIN;

GRANT SELECT (user_id, email) ON public.users TO p1_m2_runtime;

COMMIT;
