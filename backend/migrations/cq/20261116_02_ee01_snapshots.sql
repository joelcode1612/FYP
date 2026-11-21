-- Additive storage, not a scientific approval or participant activation.
BEGIN;
SET LOCAL lock_timeout='5s';
DO $$ BEGIN
 IF current_setting('project1.cq_migration_target',true) IS DISTINCT FROM current_database()
 OR nullif(current_setting('project1.cq_migration_receipt',true),'') IS NULL
 OR coalesce(current_setting('project1.cq_migration_sha256',true),'') !~ '^[0-9a-f]{64}$' THEN
  RAISE EXCEPTION 'Explicit target, receipt and verified file hash required';
 END IF;
 IF EXISTS(SELECT 1 FROM cq_schema_migrations WHERE version='20261116_02'
 AND migration_sha256<>current_setting('project1.cq_migration_sha256')) THEN
  RAISE EXCEPTION 'Migration hash differs';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='p1_ee01_runtime') THEN
  CREATE ROLE p1_ee01_runtime NOLOGIN NOSUPERUSER NOBYPASSRLS;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='p1_ee01_runtime' AND (rolsuper OR rolbypassrls)) THEN
  RAISE EXCEPTION 'Restricted reporting role required';
 END IF;
END $$;
CREATE TABLE IF NOT EXISTS ee01_measurement_snapshots(
 id uuid PRIMARY KEY,owner_user_id uuid NOT NULL REFERENCES users(user_id),
 assessment_id uuid NOT NULL REFERENCES m2_assessments(id),campaign_id uuid NOT NULL REFERENCES cq_campaigns(id),
 release_id uuid NOT NULL REFERENCES cq_manifest_releases(id),slot_id varchar(100) NOT NULL,
 question_version varchar(100) NOT NULL,cutoff timestamptz NOT NULL,
 fingerprint varchar(64) NOT NULL UNIQUE,rules_hash varchar(64) NOT NULL,source_hash varchar(64) NOT NULL,
 scope text NOT NULL CHECK(scope IN ('ISOLATED_TEST','PRODUCTION')),
 status text NOT NULL CHECK(status IN ('WITHHELD_NOT_AUTHORIZED','NOT_ESTIMABLE','NOT_SHOWN')),
 q integer NOT NULL,s integer NOT NULL,a integer NOT NULL,v integer NOT NULL,
 metadata_json jsonb NOT NULL,counts_json jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(0<=v AND v<=a AND a<=s AND s<=q),
 FOREIGN KEY(release_id,slot_id) REFERENCES cq_question_assignments(release_id,slot_id),
 UNIQUE(id,owner_user_id)
);
CREATE TABLE IF NOT EXISTS ee01_source_units(
 snapshot_id uuid NOT NULL REFERENCES ee01_measurement_snapshots(id),
 session_id uuid NOT NULL REFERENCES cq_sessions(id),
 render_id uuid REFERENCES cq_render_events(id),answer_id uuid REFERENCES cq_answer_revisions(id),
 rejected_id uuid REFERENCES cq_rejected_answer_events(id),
 source_json jsonb NOT NULL,source_hash varchar(64) NOT NULL,
 PRIMARY KEY(snapshot_id,session_id)
);
CREATE TABLE IF NOT EXISTS ee01_category_cells(
 snapshot_id uuid NOT NULL REFERENCES ee01_measurement_snapshots(id),code text NOT NULL,
 x integer NOT NULL,v integer NOT NULL,percentage numeric(12,6),diagnostic_percentage numeric(12,6),
 status text NOT NULL CHECK(status IN ('WITHHELD_NOT_AUTHORIZED','NOT_ESTIMABLE','NOT_SHOWN')),
 PRIMARY KEY(snapshot_id,code),CHECK(0<=x AND x<=v),
 CHECK(percentage IS NULL),CHECK(diagnostic_percentage IS NULL OR diagnostic_percentage BETWEEN 0 AND 100)
);
-- Bound context/readback is deliberately not a released R01-R12 report model.
-- There is no verified adopted ReportAdmission adapter in this checkout.
CREATE TABLE IF NOT EXISTS ee01_report_readbacks(
 id uuid PRIMARY KEY,snapshot_id uuid NOT NULL REFERENCES ee01_measurement_snapshots(id),
 context_hash varchar(64) NOT NULL,context_json jsonb NOT NULL,
 status text NOT NULL CHECK(status='REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE'),
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(snapshot_id,context_hash)
);
CREATE INDEX IF NOT EXISTS ix_ee01_scope ON ee01_measurement_snapshots(owner_user_id,assessment_id,campaign_id,cutoff);
CREATE OR REPLACE FUNCTION ee01_source_binding_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE snap ee01_measurement_snapshots; BEGIN
 SELECT * INTO snap FROM ee01_measurement_snapshots WHERE id=NEW.snapshot_id;
 IF snap.id IS NULL OR NOT EXISTS(SELECT 1 FROM cq_sessions s WHERE s.id=NEW.session_id AND s.campaign_id=snap.campaign_id)
 OR (NEW.render_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM cq_render_events r WHERE r.id=NEW.render_id AND r.session_id=NEW.session_id AND r.slot_id=snap.slot_id))
 OR (NEW.answer_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM cq_answer_revisions a WHERE a.id=NEW.answer_id AND a.session_id=NEW.session_id AND a.slot_id=snap.slot_id))
 OR (NEW.rejected_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM cq_rejected_answer_events a WHERE a.id=NEW.rejected_id AND a.session_id=NEW.session_id AND a.slot_id=snap.slot_id)) THEN
  RAISE EXCEPTION 'EE01 source binding mismatch' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='ee01_source_units'::regclass AND tgname='ee01_source_binding') THEN
  CREATE TRIGGER ee01_source_binding BEFORE INSERT ON ee01_source_units FOR EACH ROW EXECUTE FUNCTION ee01_source_binding_guard();
 END IF;
