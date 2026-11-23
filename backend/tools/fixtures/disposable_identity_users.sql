-- TEST FIXTURE — disposable clone only. NOT a product migration.
--
-- Why this file exists
-- --------------------
-- The authorised Gate B/C target (``project1_workflow_tests`` on port 5433) is a
-- clone of the M2/BCB/objective schema only: it carries public.m2_* and
-- project1_ai.* but no application identity table. The real FastAPI
-- authentication chain (bearer JWT -> verified subject -> authoritative
-- profile -> public.users mirror) therefore cannot run there, and pointing the
-- application's main engine at Final_Location_Analysis to borrow its users
-- table would write to a protected database.
--
-- This file provisions ONLY the identity table the auth chain reads, owned by
-- the restricted M2 principal so no superuser write connection is needed. It
-- creates no rows: the E2E harness inserts its own uniquely identified
-- synthetic entrepreneur and reports it as disposable test data.
--
-- It is deliberately NOT placed under migrations/sql because it is not part of
-- the product schema and must never be applied to a real environment.

DO $$
BEGIN
    IF current_database() <> 'project1_workflow_tests' THEN
        RAISE EXCEPTION 'REFUSED: identity fixture is disposable-only (current_database=%)',
            current_database();
    END IF;
    IF (SELECT inet_server_port()) = 5432 THEN
        RAISE EXCEPTION 'REFUSED: identity fixture must not run on the default port';
    END IF;
END $$;

-- Mirrors sitewise.db.models.user.User (SQLModel) exactly:
--   user_id PK, email unique/indexed, role/account_status varchar(20).
CREATE TABLE IF NOT EXISTS public.users (
    user_id             uuid         PRIMARY KEY,
    full_name           varchar,
    email               varchar(255) NOT NULL,
    phone_number        varchar(20),
    role                varchar(20)  NOT NULL DEFAULT 'entrepreneur',
    profile_picture_url varchar,
    account_status      varchar(20)  NOT NULL DEFAULT 'pending',
    email_verified      boolean      NOT NULL DEFAULT false,
    last_login          timestamptz,
    created_at          timestamptz  NOT NULL DEFAULT now(),
    updated_at          timestamptz  NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ix_users_email ON public.users (email);

-- The application's main engine connects as the restricted M2 principal on this
-- disposable cluster, so ownership is transferred rather than granted broadly.
ALTER TABLE public.users OWNER TO p1_m2_runtime;
