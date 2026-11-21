-- REVIEW ONLY for live Dss. Test solely in a NEW private PostgreSQL cluster.
BEGIN;
SET LOCAL lock_timeout='5s';
DO $$ BEGIN
 IF current_setting('project1.cq_migration_target',true) IS DISTINCT FROM current_database()
    OR nullif(current_setting('project1.cq_migration_receipt',true),'') IS NULL THEN
   RAISE EXCEPTION 'Explicit CQ migration target and operator receipt required';
 END IF;
END $$;
CREATE TABLE cq_bank_versions(
 version varchar(100) PRIMARY KEY,content_hash varchar(64) NOT NULL,questions_json jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),CHECK(content_hash ~ '^[0-9a-f]{64}$')
);
CREATE TABLE cq_manifest_releases(
 id uuid PRIMARY KEY,manifest_hash varchar(64) NOT NULL UNIQUE,policy_hash varchar(64) NOT NULL,
 manifest_json jsonb NOT NULL,policy_json jsonb NOT NULL,source_class varchar(32) NOT NULL
 CHECK(source_class IN ('ADOPTED','CANDIDATE','SYNTHETIC_FIXTURE')),
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(manifest_hash ~ '^[0-9a-f]{64}$' AND policy_hash ~ '^[0-9a-f]{64}$')
);
CREATE TABLE cq_question_assignments(
 release_id uuid NOT NULL REFERENCES cq_manifest_releases(id),slot_id varchar(100) NOT NULL,
 question_id varchar(3) NOT NULL CHECK(question_id ~ '^Q(0[1-9]|1[0-3])$'),
 question_version varchar(100) NOT NULL,bank_version varchar(100) NOT NULL REFERENCES cq_bank_versions(version),content_hash varchar(64) NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(release_id,slot_id)
);
CREATE TABLE cq_campaigns(
 id uuid PRIMARY KEY,assessment_id uuid NOT NULL UNIQUE REFERENCES m2_assessments(id),
 owner_user_id uuid NOT NULL REFERENCES users(user_id),release_id uuid NOT NULL REFERENCES cq_manifest_releases(id),
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(id,release_id)
);
CREATE TABLE cq_participants(
 campaign_id uuid NOT NULL REFERENCES cq_campaigns(id),respondent_user_id uuid NOT NULL REFERENCES users(user_id),
 created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(campaign_id,respondent_user_id)
);
CREATE TABLE cq_sessions(
 id uuid PRIMARY KEY,campaign_id uuid NOT NULL,release_id uuid NOT NULL,respondent_user_id uuid NOT NULL,
 locale varchar(2) NOT NULL,revision integer NOT NULL CHECK(revision>=0),
 state varchar(24) NOT NULL CHECK(state IN ('ACTIVE','SUBMITTED','WITHDRAWN')),
 consented boolean NOT NULL DEFAULT false,consent_version varchar(100),
 CHECK(NOT consented OR consent_version IS NOT NULL),CHECK(state!='WITHDRAWN' OR NOT consented),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(campaign_id,respondent_user_id),FOREIGN KEY(campaign_id,release_id) REFERENCES cq_campaigns(id,release_id),
 FOREIGN KEY(campaign_id,respondent_user_id) REFERENCES cq_participants(campaign_id,respondent_user_id)
);
CREATE TABLE cq_consent_events(
 id uuid PRIMARY KEY,session_id uuid NOT NULL REFERENCES cq_sessions(id),revision integer NOT NULL,
 request_id uuid NOT NULL,request_hash varchar(64) NOT NULL,consented boolean NOT NULL,version varchar(100) NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(session_id,request_id),UNIQUE(session_id,revision)
);
CREATE TABLE cq_stimulus_deliveries(
 id uuid PRIMARY KEY,session_id uuid NOT NULL REFERENCES cq_sessions(id),revision integer NOT NULL,
 kind varchar(20) NOT NULL,stimulus_hash varchar(64) NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(session_id,kind)
);
CREATE TABLE cq_routing_decisions(
 id uuid PRIMARY KEY,session_id uuid NOT NULL REFERENCES cq_sessions(id),revision integer NOT NULL,
 decision_json jsonb NOT NULL,decision_hash varchar(64) NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(session_id,revision),UNIQUE(id,session_id,revision)
);
CREATE TABLE cq_presentations(
 id uuid PRIMARY KEY,session_id uuid NOT NULL REFERENCES cq_sessions(id),revision integer NOT NULL,
 slot_id varchar(100) NOT NULL,context_digest varchar(64) NOT NULL,decision_id uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(session_id,revision,slot_id,context_digest),
 UNIQUE(id,session_id,slot_id),
 FOREIGN KEY(decision_id,session_id,revision) REFERENCES cq_routing_decisions(id,session_id,revision)
);
CREATE TABLE cq_answer_revisions(
 id uuid PRIMARY KEY,session_id uuid NOT NULL REFERENCES cq_sessions(id),slot_id varchar(100) NOT NULL,
 revision integer NOT NULL,request_id uuid NOT NULL,request_hash varchar(64) NOT NULL,display_id uuid NOT NULL,
 state varchar(32) NOT NULL CHECK(state IN ('SKIPPED','REFUSED','ANSWERED_SUBSTANTIVE','ANSWERED_NON_SUBSTANTIVE')),
 value_json jsonb,context_digest varchar(64) NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(session_id,request_id),UNIQUE(session_id,revision),UNIQUE(id,session_id,slot_id),
 FOREIGN KEY(display_id,session_id,slot_id) REFERENCES cq_presentations(id,session_id,slot_id),
 CHECK(state!='SKIPPED' OR value_json IS NULL OR value_json='null'::jsonb OR value_json='[]'::jsonb)
);
CREATE TABLE cq_effective_answers(
 session_id uuid NOT NULL REFERENCES cq_sessions(id),slot_id varchar(100) NOT NULL,answer_event_id uuid,
 state varchar(32) NOT NULL CHECK(state IN ('PENDING','NOT_SHOWN','SKIPPED','REFUSED','ANSWERED_SUBSTANTIVE','ANSWERED_NON_SUBSTANTIVE')),
 context_digest varchar(64) NOT NULL,revision integer NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(session_id,slot_id),FOREIGN KEY(answer_event_id,session_id,slot_id) REFERENCES cq_answer_revisions(id,session_id,slot_id),
 CHECK((state IN ('NOT_SHOWN','PENDING'))=(answer_event_id IS NULL))
);
CREATE TABLE cq_submission_receipts(
 id uuid PRIMARY KEY,session_id uuid NOT NULL UNIQUE REFERENCES cq_sessions(id),request_id uuid NOT NULL,
 request_hash varchar(64) NOT NULL,revision integer NOT NULL,receipt_hash varchar(64) NOT NULL,payload_json jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK((payload_json->>'session_id'=session_id::text AND payload_json->>'receipt_id'=id::text
    AND payload_json->>'receipt_hash'=receipt_hash) IS TRUE)
);
CREATE INDEX ix_cq_answer_history ON cq_answer_revisions(session_id,revision);
CREATE INDEX ix_cq_participant ON cq_participants(respondent_user_id,campaign_id);
CREATE FUNCTION cq_immutable_record() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Versioned CQ records are append-only' USING ERRCODE='55000'; END $$;
CREATE FUNCTION cq_session_update_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF ROW(NEW.id,NEW.campaign_id,NEW.release_id,NEW.respondent_user_id,NEW.locale,NEW.created_at)
    IS DISTINCT FROM ROW(OLD.id,OLD.campaign_id,OLD.release_id,OLD.respondent_user_id,OLD.locale,OLD.created_at)
    OR NEW.revision!=OLD.revision+1
    OR (OLD.state!='ACTIVE' AND NEW.state NOT IN (OLD.state,'WITHDRAWN')) THEN
  RAISE EXCEPTION 'CQ identity is immutable and revision transitions are controlled' USING ERRCODE='55000';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER cq_session_guard BEFORE UPDATE ON cq_sessions FOR EACH ROW EXECUTE FUNCTION cq_session_update_guard();
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['cq_bank_versions','cq_manifest_releases','cq_question_assignments','cq_campaigns','cq_participants',
 'cq_consent_events','cq_stimulus_deliveries','cq_routing_decisions','cq_presentations','cq_answer_revisions','cq_submission_receipts'] LOOP
  EXECUTE format('CREATE TRIGGER cq_append_only BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION cq_immutable_record()',t);
 END LOOP;
 FOREACH t IN ARRAY ARRAY['cq_bank_versions','cq_manifest_releases','cq_question_assignments','cq_campaigns','cq_participants','cq_sessions',
 'cq_consent_events','cq_stimulus_deliveries','cq_routing_decisions','cq_presentations','cq_answer_revisions','cq_effective_answers','cq_submission_receipts'] LOOP
  EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON %I FROM PUBLIC',t);
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION cq_immutable_record() FROM PUBLIC;
REVOKE ALL ON FUNCTION cq_session_update_guard() FROM PUBLIC;
COMMIT;