END $$;
GRANT USAGE ON SCHEMA public TO p1_ee01_runtime;
GRANT SELECT ON cq_campaigns,cq_sessions,cq_manifest_releases,cq_question_assignments,cq_bank_versions,
 cq_consent_events,cq_stimulus_deliveries,cq_presentations,cq_answer_revisions,cq_rejected_answer_events,
 cq_render_events,cq_session_controls,cq_lifecycle_events,cq_schema_migrations TO p1_ee01_runtime;
DO $$ DECLARE t text; BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename='cq_campaigns' AND policyname='ee01_owner_read') THEN
  CREATE POLICY ee01_owner_read ON cq_campaigns FOR SELECT TO p1_ee01_runtime
   USING(owner_user_id::text=current_setting('project1.actor_id',true));
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename='cq_sessions' AND policyname='ee01_owner_read') THEN
  CREATE POLICY ee01_owner_read ON cq_sessions FOR SELECT TO p1_ee01_runtime
   USING(campaign_id IN (SELECT id FROM cq_campaigns));
 END IF;
 FOREACH t IN ARRAY ARRAY['cq_consent_events','cq_stimulus_deliveries','cq_presentations','cq_answer_revisions',
 'cq_rejected_answer_events','cq_render_events','cq_session_controls','cq_lifecycle_events'] LOOP
  IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename=t AND policyname='ee01_owner_read') THEN
   EXECUTE format('CREATE POLICY ee01_owner_read ON %I FOR SELECT TO p1_ee01_runtime USING(session_id IN (SELECT id FROM cq_sessions))',t);
  END IF;
 END LOOP;
 FOREACH t IN ARRAY ARRAY['cq_manifest_releases','cq_question_assignments'] LOOP
  IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename=t AND policyname='ee01_owner_read') THEN
   EXECUTE format('CREATE POLICY ee01_owner_read ON %I FOR SELECT TO p1_ee01_runtime USING(%I IN (SELECT release_id FROM cq_campaigns))',t,CASE WHEN t='cq_manifest_releases' THEN 'id' ELSE 'release_id' END);
  END IF;
 END LOOP;
 IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename='cq_bank_versions' AND policyname='ee01_owner_read') THEN
  CREATE POLICY ee01_owner_read ON cq_bank_versions FOR SELECT TO p1_ee01_runtime
   USING(version IN (SELECT manifest_json->>'bank_version' FROM cq_manifest_releases));
 END IF;
 FOREACH t IN ARRAY ARRAY['ee01_measurement_snapshots','ee01_source_units','ee01_category_cells','ee01_report_readbacks'] LOOP
  EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON %I FROM PUBLIC',t);
  EXECUTE format('GRANT SELECT,INSERT ON %I TO p1_ee01_runtime',t);
  IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=t::regclass AND tgname='cq_append_only') THEN
   EXECUTE format('CREATE TRIGGER cq_append_only BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION cq_immutable_record()',t);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename=t AND policyname='ee01_actor') THEN
   IF t='ee01_measurement_snapshots' THEN
    CREATE POLICY ee01_actor ON ee01_measurement_snapshots TO p1_ee01_runtime
     USING(owner_user_id::text=current_setting('project1.actor_id',true))
     WITH CHECK(owner_user_id::text=current_setting('project1.actor_id',true)
       AND EXISTS(SELECT 1 FROM cq_campaigns c WHERE c.id=campaign_id AND c.assessment_id=ee01_measurement_snapshots.assessment_id
       AND c.release_id=ee01_measurement_snapshots.release_id));
   ELSE
    EXECUTE format('CREATE POLICY ee01_actor ON %I TO p1_ee01_runtime USING(snapshot_id IN (SELECT id FROM ee01_measurement_snapshots)) WITH CHECK(snapshot_id IN (SELECT id FROM ee01_measurement_snapshots))',t);
   END IF;
  END IF;
 END LOOP;
END $$;
INSERT INTO cq_schema_migrations(version,migration_sha256,receipt)
VALUES('20261116_02',current_setting('project1.cq_migration_sha256'),current_setting('project1.cq_migration_receipt'))
ON CONFLICT(version) DO NOTHING;
COMMIT;
