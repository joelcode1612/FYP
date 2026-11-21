-- Bounded nonhuman developer execution. No production collection authority.
BEGIN;
SET LOCAL lock_timeout='5s';
DO $$ BEGIN
 IF current_setting('project1.cq_migration_target',true) IS DISTINCT FROM current_database()
 OR nullif(current_setting('project1.cq_migration_receipt',true),'') IS NULL
 OR coalesce(current_setting('project1.cq_migration_sha256',true),'') !~ '^[0-9a-f]{64}$' THEN
  RAISE EXCEPTION 'Explicit target, receipt and hash required';
 END IF;
 IF EXISTS(SELECT 1 FROM cq_schema_migrations WHERE version='20261116_04' AND migration_sha256<>current_setting('project1.cq_migration_sha256')) THEN
  RAISE EXCEPTION 'Migration hash differs';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM cq_schema_migrations WHERE version='20261116_04') AND
  (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.m2_workflow_cq_change()'))
   IS DISTINCT FROM '24c80efe21c506ba5cc1fe2795ac83a4' THEN
  RAISE EXCEPTION 'Existing CQ workflow bridge differs; review before replacement';
 END IF;
END $$;
CREATE TABLE IF NOT EXISTS cq_synthetic_execution_grants(
 run_id uuid NOT NULL,developer_user_id uuid NOT NULL,operator_receipt text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(run_id,developer_user_id),
 FOREIGN KEY(run_id,developer_user_id) REFERENCES cq_synthetic_preview_grants(run_id,developer_user_id)
);
CREATE TABLE IF NOT EXISTS cq_synthetic_cases(
 session_id uuid PRIMARY KEY REFERENCES cq_sessions(id),run_id uuid NOT NULL REFERENCES cq_synthetic_import_runs(run_id),
 case_key text NOT NULL,scenario text NOT NULL CHECK(scenario IN ('NORMAL','HYPOTHETICAL_SCREENOUT','UNRESOLVED')),
 source_json jsonb NOT NULL,source_sha256 varchar(64) NOT NULL,
 origin text NOT NULL DEFAULT 'SYNTHETIC_TEST' CHECK(origin='SYNTHETIC_TEST'),
 real_reportable boolean NOT NULL DEFAULT false CHECK(NOT real_reportable),
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(run_id,case_key)
);
CREATE TABLE IF NOT EXISTS cq_synthetic_execution_events(
 id uuid PRIMARY KEY,run_id uuid NOT NULL REFERENCES cq_synthetic_import_runs(run_id),
 session_id uuid NOT NULL REFERENCES cq_synthetic_cases(session_id),developer_user_id uuid NOT NULL,
 operation text NOT NULL,request_hash varchar(64) NOT NULL,revision integer NOT NULL,
 lifecycle_status text NOT NULL CHECK(lifecycle_status IN ('IN_PROGRESS','PAUSED','COMPLETED','SCREENED_OUT','WITHDRAWN','UNRESOLVED')),
 snapshot_json jsonb NOT NULL,snapshot_sha256 varchar(64) NOT NULL,
 origin text NOT NULL DEFAULT 'SYNTHETIC_TEST' CHECK(origin='SYNTHETIC_TEST'),
 real_reportable boolean NOT NULL DEFAULT false CHECK(NOT real_reportable),created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_cq_synthetic_execution_session ON cq_synthetic_execution_events(session_id,revision,created_at);
CREATE OR REPLACE FUNCTION cq_synthetic_can_execute(sid uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT EXISTS(SELECT 1 FROM public.cq_synthetic_cases x JOIN public.cq_synthetic_execution_grants g ON g.run_id=x.run_id
 WHERE x.session_id=sid AND x.session_id::text=current_setting('project1.synthetic_session_id',true)
 AND x.run_id::text=current_setting('project1.synthetic_run_id',true)
 AND g.developer_user_id::text=current_setting('project1.actor_id',true)
 AND NOT EXISTS(SELECT 1 FROM public.cq_synthetic_import_retirements z WHERE z.run_id=x.run_id));
$$;
REVOKE ALL ON FUNCTION cq_synthetic_can_execute(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cq_synthetic_can_execute(uuid) TO p1_ee01_runtime;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['cq_synthetic_execution_grants','cq_synthetic_cases','cq_synthetic_execution_events'] LOOP
  EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON %I FROM PUBLIC',t);
  EXECUTE format('GRANT SELECT ON %I TO p1_ee01_runtime',t);
  IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=t::regclass AND tgname='cq_append_only') THEN
   EXECUTE format('CREATE TRIGGER cq_append_only BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION cq_immutable_record()',t);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename=t AND policyname='synthetic_execution_read') THEN
   IF t='cq_synthetic_execution_grants' THEN
    EXECUTE format('CREATE POLICY synthetic_execution_read ON %I FOR SELECT TO p1_ee01_runtime USING(developer_user_id::text=current_setting(''project1.actor_id'',true))',t);
   ELSE
    EXECUTE format('CREATE POLICY synthetic_execution_read ON %I FOR SELECT TO p1_ee01_runtime USING(run_id IN (SELECT run_id FROM cq_synthetic_execution_grants))',t);
   END IF;
  END IF;
 END LOOP;
 GRANT INSERT ON cq_synthetic_execution_events TO p1_ee01_runtime;
 IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename='cq_synthetic_execution_events' AND policyname='synthetic_execution_append') THEN
  CREATE POLICY synthetic_execution_append ON cq_synthetic_execution_events FOR INSERT TO p1_ee01_runtime
   WITH CHECK(cq_synthetic_can_execute(session_id) AND developer_user_id::text=current_setting('project1.actor_id',true));
 END IF;
 GRANT SELECT ON cq_participants,cq_routing_decisions TO p1_ee01_runtime;
 IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename='ee01_measurement_snapshots' AND policyname='synthetic_generated_snapshot_read') THEN
  CREATE POLICY synthetic_generated_snapshot_read ON ee01_measurement_snapshots FOR SELECT TO p1_ee01_runtime
   USING(scope='ISOLATED_TEST' AND metadata_json->>'origin'='SYNTHETIC_TEST'
    AND metadata_json->>'real_reportable'='false'
    AND metadata_json->>'synthetic_run_id' IN (SELECT run_id::text FROM cq_synthetic_preview_grants));
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename='cq_participants' AND policyname='synthetic_execution_read') THEN
  CREATE POLICY synthetic_execution_read ON cq_participants FOR SELECT TO p1_ee01_runtime USING(campaign_id IN (SELECT id FROM cq_campaigns));
  CREATE POLICY synthetic_execution_read ON cq_routing_decisions FOR SELECT TO p1_ee01_runtime USING(session_id IN (SELECT id FROM cq_sessions));
 END IF;
 GRANT UPDATE(revision,state,consented,consent_version) ON cq_sessions TO p1_ee01_runtime;
 IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename='cq_sessions' AND policyname='synthetic_execution_update') THEN
  CREATE POLICY synthetic_execution_update ON cq_sessions FOR UPDATE TO p1_ee01_runtime
   USING(cq_synthetic_can_execute(id)) WITH CHECK(cq_synthetic_can_execute(id));
 END IF;
 FOREACH t IN ARRAY ARRAY['cq_consent_events','cq_stimulus_deliveries','cq_routing_decisions','cq_presentations',
 'cq_answer_revisions','cq_effective_answers','cq_submission_receipts','cq_lifecycle_events','cq_render_events','cq_rejected_answer_events'] LOOP
  EXECUTE format('GRANT INSERT ON %I TO p1_ee01_runtime',t);
  IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename=t AND policyname='synthetic_execution_insert') THEN
   EXECUTE format('CREATE POLICY synthetic_execution_insert ON %I FOR INSERT TO p1_ee01_runtime WITH CHECK(cq_synthetic_can_execute(session_id))',t);
  END IF;
 END LOOP;
 GRANT UPDATE ON cq_effective_answers TO p1_ee01_runtime;
 IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE tablename='cq_effective_answers' AND policyname='synthetic_execution_update') THEN
  CREATE POLICY synthetic_execution_update ON cq_effective_answers FOR UPDATE TO p1_ee01_runtime
   USING(cq_synthetic_can_execute(session_id)) WITH CHECK(cq_synthetic_can_execute(session_id));
 END IF;
