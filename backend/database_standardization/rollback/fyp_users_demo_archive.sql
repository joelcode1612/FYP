-- Archive of fyp.users (pre-auth demo row) taken before canonical_fyp_schema migration 0014.
-- Restore manually only if that account is ever needed; it has NO Supabase auth identity.
BEGIN;
CREATE SCHEMA IF NOT EXISTS fyp_archive;
CREATE TABLE IF NOT EXISTS fyp_archive.users_pre_auth_demo (LIKE fyp.users INCLUDING ALL);
INSERT INTO fyp_archive.users_pre_auth_demo (id,email,password_hash,full_name,phone,role,is_active,created_at,updated_at) VALUES ('8', 'owner@fyp.demo', '$2b$12$W6gug4VtW4PSS47nmjPdLuzj29REu0iDq44btrA7ntk.V0Vc2mhqm', 'Demo Property Owner', NULL, 'owner', 'True', '2026-09-20 14:49:59.919433+08:00', '2026-09-20 14:49:59.919433+08:00');
COMMIT;