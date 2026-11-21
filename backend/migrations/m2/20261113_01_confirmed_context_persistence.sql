-- REVIEW REQUIRED. Never run against live Dss without separate authorization.
-- Existing Dss nine-table schema + users; no instrument or approval is seeded.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
DO $guard$
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'M2 BCB migration requires an explicit target and operator receipt';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='public'
       AND tablename IN ('m2_clarification_events','m2_business_contexts','m2_business_context_builds')) THEN
    RAISE EXCEPTION 'Target objects already exist; reconcile schema drift before migration';
  END IF;
END
$guard$;

ALTER TABLE public.m2_assessments
  ADD CONSTRAINT uq_m2_assessment_owner UNIQUE(id,owner_user_id);
ALTER TABLE public.m2_bdj_findings
  ADD CONSTRAINT uq_m2_finding_source UNIQUE(id,assessment_id,assessment_revision);
ALTER TABLE public.m2_review_events
  ADD CONSTRAINT fk_m2_review_owner FOREIGN KEY(assessment_id,actor_user_id)
    REFERENCES public.m2_assessments(id,owner_user_id);
ALTER TABLE public.m2_confirmation_snapshots
  ADD CONSTRAINT uq_m2_confirmation_source UNIQUE(id,assessment_id,assessment_revision,actor_user_id),
  ADD CONSTRAINT fk_m2_confirmation_owner FOREIGN KEY(assessment_id,actor_user_id)
    REFERENCES public.m2_assessments(id,owner_user_id);

CREATE TABLE public.m2_clarification_events (
  id uuid PRIMARY KEY,
  assessment_id uuid NOT NULL REFERENCES public.m2_assessments(id),
  assessment_revision integer NOT NULL CHECK(assessment_revision>=0),
  finding_id uuid NOT NULL,
  actor_user_id uuid NOT NULL,
  decision varchar(24) NOT NULL CHECK(decision IN ('KEEP_ORIGINAL','REVIEW_LATER')),
  event_sequence integer NOT NULL CHECK(event_sequence>0),
  request_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_m2_clarification_request UNIQUE(assessment_id,request_id),
  CONSTRAINT uq_m2_clarification_sequence UNIQUE(assessment_id,assessment_revision,event_sequence),
  FOREIGN KEY(finding_id,assessment_id,assessment_revision)
    REFERENCES public.m2_bdj_findings(id,assessment_id,assessment_revision),
  FOREIGN KEY(assessment_id,actor_user_id) REFERENCES public.m2_assessments(id,owner_user_id)
);