END $$;
CREATE OR REPLACE FUNCTION cq_synthetic_profile_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 IF (NEW.account_status<>'suspended' OR NEW.email_verified) AND
 (EXISTS(SELECT 1 FROM public.cq_synthetic_import_records WHERE table_name='users' AND record_key->>'user_id'=NEW.user_id::text)
 OR EXISTS(SELECT 1 FROM public.cq_sessions s JOIN public.cq_synthetic_cases x ON x.session_id=s.id WHERE s.respondent_user_id=NEW.user_id)) THEN
  RAISE EXCEPTION 'SYNTHETIC_PROFILE_NOT_LOGIN_ACCOUNT' USING ERRCODE='42501';
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION cq_synthetic_profile_guard() FROM PUBLIC;
-- Synthetic activity must not become ordinary M2/research progress. Preserve
-- the existing bridge for every untagged campaign, without granting the CQ
-- runtime UPDATE/SELECT FOR UPDATE rights on entrepreneur M2 records.
CREATE OR REPLACE FUNCTION cq_is_synthetic_campaign(cid uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT EXISTS(SELECT 1 FROM public.cq_synthetic_import_records
 WHERE table_name='cq_campaigns' AND record_key->>'id'=cid::text);
$$;
REVOKE ALL ON FUNCTION cq_is_synthetic_campaign(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cq_is_synthetic_campaign(uuid) TO p1_ee01_runtime;
CREATE OR REPLACE FUNCTION public.m2_workflow_cq_change() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE aid uuid; cid uuid;
BEGIN
 IF TG_TABLE_NAME='cq_campaigns' THEN cid:=NEW.id; aid:=NEW.assessment_id;
 ELSIF TG_TABLE_NAME='cq_sessions' THEN cid:=NEW.campaign_id;
 ELSE SELECT campaign_id INTO cid FROM public.cq_sessions WHERE id=NEW.session_id;
 END IF;
 IF public.cq_is_synthetic_campaign(cid) THEN RETURN NULL; END IF;
 IF aid IS NULL THEN SELECT assessment_id INTO aid FROM public.cq_campaigns WHERE id=cid; END IF;
 PERFORM public.refresh_m2_workflow(aid);
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.m2_workflow_cq_change() FROM PUBLIC;
INSERT INTO cq_schema_migrations(version,migration_sha256,receipt)
VALUES('20261116_04',current_setting('project1.cq_migration_sha256'),current_setting('project1.cq_migration_receipt'))
ON CONFLICT(version) DO NOTHING;
COMMIT;
