-- CUST03 SYNTHETIC CANDIDATE ONLY — NOT AN APPROVED APPLICATION MIGRATION.

-- Kept outside alembic/ and supabase/migrations/ to prevent automatic discovery.

-- PostgreSQL execution, RLS/access review and production integration NOT VERIFIED.

-- No instrument, feature bank, concept, translation or approval is seeded.

BEGIN;

CREATE TABLE cq_candidate_sessions (
	id VARCHAR(80) NOT NULL, 
	purpose VARCHAR(32) NOT NULL, 
	revision INTEGER NOT NULL, 
	contract_digest VARCHAR(64) NOT NULL, 
	policy_digest VARCHAR(64) NOT NULL, 
	policy_snapshot JSON NOT NULL, 
	context JSON NOT NULL, 
	PRIMARY KEY (id), 
	CONSTRAINT ck_cq_synthetic_only CHECK (purpose = 'SYNTHETIC_ONLY'), 
	CONSTRAINT ck_cq_revision CHECK (revision >= 0)
);

CREATE TABLE cq_candidate_displays (
	id VARCHAR(36) NOT NULL, 
	session_id VARCHAR(80) NOT NULL, 
	question_id VARCHAR(3) NOT NULL, 
	feature_id VARCHAR(80) NOT NULL, 
	revision INTEGER NOT NULL, 
	context_digest VARCHAR(64) NOT NULL, 
	provenance JSON NOT NULL, 
	PRIMARY KEY (id), 
	CONSTRAINT uq_cq_display UNIQUE (session_id, question_id, feature_id, revision, context_digest), 
	FOREIGN KEY(session_id) REFERENCES cq_candidate_sessions (id)
);

CREATE TABLE cq_candidate_stimulus_exposures (
	id VARCHAR(36) NOT NULL, 
	session_id VARCHAR(80) NOT NULL, 
	revision INTEGER NOT NULL, 
	asset_kind VARCHAR(20) NOT NULL, 
	asset_digest VARCHAR(64) NOT NULL, 
	provenance JSON NOT NULL, 
	PRIMARY KEY (id), 
	CONSTRAINT uq_cq_exposure_revision UNIQUE (session_id, revision), 
	FOREIGN KEY(session_id) REFERENCES cq_candidate_sessions (id)
);

CREATE TABLE cq_candidate_structured_pretests (
	id VARCHAR(36) NOT NULL, 
	session_id VARCHAR(80) NOT NULL, 
	question_id VARCHAR(3) NOT NULL, 
	feature_id VARCHAR(80) NOT NULL, 
	locale VARCHAR(2) NOT NULL, 
	check_code VARCHAR(40) NOT NULL, 
	result_code VARCHAR(20) NOT NULL, 
	question_version VARCHAR(100) NOT NULL, 
	route_revision INTEGER NOT NULL, 
	policy_digest VARCHAR(64) NOT NULL, 
	option_bank_digest VARCHAR(64) NOT NULL, 
	PRIMARY KEY (id), 
	CONSTRAINT ck_cq_locale CHECK (locale IN ('EN','BM')), 
	CONSTRAINT ck_cq_pretest_result CHECK (result_code IN ('CORRECT','INCORRECT','UNSURE','NOT_APPLICABLE')), 
	FOREIGN KEY(session_id) REFERENCES cq_candidate_sessions (id)
);

CREATE TABLE cq_candidate_response_history (
	id VARCHAR(36) NOT NULL, 
	session_id VARCHAR(80) NOT NULL, 
	question_id VARCHAR(3) NOT NULL, 
	feature_id VARCHAR(80) NOT NULL, 
	revision INTEGER NOT NULL, 
	request_id VARCHAR(80) NOT NULL, 
	request_digest VARCHAR(64) NOT NULL, 
	display_id VARCHAR(36), 
	answer_state VARCHAR(32) NOT NULL, 
	raw_response JSON, 
	reason VARCHAR(160), 
	context_digest VARCHAR(64) NOT NULL, 
	provenance JSON NOT NULL, 
	PRIMARY KEY (id), 
	CONSTRAINT uq_cq_request UNIQUE (session_id, request_id), 
	CONSTRAINT uq_cq_answer_revision UNIQUE (session_id, question_id, feature_id, revision), 
	CONSTRAINT ck_cq_state CHECK (answer_state IN ('NOT_SHOWN','SKIPPED','REFUSED','INVALID','ANSWERED_SUBSTANTIVE','ANSWERED_NON_SUBSTANTIVE')), 
	FOREIGN KEY(session_id) REFERENCES cq_candidate_sessions (id), 
	FOREIGN KEY(display_id) REFERENCES cq_candidate_displays (id)
);

CREATE FUNCTION cq_candidate_history_append_only() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
    RAISE EXCEPTION 'Candidate history is append-only';
END $$;

CREATE TRIGGER cq_candidate_displays_append_only BEFORE UPDATE OR DELETE ON cq_candidate_displays
FOR EACH ROW EXECUTE FUNCTION cq_candidate_history_append_only();

CREATE TRIGGER cq_candidate_response_history_append_only BEFORE UPDATE OR DELETE ON cq_candidate_response_history
FOR EACH ROW EXECUTE FUNCTION cq_candidate_history_append_only();

CREATE TRIGGER cq_candidate_structured_pretests_append_only BEFORE UPDATE OR DELETE ON cq_candidate_structured_pretests
FOR EACH ROW EXECUTE FUNCTION cq_candidate_history_append_only();

CREATE TRIGGER cq_candidate_stimulus_exposures_append_only BEFORE UPDATE OR DELETE ON cq_candidate_stimulus_exposures
FOR EACH ROW EXECUTE FUNCTION cq_candidate_history_append_only();

COMMIT;
