-- Additive: existing physical CQ session vocabulary and historical rows remain intact.
BEGIN;
SET LOCAL lock_timeout='5s';
DO $$ BEGIN
 IF current_setting('project1.cq_migration_target',true) IS DISTINCT FROM current_database()
 OR nullif(current_setting('project1.cq_migration_receipt',true),'') IS NULL
 OR coalesce(current_setting('project1.cq_migration_sha256',true),'') !~ '^[0-9a-f]{64}$' THEN
  RAISE EXCEPTION 'Explicit target, operator receipt and verified migration hash required';
 END IF;
END $$;
CREATE TABLE IF NOT EXISTS cq_schema_migrations(
 version text PRIMARY KEY,migration_sha256 varchar(64) NOT NULL,receipt text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM cq_schema_migrations WHERE version='20261116_01'
 AND migration_sha256<>current_setting('project1.cq_migration_sha256')) THEN
  RAISE EXCEPTION 'Recorded migration hash differs';
 END IF;
END $$;
CREATE TABLE IF NOT EXISTS cq_lifecycle_events(
 id uuid PRIMARY KEY,session_id uuid NOT NULL REFERENCES cq_sessions(id),revision integer NOT NULL,
 request_id uuid NOT NULL,request_hash varchar(64) NOT NULL,
 action varchar(8) NOT NULL CHECK(action IN ('PAUSE','RESUME')),
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(session_id,request_id),UNIQUE(session_id,revision)
);
CREATE TABLE IF NOT EXISTS cq_render_events(
 id uuid PRIMARY KEY,session_id uuid NOT NULL REFERENCES cq_sessions(id),display_id uuid NOT NULL,
 slot_id varchar(100) NOT NULL,revision integer NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(display_id),FOREIGN KEY(display_id,session_id,slot_id) REFERENCES cq_presentations(id,session_id,slot_id)
);
CREATE TABLE IF NOT EXISTS cq_rejected_answer_events(
 id uuid PRIMARY KEY,session_id uuid NOT NULL REFERENCES cq_sessions(id),display_id uuid NOT NULL,
 revision integer NOT NULL,request_id uuid NOT NULL,request_hash varchar(64) NOT NULL,
 slot_id varchar(100) NOT NULL,raw_value jsonb,reason varchar(100) NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(session_id,request_id),
 FOREIGN KEY(display_id,session_id,slot_id) REFERENCES cq_presentations(id,session_id,slot_id)
);
CREATE TABLE IF NOT EXISTS cq_session_controls(
 session_id uuid PRIMARY KEY REFERENCES cq_sessions(id),research_mode varchar(32) NOT NULL
 CHECK(research_mode IN ('COGNITIVE_PRETEST','CUSTOMER_DEMAND_SURVEY','DEVELOPER_PREVIEW')),
 eligibility varchar(24) NOT NULL CHECK(eligibility IN ('UNRESOLVED','ELIGIBLE','INELIGIBLE')),
 qualification_version text NOT NULL,source_json jsonb NOT NULL,source_hash varchar(64) NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),CHECK(source_hash ~ '^[0-9a-f]{64}$')
);
CREATE INDEX IF NOT EXISTS ix_cq_lifecycle_cutoff ON cq_lifecycle_events(session_id,created_at,revision);
CREATE INDEX IF NOT EXISTS ix_cq_render_cutoff ON cq_render_events(session_id,slot_id,created_at);
CREATE INDEX IF NOT EXISTS ix_cq_rejected_cutoff ON cq_rejected_answer_events(session_id,slot_id,created_at);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['cq_lifecycle_events','cq_render_events','cq_rejected_answer_events','cq_session_controls'] LOOP
  EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON %I FROM PUBLIC',t);
  IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=t::regclass AND tgname='cq_append_only') THEN
   EXECUTE format('CREATE TRIGGER cq_append_only BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION cq_immutable_record()',t);
  END IF;
 END LOOP;
END $$;
INSERT INTO cq_schema_migrations(version,migration_sha256,receipt)
VALUES('20261116_01',current_setting('project1.cq_migration_sha256'),current_setting('project1.cq_migration_receipt'))
ON CONFLICT(version) DO NOTHING;
COMMIT;
