-- Local development fixture provenance, not a fielding/consent approval.
BEGIN;
SET LOCAL lock_timeout='5s';
DO $$ BEGIN
 IF current_setting('project1.cq_migration_target',true) IS DISTINCT FROM current_database()
 OR nullif(current_setting('project1.cq_migration_receipt',true),'') IS NULL
 OR coalesce(current_setting('project1.cq_migration_sha256',true),'') !~ '^[0-9a-f]{64}$' THEN
  RAISE EXCEPTION 'Explicit target, operator receipt and migration hash required';
 END IF;
 IF EXISTS(SELECT 1 FROM cq_schema_migrations WHERE version='20261116_03'
 AND migration_sha256<>current_setting('project1.cq_migration_sha256')) THEN
  RAISE EXCEPTION 'Migration hash differs';
 END IF;
END $$;
CREATE TABLE IF NOT EXISTS cq_synthetic_import_runs(
 run_id uuid PRIMARY KEY,owner_user_id uuid NOT NULL REFERENCES users(user_id),
 package_sha256 varchar(64) NOT NULL,plan_sha256 varchar(64) NOT NULL,
 origin text NOT NULL DEFAULT 'SYNTHETIC_TEST' CHECK(origin='SYNTHETIC_TEST'),
 effective_mode text NOT NULL DEFAULT 'DEVELOPER_PREVIEW' CHECK(effective_mode='DEVELOPER_PREVIEW'),
 consent_semantics text NOT NULL DEFAULT 'SIMULATED_NONHUMAN_NOT_INFORMED_CONSENT'
 CHECK(consent_semantics='SIMULATED_NONHUMAN_NOT_INFORMED_CONSENT'),
 real_reportable boolean NOT NULL DEFAULT false CHECK(NOT real_reportable),
 operator_receipt text NOT NULL CHECK(length(operator_receipt)>0),
 manifest_json jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS cq_synthetic_import_records(
 run_id uuid NOT NULL REFERENCES cq_synthetic_import_runs(run_id),table_name text NOT NULL,
 source_key jsonb NOT NULL,source_key_hash varchar(64) NOT NULL,
 record_key jsonb NOT NULL,record_key_hash varchar(64) NOT NULL,
 source_sha256 varchar(64) NOT NULL,imported_sha256 varchar(64) NOT NULL,
 record_kind text NOT NULL DEFAULT 'PACKAGE' CHECK(record_kind IN ('PACKAGE','DEVELOPER_ACTION')),
 origin text NOT NULL DEFAULT 'SYNTHETIC_TEST' CHECK(origin='SYNTHETIC_TEST'),
 real_reportable boolean NOT NULL DEFAULT false CHECK(NOT real_reportable),
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(table_name,record_key_hash),UNIQUE(run_id,table_name,source_key_hash),
 CHECK(table_name IN ('users','m2_instrument_versions','m2_assessments','cq_bank_versions',
 'cq_manifest_releases','cq_question_assignments','cq_campaigns','cq_participants','cq_sessions',
 'cq_consent_events','cq_stimulus_deliveries','cq_routing_decisions','cq_presentations',
 'cq_answer_revisions','cq_effective_answers','cq_submission_receipts','cq_lifecycle_events',
 'cq_render_events','cq_rejected_answer_events','cq_session_controls',
 'ee01_measurement_snapshots','ee01_source_units','ee01_category_cells','ee01_report_readbacks'))
);
CREATE TABLE IF NOT EXISTS cq_synthetic_import_retirements(
 run_id uuid PRIMARY KEY REFERENCES cq_synthetic_import_runs(run_id),
 reason text NOT NULL CHECK(length(reason)>0),created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS cq_synthetic_preview_grants(
 run_id uuid NOT NULL REFERENCES cq_synthetic_import_runs(run_id),developer_user_id uuid NOT NULL,
 principal_source text NOT NULL CHECK(principal_source='EXISTING_VERIFIED_APP_PROFILE'),
 profile_anchor_sha256 varchar(64) NOT NULL,may_pause_resume boolean NOT NULL DEFAULT false,
 operator_receipt text NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(run_id,developer_user_id)
);
CREATE INDEX IF NOT EXISTS ix_cq_synthetic_run_records ON cq_synthetic_import_records(run_id,table_name);
CREATE OR REPLACE FUNCTION cq_synthetic_profile_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 IF (NEW.account_status<>'suspended' OR NEW.email_verified) AND EXISTS(
  SELECT 1 FROM public.cq_synthetic_import_records
  WHERE table_name='users' AND record_key->>'user_id'=NEW.user_id::text) THEN
  RAISE EXCEPTION 'SYNTHETIC_PROFILE_NOT_LOGIN_ACCOUNT' USING ERRCODE='42501';
 END IF;
 RETURN NEW;
END $$;
-- Read-only grants. No synthetic answer, consent or session write privileges.
ALTER TABLE cq_synthetic_preview_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE cq_synthetic_preview_grants FORCE ROW LEVEL SECURITY;
REVOKE ALL ON cq_synthetic_preview_grants FROM PUBLIC;
GRANT SELECT ON cq_synthetic_preview_grants TO p1_ee01_runtime;
GRANT SELECT ON cq_effective_answers,cq_submission_receipts TO p1_ee01_runtime;
CREATE OR REPLACE FUNCTION cq_synthetic_can_read(target_table text,target_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT EXISTS(SELECT 1 FROM public.cq_synthetic_import_records r
 JOIN public.cq_synthetic_preview_grants g ON g.run_id=r.run_id
 WHERE r.table_name=target_table AND r.record_key->>'id'=target_id::text
 AND g.developer_user_id::text=current_setting('project1.actor_id',true)
 AND NOT EXISTS(SELECT 1 FROM public.cq_synthetic_import_retirements x WHERE x.run_id=r.run_id));
$$;
REVOKE ALL ON FUNCTION cq_synthetic_can_read(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cq_synthetic_can_read(text,uuid) TO p1_ee01_runtime;
DO $$ DECLARE t text; BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='cq_synthetic_preview_grants'::regclass AND tgname='cq_append_only') THEN
  CREATE TRIGGER cq_append_only BEFORE UPDATE OR DELETE ON cq_synthetic_preview_grants FOR EACH ROW EXECUTE FUNCTION cq_immutable_record();
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename='cq_synthetic_preview_grants' AND policyname='synthetic_developer_self') THEN
  CREATE POLICY synthetic_developer_self ON cq_synthetic_preview_grants FOR SELECT TO p1_ee01_runtime
   USING(developer_user_id::text=current_setting('project1.actor_id',true));
  CREATE POLICY synthetic_granted_run ON cq_synthetic_import_runs FOR SELECT TO p1_ee01_runtime
   USING(run_id IN (SELECT run_id FROM cq_synthetic_preview_grants));
  CREATE POLICY synthetic_campaign_grant ON cq_campaigns FOR SELECT TO p1_ee01_runtime
   USING(cq_synthetic_can_read('cq_campaigns',id));
  CREATE POLICY synthetic_snapshot_grant ON ee01_measurement_snapshots FOR SELECT TO p1_ee01_runtime
   USING(cq_synthetic_can_read('ee01_measurement_snapshots',id));
 END IF;
 FOREACH t IN ARRAY ARRAY['cq_effective_answers','cq_submission_receipts'] LOOP
  IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename=t AND policyname='synthetic_owner_inspection') THEN
   EXECUTE format('CREATE POLICY synthetic_owner_inspection ON %I FOR SELECT TO p1_ee01_runtime USING(session_id IN (SELECT id FROM cq_sessions))',t);
  END IF;
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION cq_synthetic_profile_guard() FROM PUBLIC;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='users'::regclass AND tgname='cq_synthetic_login_guard') THEN
  CREATE TRIGGER cq_synthetic_login_guard BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION cq_synthetic_profile_guard();
 END IF;
