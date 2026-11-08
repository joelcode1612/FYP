-- Project1 M2 upstream foundation migration candidate — P0-02
-- Apply ONLY if the team confirms Supabase SQL migrations are the sole schema authority.
-- DO NOT apply to shared/production databases until approved, backed up and tested on a clone.
-- Creates schema only; does NOT seed or authorize an M2 instrument.
-- QJ and QG remain held.
-- The source metadata is sitewise/db/m2_schema.py in the 2026-11-07 patch.
-- Prerequisites: public.users(user_id UUID PRIMARY KEY) exists and 9 M2 tables do not.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $preflight$
BEGIN
    IF to_regclass('public.users') IS NULL THEN
        RAISE EXCEPTION 'M2 preflight: public.users is absent; reconcile application schema before migration';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = 'users'
          AND a.attname = 'user_id' AND a.atttypid = 'pg_catalog.uuid'::regtype
          AND a.attnotnull AND NOT a.attisdropped
    ) THEN
        RAISE EXCEPTION 'M2 preflight: public.users.user_id must be a non-null UUID';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(con.conkey)
        WHERE n.nspname = 'public' AND c.relname = 'users'
          AND con.contype = 'p' AND array_length(con.conkey, 1) = 1
          AND a.attname = 'user_id'
    ) THEN
        RAISE EXCEPTION 'M2 preflight: public.users.user_id must be the single-column primary key';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_tables
        WHERE schemaname = 'public' AND tablename IN (
            'm2_instrument_versions','m2_item_versions','m2_assessments',
            'm2_answer_revisions','m2_bdj_evaluations','m2_bdj_findings',
            'm2_review_events','m2_confirmation_snapshots','m2_confirmed_uncertainties'
        )
    ) THEN
        RAISE EXCEPTION 'M2 preflight: one or more target tables already exist; stop and reconcile drift';
    END IF;
END
$preflight$;

CREATE TABLE public.m2_instrument_versions (
	id UUID NOT NULL, 
	code VARCHAR(32) NOT NULL, 
	version_tag VARCHAR(100) NOT NULL, 
	approval_state VARCHAR(24) NOT NULL, 
	schema_digest VARCHAR(64) NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (id), 
	CONSTRAINT uq_m2_instrument_code_version UNIQUE (code, version_tag)
);

CREATE TABLE public.m2_assessments (
	id UUID NOT NULL, 
	owner_user_id UUID NOT NULL, 
	instrument_id UUID NOT NULL, 
	revision INTEGER NOT NULL, 
	confirmed_revision INTEGER, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(instrument_id) REFERENCES public.m2_instrument_versions (id)
);

CREATE TABLE public.m2_item_versions (
	id UUID NOT NULL, 
	instrument_id UUID NOT NULL, 
	item_key VARCHAR(32) NOT NULL, 
	question_text TEXT NOT NULL, 
	requiredness VARCHAR(24) NOT NULL, 
	answer_kind VARCHAR(20) NOT NULL, 
	option_values JSON NOT NULL, 
	allowed_states JSON NOT NULL, 
	lifecycle VARCHAR(24) NOT NULL, 
	sort_order INTEGER NOT NULL, 
	PRIMARY KEY (id), 
	CONSTRAINT uq_m2_item_instrument_key UNIQUE (instrument_id, item_key), 
	FOREIGN KEY(instrument_id) REFERENCES public.m2_instrument_versions (id)
);

CREATE TABLE public.m2_answer_revisions (
	id UUID NOT NULL, 
	assessment_id UUID NOT NULL, 
	item_version_id UUID NOT NULL, 
	assessment_revision INTEGER NOT NULL, 
	answer_state VARCHAR(32) NOT NULL, 
	value_json JSON, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (id), 
	CONSTRAINT uq_m2_answer_revision UNIQUE (assessment_id, item_version_id, assessment_revision), 
	FOREIGN KEY(assessment_id) REFERENCES public.m2_assessments (id), 
	FOREIGN KEY(item_version_id) REFERENCES public.m2_item_versions (id)
);

CREATE TABLE public.m2_bdj_evaluations (
	id UUID NOT NULL, 
	assessment_id UUID NOT NULL, 
	assessment_revision INTEGER NOT NULL, 
	evaluator_version VARCHAR(64) NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (id), 
	CONSTRAINT uq_m2_bdj_evaluation UNIQUE (assessment_id, assessment_revision, evaluator_version), 
	FOREIGN KEY(assessment_id) REFERENCES public.m2_assessments (id)
);

CREATE TABLE public.m2_bdj_findings (
	id UUID NOT NULL, 
	assessment_id UUID NOT NULL, 
	assessment_revision INTEGER NOT NULL, 
	rule_id VARCHAR(64) NOT NULL, 
	rule_version VARCHAR(32) NOT NULL, 
	source_answer_ids JSON NOT NULL, 
	issue_type VARCHAR(48) NOT NULL, 
	explanation TEXT NOT NULL, 
	not_proven TEXT NOT NULL, 
	next_action TEXT NOT NULL, 
	review_state VARCHAR(24) NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (id), 
	CONSTRAINT uq_m2_bdj_rule_revision UNIQUE (assessment_id, assessment_revision, rule_id, rule_version), 
	FOREIGN KEY(assessment_id) REFERENCES public.m2_assessments (id)
);