CREATE TABLE public.m2_business_contexts (
  context_id uuid PRIMARY KEY,
  assessment_id uuid NOT NULL,
  owner_user_id uuid NOT NULL,
  confirmation_id uuid NOT NULL,
  assessment_revision integer NOT NULL CHECK(assessment_revision>=0),
  schema_version varchar(100) NOT NULL,
  builder_version varchar(100) NOT NULL,
  purpose varchar(64) NOT NULL,
  tenant_id varchar(200) NOT NULL,
  concept_version varchar(200) NOT NULL,
  snapshot_digest varchar(64) NOT NULL CHECK(snapshot_digest ~ '^[0-9a-f]{64}$'),
  packet_hash varchar(64) NOT NULL UNIQUE CHECK(packet_hash ~ '^[0-9a-f]{64}$'),
  canonical_body text NOT NULL,
  packet_json jsonb NOT NULL,
  lifecycle_status varchar(24) NOT NULL CHECK(lifecycle_status='PERSISTED'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_bcb_confirmation_source FOREIGN KEY(confirmation_id,assessment_id,assessment_revision,owner_user_id)
    REFERENCES public.m2_confirmation_snapshots(id,assessment_id,assessment_revision,actor_user_id),
  CONSTRAINT uq_bcb_full_source UNIQUE(context_id,confirmation_id,assessment_id,assessment_revision,owner_user_id),
  CONSTRAINT ck_bcb_canonical_packet CHECK(jsonb_typeof(packet_json)='object' AND canonical_body::jsonb = packet_json - 'packet_hash'),
  CONSTRAINT ck_bcb_packet_digest CHECK((encode(sha256(convert_to(canonical_body,'UTF8')),'hex')=packet_hash
    AND packet_json->>'packet_hash'=packet_hash) IS TRUE),
  CONSTRAINT ck_bcb_source_binding CHECK((packet_json#>>'{identity,assessment_id}'=assessment_id::text
    AND packet_json#>>'{identity,owner_id}'=owner_user_id::text
    AND packet_json#>>'{confirmation,id}'=confirmation_id::text
    AND (packet_json#>>'{confirmation,revision}')::integer=assessment_revision
    AND packet_json#>>'{confirmation,digest}'=snapshot_digest
    AND packet_json->>'schema_version'=schema_version AND packet_json->>'context_version'=builder_version
    AND packet_json#>>'{identity,tenant_id}'=tenant_id
    AND packet_json#>>'{concept,version}'=concept_version
    AND packet_json#>>'{access,scope,purpose}'=purpose) IS TRUE),
  CONSTRAINT ck_bcb_no_downstream_authority CHECK((packet_json->'permissions' =
    '{"report_admission":false,"report_release":false,"qj_execution":false,"qg_execution":false}'::jsonb) IS TRUE)
);
CREATE INDEX ix_bcb_owner_assessment ON public.m2_business_contexts(owner_user_id,assessment_id,created_at);

-- One durable generation status per actual confirmation. Status is engineering
-- lifecycle only, not scientific, Owner, fielding or report authority.
CREATE TABLE public.m2_business_context_builds (
  confirmation_id uuid PRIMARY KEY,
  assessment_id uuid NOT NULL,
  owner_user_id uuid NOT NULL,
  assessment_revision integer NOT NULL CHECK(assessment_revision>=0),
  status varchar(24) NOT NULL CHECK(status IN ('PENDING','HELD','PERSISTED','FAILED')),
  last_code varchar(100),
  context_id uuid REFERENCES public.m2_business_contexts(context_id),
  attempt_count integer NOT NULL DEFAULT 0 CHECK(attempt_count>=0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY(confirmation_id,assessment_id,assessment_revision,owner_user_id)
    REFERENCES public.m2_confirmation_snapshots(id,assessment_id,assessment_revision,actor_user_id),
  FOREIGN KEY(context_id,confirmation_id,assessment_id,assessment_revision,owner_user_id)
    REFERENCES public.m2_business_contexts(context_id,confirmation_id,assessment_id,assessment_revision,owner_user_id),
  CHECK((status='PERSISTED')=(context_id IS NOT NULL))
);

CREATE FUNCTION public.m2_bcb_initialize_status() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
  INSERT INTO public.m2_business_context_builds(confirmation_id,assessment_id,owner_user_id,assessment_revision,status)
    VALUES(NEW.id,NEW.assessment_id,NEW.actor_user_id,NEW.assessment_revision,'PENDING');
  RETURN NEW;
END $$;
CREATE TRIGGER m2_bcb_confirmation_status AFTER INSERT ON public.m2_confirmation_snapshots
  FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_initialize_status();
-- Existing confirmations are explicitly pending, never silently called built.
INSERT INTO public.m2_business_context_builds(confirmation_id,assessment_id,owner_user_id,assessment_revision,status)
  SELECT id,assessment_id,actor_user_id,assessment_revision,'PENDING' FROM public.m2_confirmation_snapshots;

CREATE FUNCTION public.m2_bcb_reject_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Versioned M2/BCB source records are append-only' USING ERRCODE='55000'; END $$;
DO $immutability$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['m2_answer_revisions','m2_bdj_evaluations','m2_bdj_findings',
    'm2_review_events','m2_confirmation_snapshots','m2_confirmed_uncertainties',
    'm2_clarification_events','m2_business_contexts'] LOOP
    EXECUTE format('CREATE TRIGGER m2_bcb_append_only BEFORE UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation()',t);
  END LOOP;
END
$immutability$;

CREATE FUNCTION public.m2_bcb_freeze_definition() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE inst uuid;
BEGIN
  IF TG_TABLE_NAME='m2_item_versions' THEN
    IF TG_OP='INSERT' THEN inst:=NEW.instrument_id; ELSE inst:=OLD.instrument_id; END IF;
  ELSE inst:=OLD.id; END IF;
  IF EXISTS(SELECT 1 FROM public.m2_assessments WHERE instrument_id=inst) THEN
    -- Instrument withdrawal may change approval_state; wording/codebooks stay immutable.
    IF TG_OP='UPDATE' AND TG_TABLE_NAME='m2_instrument_versions'
       AND to_jsonb(NEW)-'approval_state'=to_jsonb(OLD)-'approval_state' THEN RETURN NEW; END IF;
    RAISE EXCEPTION 'An in-use M2 definition is immutable; create a new instrument version' USING ERRCODE='55000';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER m2_bcb_instrument_version BEFORE UPDATE OR DELETE ON public.m2_instrument_versions
  FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_freeze_definition();
CREATE TRIGGER m2_bcb_item_version BEFORE INSERT OR UPDATE OR DELETE ON public.m2_item_versions
  FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_freeze_definition();

-- Match existing M2's default-deny RLS. No production role/grant/policy is invented.
ALTER TABLE public.m2_clarification_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.m2_business_contexts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.m2_business_context_builds ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.m2_clarification_events, public.m2_business_contexts, public.m2_business_context_builds FROM PUBLIC;
REVOKE ALL ON FUNCTION public.m2_bcb_initialize_status(), public.m2_bcb_reject_mutation(), public.m2_bcb_freeze_definition() FROM PUBLIC;
COMMIT;