END $$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['cq_synthetic_import_runs','cq_synthetic_import_records','cq_synthetic_import_retirements'] LOOP
  EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON %I FROM PUBLIC',t);
  EXECUTE format('GRANT SELECT ON %I TO p1_ee01_runtime',t);
  IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=t::regclass AND tgname='cq_append_only') THEN
   EXECUTE format('CREATE TRIGGER cq_append_only BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION cq_immutable_record()',t);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename=t AND policyname='synthetic_owner') THEN
   IF t='cq_synthetic_import_runs' THEN
    CREATE POLICY synthetic_owner ON cq_synthetic_import_runs FOR SELECT TO p1_ee01_runtime
     USING(owner_user_id::text=current_setting('project1.actor_id',true));
   ELSE
    EXECUTE format('CREATE POLICY synthetic_owner ON %I FOR SELECT TO p1_ee01_runtime USING(run_id IN (SELECT run_id FROM cq_synthetic_import_runs))',t);
   END IF;
  END IF;
 END LOOP;
END $$;
INSERT INTO cq_schema_migrations(version,migration_sha256,receipt)
VALUES('20261116_03',current_setting('project1.cq_migration_sha256'),current_setting('project1.cq_migration_receipt'))
ON CONFLICT(version) DO NOTHING;
COMMIT;
