
-- Users foundation for the existing Dss application database.
-- Review and test before execution.
-- Does not create a new database.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE public.users (
    user_id UUID NOT NULL,
    full_name VARCHAR,
    email VARCHAR(255) NOT NULL,
    phone_number VARCHAR(20),
    role VARCHAR(20) NOT NULL,
    profile_picture_url VARCHAR,
    account_status VARCHAR(20) NOT NULL,
    email_verified BOOLEAN NOT NULL,
    last_login TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL,
    PRIMARY KEY (user_id)
);

COMMIT;