CREATE TABLE public.m2_confirmation_snapshots (
	id UUID NOT NULL, 
	assessment_id UUID NOT NULL, 
	assessment_revision INTEGER NOT NULL, 
	actor_user_id UUID NOT NULL, 
	snapshot_json JSON NOT NULL, 
	snapshot_digest VARCHAR(64) NOT NULL, 
	acknowledged_issue_ids JSON NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (id), 
	CONSTRAINT uq_m2_confirmation_revision UNIQUE (assessment_id, assessment_revision), 
	FOREIGN KEY(assessment_id) REFERENCES public.m2_assessments (id)
);

CREATE TABLE public.m2_review_events (
	id UUID NOT NULL, 
	assessment_id UUID NOT NULL, 
	assessment_revision INTEGER NOT NULL, 
	actor_user_id UUID NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (id), 
	CONSTRAINT uq_m2_review_revision UNIQUE (assessment_id, assessment_revision), 
	FOREIGN KEY(assessment_id) REFERENCES public.m2_assessments (id)
);

CREATE TABLE public.m2_confirmed_uncertainties (
	id UUID NOT NULL, 
	confirmation_id UUID NOT NULL, 
	actor_user_id UUID NOT NULL, 
	exact_text TEXT NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(confirmation_id) REFERENCES public.m2_confirmation_snapshots (id)
);

CREATE INDEX ix_m2_assessments_owner_user_id ON public.m2_assessments (owner_user_id);

CREATE INDEX ix_m2_answer_revisions_assessment_id ON public.m2_answer_revisions (assessment_id);


-- Strengthen referential integrity. The application uses verified Supabase UUIDs,
-- while public.users contains the authoritative locally provisioned profile.
ALTER TABLE public.m2_assessments
    ADD CONSTRAINT fk_m2_owner_user FOREIGN KEY (owner_user_id)
    REFERENCES public.users (user_id) ON DELETE RESTRICT;
ALTER TABLE public.m2_review_events
    ADD CONSTRAINT fk_m2_review_actor FOREIGN KEY (actor_user_id)
    REFERENCES public.users (user_id) ON DELETE RESTRICT;
ALTER TABLE public.m2_confirmation_snapshots
    ADD CONSTRAINT fk_m2_confirmation_actor FOREIGN KEY (actor_user_id)
    REFERENCES public.users (user_id) ON DELETE RESTRICT;
ALTER TABLE public.m2_confirmed_uncertainties
    ADD CONSTRAINT fk_m2_uncertainty_actor FOREIGN KEY (actor_user_id)
    REFERENCES public.users (user_id) ON DELETE RESTRICT;

ALTER TABLE public.m2_assessments
    ADD CONSTRAINT ck_m2_assessment_revision CHECK
    (revision >= 0 AND (confirmed_revision IS NULL OR
       (confirmed_revision >= 0 AND confirmed_revision <= revision)));
ALTER TABLE public.m2_answer_revisions
    ADD CONSTRAINT ck_m2_answer_revision CHECK (assessment_revision > 0);
ALTER TABLE public.m2_bdj_findings
    ADD CONSTRAINT ck_m2_bdj_finding_revision CHECK (assessment_revision >= 0);
ALTER TABLE public.m2_bdj_evaluations
    ADD CONSTRAINT ck_m2_bdj_evaluation_revision CHECK (assessment_revision >= 0);
ALTER TABLE public.m2_review_events
    ADD CONSTRAINT ck_m2_review_revision CHECK (assessment_revision >= 0);
ALTER TABLE public.m2_confirmation_snapshots
    ADD CONSTRAINT ck_m2_confirmation_revision CHECK (assessment_revision >= 0);
ALTER TABLE public.m2_confirmed_uncertainties
    ADD CONSTRAINT ck_m2_uncertainty_nonblank CHECK (length(btrim(exact_text)) > 0);

CREATE INDEX ix_m2_findings_assessment_revision
    ON public.m2_bdj_findings (assessment_id, assessment_revision);
CREATE INDEX ix_m2_evaluations_assessment_revision
    ON public.m2_bdj_evaluations (assessment_id, assessment_revision);
CREATE INDEX ix_m2_review_events_assessment_revision
    ON public.m2_review_events (assessment_id, assessment_revision);
CREATE INDEX ix_m2_confirmation_assessment_revision
    ON public.m2_confirmation_snapshots (assessment_id, assessment_revision);
CREATE INDEX ix_m2_uncertainties_confirmation_id
    ON public.m2_confirmed_uncertainties (confirmation_id);

-- Fail closed for Supabase Data API roles. The FastAPI backend currently uses
-- DB session connections and performs its own assessment-owner checks; a DB
-- role with table ownership or BYPASSRLS can bypass RLS, so this does NOT prove
-- API isolation. All backend cross-tenant checks must still be integration-tested.
DO $rls$
DECLARE table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'm2_instrument_versions','m2_item_versions','m2_assessments',
        'm2_answer_revisions','m2_bdj_evaluations','m2_bdj_findings',
        'm2_review_events','m2_confirmation_snapshots','m2_confirmed_uncertainties'
    ] LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', table_name);
        EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC', table_name);
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
            EXECUTE format('REVOKE ALL ON TABLE public.%I FROM anon', table_name);
        END IF;
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
            EXECUTE format('REVOKE ALL ON TABLE public.%I FROM authenticated', table_name);
        END IF;
    END LOOP;
END
$rls$;

-- No policies are created, therefore anon/authenticated Data API requests
-- are denied even if other privileges are later granted. Adding policies
-- requires separate role/security design and access-denial tests.
-- No rows are seeded. Existing app defaults and QJ/QG are untouched.
COMMIT;



