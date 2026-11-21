--
-- PostgreSQL database dump
--

\restrict ZaCFGvJWO1cbemRrwaxdEVrLlJFtmqVP4Po108XtZN32W93wrEx9AUmmDVmnie6

-- Dumped from database version 18.6
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: m2_bcb_freeze_definition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.m2_bcb_freeze_definition() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
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


--
-- Name: m2_bcb_initialize_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.m2_bcb_initialize_status() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
BEGIN
  INSERT INTO public.m2_business_context_builds(confirmation_id,assessment_id,owner_user_id,assessment_revision,status)
    VALUES(NEW.id,NEW.assessment_id,NEW.actor_user_id,NEW.assessment_revision,'PENDING');
  RETURN NEW;
END $$;


--
-- Name: m2_bcb_reject_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.m2_bcb_reject_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN RAISE EXCEPTION 'Versioned M2/BCB source records are append-only' USING ERRCODE='55000'; END $$;


--
-- Name: m2_workflow_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.m2_workflow_change() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE rowdata jsonb; aid uuid; uid uuid;
BEGIN
 rowdata:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
 IF TG_TABLE_NAME='m2_assessments' THEN aid:=(rowdata->>'id')::uuid;
 ELSIF rowdata ? 'assessment_id' THEN aid:=(rowdata->>'assessment_id')::uuid;
 ELSE
 uid:=coalesce(rowdata->>'objective_id',rowdata->>'parent_id')::uuid;
 IF uid IS NULL THEN SELECT objective_id INTO uid FROM public.m2_review_question_versions WHERE id=coalesce(rowdata->>'candidate_id',rowdata->>'question_version')::uuid; END IF;
 SELECT c.assessment_id INTO aid FROM public.m2_confirmed_uncertainties u JOIN public.m2_confirmation_snapshots c ON c.id=u.confirmation_id WHERE u.id=uid;
 END IF;
 PERFORM public.refresh_m2_workflow(aid);
 RETURN NULL;
END $$;


--
-- Name: refresh_m2_workflow(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_m2_workflow(aid uuid) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE s record; prev record; fingerprint text;
BEGIN
 PERFORM 1 FROM public.m2_assessments WHERE id=aid FOR UPDATE;
 SELECT * INTO s FROM public.m2_workflow_summary WHERE assessment_id=aid;
 IF NOT FOUND THEN RETURN; END IF;
 fingerprint:=encode(sha256(convert_to(s.summary::text,'UTF8')),'hex');
 SELECT projection_sequence,source_fingerprint INTO prev FROM public.assessment_workflow_projection
 WHERE assessment_id=aid ORDER BY projection_sequence DESC LIMIT 1;
 IF prev.source_fingerprint IS DISTINCT FROM fingerprint THEN
 INSERT INTO public.assessment_workflow_projection(assessment_id,owner_user_id,assessment_revision,projection_sequence,source_fingerprint,projection_data)
 VALUES(aid,s.owner_user_id,s.revision,coalesce(prev.projection_sequence,0)+1,fingerprint,s.summary);
 END IF;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: assessment_workflow_projection; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.assessment_workflow_projection (
    projection_id uuid DEFAULT gen_random_uuid() NOT NULL,
    assessment_id uuid NOT NULL,
    owner_user_id uuid NOT NULL,
    assessment_revision integer NOT NULL,
    projection_sequence bigint NOT NULL,
    schema_version text DEFAULT 'workflow-overview/1'::text NOT NULL,
    source_fingerprint text NOT NULL,
    projection_data jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT assessment_workflow_projection_assessment_revision_check CHECK ((assessment_revision >= 0)),
    CONSTRAINT assessment_workflow_projection_projection_sequence_check CHECK ((projection_sequence > 0)),
    CONSTRAINT assessment_workflow_projection_source_fingerprint_check CHECK ((length(source_fingerprint) = 64))
);


--
-- Name: m2_answer_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_answer_revisions (
    id uuid NOT NULL,
    assessment_id uuid NOT NULL,
    item_version_id uuid NOT NULL,
    assessment_revision integer NOT NULL,
    answer_state character varying(32) NOT NULL,
    value_json json,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_m2_answer_revision CHECK ((assessment_revision > 0))
);


--
-- Name: m2_assessment_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_assessment_links (
    link_id uuid DEFAULT gen_random_uuid() NOT NULL,
    m2_assessment_id uuid NOT NULL,
    marketplace_assessment_id uuid NOT NULL,
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid NOT NULL,
    revoked_at timestamp with time zone,
    revoked_by uuid,
    revoke_reason text,
    CONSTRAINT ck_m2_link_distinct_ids CHECK ((m2_assessment_id <> marketplace_assessment_id)),
    CONSTRAINT ck_m2_link_revocation_state CHECK ((((revoked_at IS NULL) AND (revoked_by IS NULL) AND (revoke_reason IS NULL)) OR ((revoked_at IS NOT NULL) AND (revoked_by IS NOT NULL) AND (revoke_reason IS NOT NULL) AND (length(btrim(revoke_reason)) > 0))))
);

ALTER TABLE ONLY public.m2_assessment_links FORCE ROW LEVEL SECURITY;


--
-- Name: m2_assessments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_assessments (
    id uuid NOT NULL,
    owner_user_id uuid NOT NULL,
    instrument_id uuid NOT NULL,
    revision integer NOT NULL,
    confirmed_revision integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_m2_assessment_revision CHECK (((revision >= 0) AND ((confirmed_revision IS NULL) OR ((confirmed_revision >= 0) AND (confirmed_revision <= revision)))))
);


--
-- Name: m2_bdj_evaluations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_bdj_evaluations (
    id uuid NOT NULL,
    assessment_id uuid NOT NULL,
    assessment_revision integer NOT NULL,
    evaluator_version character varying(64) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_m2_bdj_evaluation_revision CHECK ((assessment_revision >= 0))
);


--
-- Name: m2_bdj_findings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_bdj_findings (
    id uuid NOT NULL,
    assessment_id uuid NOT NULL,
    assessment_revision integer NOT NULL,
    rule_id character varying(64) NOT NULL,
    rule_version character varying(32) NOT NULL,
    source_answer_ids json NOT NULL,
    issue_type character varying(48) NOT NULL,
    explanation text NOT NULL,
    not_proven text NOT NULL,
    next_action text NOT NULL,
    review_state character varying(24) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_m2_bdj_finding_revision CHECK ((assessment_revision >= 0))
);


--
-- Name: m2_business_context_builds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_business_context_builds (
    confirmation_id uuid NOT NULL,
    assessment_id uuid NOT NULL,
    owner_user_id uuid NOT NULL,
    assessment_revision integer NOT NULL,
    status character varying(24) NOT NULL,
    last_code character varying(100),
    context_id uuid,
    attempt_count integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT m2_business_context_builds_assessment_revision_check CHECK ((assessment_revision >= 0)),
    CONSTRAINT m2_business_context_builds_attempt_count_check CHECK ((attempt_count >= 0)),
    CONSTRAINT m2_business_context_builds_check CHECK ((((status)::text = 'PERSISTED'::text) = (context_id IS NOT NULL))),
    CONSTRAINT m2_business_context_builds_status_check CHECK (((status)::text = ANY ((ARRAY['PENDING'::character varying, 'HELD'::character varying, 'PERSISTED'::character varying, 'FAILED'::character varying])::text[])))
);


--
-- Name: m2_business_contexts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_business_contexts (
    context_id uuid NOT NULL,
    assessment_id uuid NOT NULL,
    owner_user_id uuid NOT NULL,
    confirmation_id uuid NOT NULL,
    assessment_revision integer NOT NULL,
    schema_version character varying(100) NOT NULL,
    builder_version character varying(100) NOT NULL,
    purpose character varying(64) NOT NULL,
    tenant_id character varying(200) NOT NULL,
    concept_version character varying(200) NOT NULL,
    snapshot_digest character varying(64) NOT NULL,
    packet_hash character varying(64) NOT NULL,
    canonical_body text NOT NULL,
    packet_json jsonb NOT NULL,
    lifecycle_status character varying(24) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_bcb_canonical_packet CHECK (((jsonb_typeof(packet_json) = 'object'::text) AND ((canonical_body)::jsonb = (packet_json - 'packet_hash'::text)))),
    CONSTRAINT ck_bcb_no_downstream_authority CHECK ((((packet_json -> 'permissions'::text) = '{"qg_execution": false, "qj_execution": false, "report_release": false, "report_admission": false}'::jsonb) IS TRUE)),
    CONSTRAINT ck_bcb_packet_digest CHECK ((((encode(sha256(convert_to(canonical_body, 'UTF8'::name)), 'hex'::text) = (packet_hash)::text) AND ((packet_json ->> 'packet_hash'::text) = (packet_hash)::text)) IS TRUE)),
    CONSTRAINT ck_bcb_source_binding CHECK (((((packet_json #>> '{identity,assessment_id}'::text[]) = (assessment_id)::text) AND ((packet_json #>> '{identity,owner_id}'::text[]) = (owner_user_id)::text) AND ((packet_json #>> '{confirmation,id}'::text[]) = (confirmation_id)::text) AND (((packet_json #>> '{confirmation,revision}'::text[]))::integer = assessment_revision) AND ((packet_json #>> '{confirmation,digest}'::text[]) = (snapshot_digest)::text) AND ((packet_json ->> 'schema_version'::text) = (schema_version)::text) AND ((packet_json ->> 'context_version'::text) = (builder_version)::text) AND ((packet_json #>> '{identity,tenant_id}'::text[]) = (tenant_id)::text) AND ((packet_json #>> '{concept,version}'::text[]) = (concept_version)::text) AND ((packet_json #>> '{access,scope,purpose}'::text[]) = (purpose)::text)) IS TRUE)),
    CONSTRAINT m2_business_contexts_assessment_revision_check CHECK ((assessment_revision >= 0)),
    CONSTRAINT m2_business_contexts_lifecycle_status_check CHECK (((lifecycle_status)::text = 'PERSISTED'::text)),
    CONSTRAINT m2_business_contexts_packet_hash_check CHECK (((packet_hash)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT m2_business_contexts_snapshot_digest_check CHECK (((snapshot_digest)::text ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: m2_candidate_owner_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_candidate_owner_reviews (
    candidate_id uuid NOT NULL,
    reviewer_id uuid NOT NULL,
    decision text NOT NULL,
    rationale text NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT m2_candidate_owner_reviews_decision_check CHECK ((decision = ANY (ARRAY['APPROVE_FOR_REVIEW'::text, 'REJECT'::text]))),
    CONSTRAINT m2_candidate_owner_reviews_rationale_check CHECK (((length(TRIM(BOTH FROM rationale)) >= 1) AND (length(TRIM(BOTH FROM rationale)) <= 1000)))
);


--
-- Name: m2_candidate_review_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_candidate_review_assignments (
    candidate_id uuid NOT NULL,
    reviewer_id uuid NOT NULL,
    authority_reference text NOT NULL,
    CONSTRAINT m2_candidate_review_assignments_authority_reference_check CHECK ((length(TRIM(BOTH FROM authority_reference)) > 0))
);


--
-- Name: m2_clarification_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_clarification_events (
    id uuid NOT NULL,
    assessment_id uuid NOT NULL,
    assessment_revision integer NOT NULL,
    finding_id uuid NOT NULL,
    actor_user_id uuid NOT NULL,
    decision character varying(24) NOT NULL,
    event_sequence integer NOT NULL,
    request_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT m2_clarification_events_assessment_revision_check CHECK ((assessment_revision >= 0)),
    CONSTRAINT m2_clarification_events_decision_check CHECK (((decision)::text = ANY ((ARRAY['KEEP_ORIGINAL'::character varying, 'REVIEW_LATER'::character varying])::text[]))),
    CONSTRAINT m2_clarification_events_event_sequence_check CHECK ((event_sequence > 0))
);


--
-- Name: m2_confirmation_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_confirmation_snapshots (
    id uuid NOT NULL,
    assessment_id uuid NOT NULL,
    assessment_revision integer NOT NULL,
    actor_user_id uuid NOT NULL,
    snapshot_json json NOT NULL,
    snapshot_digest character varying(64) NOT NULL,
    acknowledged_issue_ids json NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_m2_confirmation_revision CHECK ((assessment_revision >= 0))
);


--
-- Name: m2_confirmed_uncertainties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_confirmed_uncertainties (
    id uuid NOT NULL,
    confirmation_id uuid NOT NULL,
    actor_user_id uuid NOT NULL,
    exact_text text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_m2_uncertainty_nonblank CHECK ((length(btrim(exact_text)) > 0))
);


--
-- Name: m2_desired_options; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_desired_options (
    question_version uuid NOT NULL,
    actor_id uuid NOT NULL,
    option_code text NOT NULL
);


--
-- Name: m2_instrument_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_instrument_versions (
    id uuid NOT NULL,
    code character varying(32) NOT NULL,
    version_tag character varying(100) NOT NULL,
    approval_state character varying(24) NOT NULL,
    schema_digest character varying(64) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: m2_item_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_item_versions (
    id uuid NOT NULL,
    instrument_id uuid NOT NULL,
    item_key character varying(32) NOT NULL,
    question_text text NOT NULL,
    requiredness character varying(24) NOT NULL,
    answer_kind character varying(20) NOT NULL,
    option_values json NOT NULL,
    allowed_states json NOT NULL,
    lifecycle character varying(24) NOT NULL,
    sort_order integer NOT NULL
);


--
-- Name: m2_research_clarifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_research_clarifications (
    objective_id uuid NOT NULL,
    limitation text NOT NULL,
    broader_objective text,
    CONSTRAINT m2_research_clarifications_broader_objective_check CHECK (((length(TRIM(BOTH FROM broader_objective)) >= 1) AND (length(TRIM(BOTH FROM broader_objective)) <= 1000))),
    CONSTRAINT m2_research_clarifications_limitation_check CHECK ((length(TRIM(BOTH FROM limitation)) > 0))
);


--
-- Name: m2_research_objective_sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_research_objective_sources (
    objective_id uuid NOT NULL,
    provenance jsonb NOT NULL,
    CONSTRAINT m2_research_objective_sources_provenance_check CHECK ((jsonb_typeof(provenance) = 'object'::text))
);


--
-- Name: m2_research_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_research_revisions (
    parent_id uuid NOT NULL,
    child_id uuid NOT NULL,
    action text NOT NULL,
    CONSTRAINT m2_research_revisions_action_check CHECK ((action = ANY (ARRAY['CLARIFY'::text, 'EXPLORE'::text])))
);


--
-- Name: m2_review_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_review_events (
    id uuid NOT NULL,
    assessment_id uuid NOT NULL,
    assessment_revision integer NOT NULL,
    actor_user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_m2_review_revision CHECK ((assessment_revision >= 0))
);


--
-- Name: m2_review_question_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.m2_review_question_versions (
    id uuid NOT NULL,
    objective_id uuid NOT NULL,
    source_receipt text NOT NULL,
    question text NOT NULL,
    options jsonb NOT NULL,
    supersedes uuid
);


--
-- Name: m2_workflow_campaigns; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.m2_workflow_campaigns WITH (security_invoker='true') AS
 SELECT NULL::uuid AS assessment_id,
    NULL::uuid AS owner_user_id,
    NULL::jsonb AS campaigns
  WHERE false;


--
-- Name: m2_workflow_summary; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.m2_workflow_summary WITH (security_invoker='true') AS
 SELECT a.id AS assessment_id,
    a.owner_user_id,
    a.revision,
    jsonb_build_object('assessment', jsonb_build_object('id', a.id, 'revision', a.revision, 'confirmed_revision', a.confirmed_revision, 'instrument_version', i.version_tag), 'review_events', COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', v.id, 'revision', v.assessment_revision) ORDER BY v.created_at, v.id) AS jsonb_agg
           FROM public.m2_review_events v
          WHERE (v.assessment_id = a.id)), '[]'::jsonb), 'clarifications', COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', v.id, 'revision', v.assessment_revision, 'finding', v.finding_id, 'decision', v.decision, 'sequence', v.event_sequence) ORDER BY v.assessment_revision, v.event_sequence) AS jsonb_agg
           FROM public.m2_clarification_events v
          WHERE (v.assessment_id = a.id)), '[]'::jsonb), 'confirmations', COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', c.id, 'revision', c.assessment_revision, 'digest', c.snapshot_digest) ORDER BY c.id) AS jsonb_agg
           FROM public.m2_confirmation_snapshots c
          WHERE (c.assessment_id = a.id)), '[]'::jsonb), 'contexts', COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', b.context_id, 'revision', b.assessment_revision, 'hash', b.packet_hash, 'status', b.lifecycle_status, 'attributes', (b.packet_json #> '{business_description,source_question_ids}'::text[])) ORDER BY b.context_id) AS jsonb_agg
           FROM public.m2_business_contexts b
          WHERE (b.assessment_id = a.id)), '[]'::jsonb), 'builds', COALESCE(( SELECT jsonb_agg(jsonb_build_object('confirmation', b.confirmation_id, 'revision', b.assessment_revision, 'status', b.status, 'reason', b.last_code, 'attempts', b.attempt_count) ORDER BY b.confirmation_id) AS jsonb_agg
           FROM public.m2_business_context_builds b
          WHERE (b.assessment_id = a.id)), '[]'::jsonb), 'bdj_evaluations', COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', e.id, 'revision', e.assessment_revision, 'rule_version', e.evaluator_version) ORDER BY e.id) AS jsonb_agg
           FROM public.m2_bdj_evaluations e
          WHERE (e.assessment_id = a.id)), '[]'::jsonb), 'findings', COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', f.id, 'revision', f.assessment_revision, 'type', f.issue_type, 'decision', f.review_state, 'sources', f.source_answer_ids) ORDER BY f.id) AS jsonb_agg
           FROM public.m2_bdj_findings f
          WHERE (f.assessment_id = a.id)), '[]'::jsonb), 'objectives', COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', u.id, 'revision', c.assessment_revision, 'confirmation', c.id, 'origin', (s.provenance ->> 'origin'::text), 'parent', (s.provenance ->> 'parent_objective_id'::text), 'exploration_used', (s.provenance -> 'exploration_used'::text), 'limitation_recorded', (l.objective_id IS NOT NULL), 'child', r.child_id) ORDER BY u.id) AS jsonb_agg
           FROM ((((public.m2_confirmation_snapshots c
             JOIN public.m2_confirmed_uncertainties u ON ((u.confirmation_id = c.id)))
             JOIN public.m2_research_objective_sources s ON ((s.objective_id = u.id)))
             LEFT JOIN public.m2_research_clarifications l ON ((l.objective_id = u.id)))
             LEFT JOIN public.m2_research_revisions r ON ((r.parent_id = u.id)))
          WHERE (c.assessment_id = a.id)), '[]'::jsonb), 'candidates', COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', q.id, 'objective', u.id, 'revision', c.assessment_revision, 'supersedes', q.supersedes, 'desired_option', d.option_code, 'qj_route', (receipt.data #>> '{evaluation,qj,route}'::text[]), 'bank_outcome', (receipt.data #>> '{evaluation,bank}'::text[]), 'candidate_decision', (receipt.data #>> '{evaluation,qg,decision}'::text[]), 'source_version', (receipt.data #>> '{candidate,source_version}'::text[]), 'owner_decision', v.decision, 'decision_time', to_char((v.recorded_at AT TIME ZONE 'UTC'::text), 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'::text)) ORDER BY q.id) AS jsonb_agg
           FROM (((((public.m2_confirmation_snapshots c
             JOIN public.m2_confirmed_uncertainties u ON ((u.confirmation_id = c.id)))
             JOIN public.m2_review_question_versions q ON ((q.objective_id = u.id)))
             CROSS JOIN LATERAL ( SELECT
                        CASE
                            WHEN (q.source_receipt IS JSON OBJECT) THEN (q.source_receipt)::jsonb
                            ELSE NULL::jsonb
                        END AS data) receipt)
             LEFT JOIN public.m2_desired_options d ON ((d.question_version = q.id)))
             LEFT JOIN public.m2_candidate_owner_reviews v ON ((v.candidate_id = q.id)))
          WHERE (c.assessment_id = a.id)), '[]'::jsonb), 'campaigns', ( SELECT cq.campaigns
           FROM public.m2_workflow_campaigns cq
          WHERE ((cq.assessment_id = a.id) AND (cq.owner_user_id = a.owner_user_id))), 'llm_execution', 'NOT_VERIFIED', 'scientific_review', 'NOT_VERIFIED', 'fielding', 'NOT_VERIFIED', 'report_admission', 'NOT_VERIFIED') AS summary
   FROM (public.m2_assessments a
     JOIN public.m2_instrument_versions i ON ((i.id = a.instrument_id)));


--
-- Name: test_bcb_bindings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.test_bcb_bindings (
    confirmation_id uuid NOT NULL,
    owner_id uuid NOT NULL,
    request_json jsonb NOT NULL,
    decision_json jsonb NOT NULL,
    bindings_json jsonb NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    user_id uuid NOT NULL,
    full_name character varying,
    email character varying(255) NOT NULL,
    phone_number character varying(20),
    role character varying(20) NOT NULL,
    profile_picture_url character varying,
    account_status character varying(20) NOT NULL,
    email_verified boolean NOT NULL,
    last_login timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: assessment_workflow_projection assessment_workflow_projectio_assessment_id_projection_sequ_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assessment_workflow_projection
    ADD CONSTRAINT assessment_workflow_projectio_assessment_id_projection_sequ_key UNIQUE (assessment_id, projection_sequence);


--
-- Name: assessment_workflow_projection assessment_workflow_projection_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assessment_workflow_projection
    ADD CONSTRAINT assessment_workflow_projection_pkey PRIMARY KEY (projection_id);


--
-- Name: m2_answer_revisions m2_answer_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_answer_revisions
    ADD CONSTRAINT m2_answer_revisions_pkey PRIMARY KEY (id);


--
-- Name: m2_assessment_links m2_assessment_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_assessment_links
    ADD CONSTRAINT m2_assessment_links_pkey PRIMARY KEY (link_id);


--
-- Name: m2_assessments m2_assessments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_assessments
    ADD CONSTRAINT m2_assessments_pkey PRIMARY KEY (id);


--
-- Name: m2_bdj_evaluations m2_bdj_evaluations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_bdj_evaluations
    ADD CONSTRAINT m2_bdj_evaluations_pkey PRIMARY KEY (id);


--
-- Name: m2_bdj_findings m2_bdj_findings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_bdj_findings
    ADD CONSTRAINT m2_bdj_findings_pkey PRIMARY KEY (id);


--
-- Name: m2_business_context_builds m2_business_context_builds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_business_context_builds
    ADD CONSTRAINT m2_business_context_builds_pkey PRIMARY KEY (confirmation_id);


--
-- Name: m2_business_contexts m2_business_contexts_packet_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_business_contexts
    ADD CONSTRAINT m2_business_contexts_packet_hash_key UNIQUE (packet_hash);


--
-- Name: m2_business_contexts m2_business_contexts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_business_contexts
    ADD CONSTRAINT m2_business_contexts_pkey PRIMARY KEY (context_id);


--
-- Name: m2_candidate_owner_reviews m2_candidate_owner_reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_candidate_owner_reviews
    ADD CONSTRAINT m2_candidate_owner_reviews_pkey PRIMARY KEY (candidate_id);


--
-- Name: m2_candidate_review_assignments m2_candidate_review_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_candidate_review_assignments
    ADD CONSTRAINT m2_candidate_review_assignments_pkey PRIMARY KEY (candidate_id, reviewer_id);


--
-- Name: m2_clarification_events m2_clarification_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_clarification_events
    ADD CONSTRAINT m2_clarification_events_pkey PRIMARY KEY (id);


--
-- Name: m2_confirmation_snapshots m2_confirmation_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_confirmation_snapshots
    ADD CONSTRAINT m2_confirmation_snapshots_pkey PRIMARY KEY (id);


--
-- Name: m2_confirmed_uncertainties m2_confirmed_uncertainties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_confirmed_uncertainties
    ADD CONSTRAINT m2_confirmed_uncertainties_pkey PRIMARY KEY (id);


--
-- Name: m2_desired_options m2_desired_options_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_desired_options
    ADD CONSTRAINT m2_desired_options_pkey PRIMARY KEY (question_version);


--
-- Name: m2_instrument_versions m2_instrument_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_instrument_versions
    ADD CONSTRAINT m2_instrument_versions_pkey PRIMARY KEY (id);


--
-- Name: m2_item_versions m2_item_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_item_versions
    ADD CONSTRAINT m2_item_versions_pkey PRIMARY KEY (id);


--
-- Name: m2_research_clarifications m2_research_clarifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_research_clarifications
    ADD CONSTRAINT m2_research_clarifications_pkey PRIMARY KEY (objective_id);


--
-- Name: m2_research_objective_sources m2_research_objective_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_research_objective_sources
    ADD CONSTRAINT m2_research_objective_sources_pkey PRIMARY KEY (objective_id);


--
-- Name: m2_research_revisions m2_research_revisions_child_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_research_revisions
    ADD CONSTRAINT m2_research_revisions_child_id_key UNIQUE (child_id);


--
-- Name: m2_research_revisions m2_research_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_research_revisions
    ADD CONSTRAINT m2_research_revisions_pkey PRIMARY KEY (parent_id);


--
-- Name: m2_review_events m2_review_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_review_events
    ADD CONSTRAINT m2_review_events_pkey PRIMARY KEY (id);


--
-- Name: m2_review_question_versions m2_review_question_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_review_question_versions
    ADD CONSTRAINT m2_review_question_versions_pkey PRIMARY KEY (id);


--
-- Name: m2_review_question_versions m2_review_question_versions_supersedes_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_review_question_versions
    ADD CONSTRAINT m2_review_question_versions_supersedes_key UNIQUE (supersedes);


--
-- Name: test_bcb_bindings test_bcb_bindings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_bcb_bindings
    ADD CONSTRAINT test_bcb_bindings_pkey PRIMARY KEY (confirmation_id);


--
-- Name: m2_business_contexts uq_bcb_full_source; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_business_contexts
    ADD CONSTRAINT uq_bcb_full_source UNIQUE (context_id, confirmation_id, assessment_id, assessment_revision, owner_user_id);


--
-- Name: m2_answer_revisions uq_m2_answer_revision; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_answer_revisions
    ADD CONSTRAINT uq_m2_answer_revision UNIQUE (assessment_id, item_version_id, assessment_revision);


--
-- Name: m2_assessments uq_m2_assessment_owner; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_assessments
    ADD CONSTRAINT uq_m2_assessment_owner UNIQUE (id, owner_user_id);


--
-- Name: m2_bdj_evaluations uq_m2_bdj_evaluation; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_bdj_evaluations
    ADD CONSTRAINT uq_m2_bdj_evaluation UNIQUE (assessment_id, assessment_revision, evaluator_version);


--
-- Name: m2_bdj_findings uq_m2_bdj_rule_revision; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_bdj_findings
    ADD CONSTRAINT uq_m2_bdj_rule_revision UNIQUE (assessment_id, assessment_revision, rule_id, rule_version);


--
-- Name: m2_clarification_events uq_m2_clarification_request; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_clarification_events
    ADD CONSTRAINT uq_m2_clarification_request UNIQUE (assessment_id, request_id);


--
-- Name: m2_clarification_events uq_m2_clarification_sequence; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_clarification_events
    ADD CONSTRAINT uq_m2_clarification_sequence UNIQUE (assessment_id, assessment_revision, event_sequence);


--
-- Name: m2_confirmation_snapshots uq_m2_confirmation_revision; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_confirmation_snapshots
    ADD CONSTRAINT uq_m2_confirmation_revision UNIQUE (assessment_id, assessment_revision);


--
-- Name: m2_confirmation_snapshots uq_m2_confirmation_source; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_confirmation_snapshots
    ADD CONSTRAINT uq_m2_confirmation_source UNIQUE (id, assessment_id, assessment_revision, actor_user_id);


--
-- Name: m2_bdj_findings uq_m2_finding_source; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_bdj_findings
    ADD CONSTRAINT uq_m2_finding_source UNIQUE (id, assessment_id, assessment_revision);


--
-- Name: m2_instrument_versions uq_m2_instrument_code_version; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_instrument_versions
    ADD CONSTRAINT uq_m2_instrument_code_version UNIQUE (code, version_tag);


--
-- Name: m2_item_versions uq_m2_item_instrument_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_item_versions
    ADD CONSTRAINT uq_m2_item_instrument_key UNIQUE (instrument_id, item_key);


--
-- Name: m2_review_events uq_m2_review_revision; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_review_events
    ADD CONSTRAINT uq_m2_review_revision UNIQUE (assessment_id, assessment_revision);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (user_id);


--
-- Name: ix_bcb_owner_assessment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_bcb_owner_assessment ON public.m2_business_contexts USING btree (owner_user_id, assessment_id, created_at);


--
-- Name: ix_m2_answer_revisions_assessment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_m2_answer_revisions_assessment_id ON public.m2_answer_revisions USING btree (assessment_id);


--
-- Name: ix_m2_assessments_owner_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_m2_assessments_owner_user_id ON public.m2_assessments USING btree (owner_user_id);


--
-- Name: ix_m2_confirmation_assessment_revision; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_m2_confirmation_assessment_revision ON public.m2_confirmation_snapshots USING btree (assessment_id, assessment_revision);


--
-- Name: ix_m2_evaluations_assessment_revision; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_m2_evaluations_assessment_revision ON public.m2_bdj_evaluations USING btree (assessment_id, assessment_revision);


--
-- Name: ix_m2_findings_assessment_revision; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_m2_findings_assessment_revision ON public.m2_bdj_findings USING btree (assessment_id, assessment_revision);


--
-- Name: ix_m2_link_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_m2_link_user ON public.m2_assessment_links USING btree (user_id);


--
-- Name: ix_m2_review_events_assessment_revision; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_m2_review_events_assessment_revision ON public.m2_review_events USING btree (assessment_id, assessment_revision);


--
-- Name: ix_m2_uncertainties_confirmation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_m2_uncertainties_confirmation_id ON public.m2_confirmed_uncertainties USING btree (confirmation_id);


--
-- Name: uq_m2_link_m2_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_m2_link_m2_active ON public.m2_assessment_links USING btree (m2_assessment_id) WHERE (revoked_at IS NULL);


--
-- Name: uq_m2_link_marketplace_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_m2_link_marketplace_active ON public.m2_assessment_links USING btree (marketplace_assessment_id) WHERE (revoked_at IS NULL);


--
-- Name: assessment_workflow_projection immutable_projection; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_projection BEFORE DELETE OR UPDATE ON public.assessment_workflow_projection FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();


--
-- Name: m2_answer_revisions m2_bcb_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_bcb_append_only BEFORE DELETE OR UPDATE ON public.m2_answer_revisions FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();


--
-- Name: m2_bdj_evaluations m2_bcb_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_bcb_append_only BEFORE DELETE OR UPDATE ON public.m2_bdj_evaluations FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();


--
-- Name: m2_bdj_findings m2_bcb_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_bcb_append_only BEFORE DELETE OR UPDATE ON public.m2_bdj_findings FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();


--
-- Name: m2_business_contexts m2_bcb_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_bcb_append_only BEFORE DELETE OR UPDATE ON public.m2_business_contexts FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();


--
-- Name: m2_clarification_events m2_bcb_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_bcb_append_only BEFORE DELETE OR UPDATE ON public.m2_clarification_events FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();


--
-- Name: m2_confirmation_snapshots m2_bcb_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_bcb_append_only BEFORE DELETE OR UPDATE ON public.m2_confirmation_snapshots FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();


--
-- Name: m2_confirmed_uncertainties m2_bcb_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_bcb_append_only BEFORE DELETE OR UPDATE ON public.m2_confirmed_uncertainties FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();


--
-- Name: m2_review_events m2_bcb_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_bcb_append_only BEFORE DELETE OR UPDATE ON public.m2_review_events FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();


--
-- Name: m2_confirmation_snapshots m2_bcb_confirmation_status; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_bcb_confirmation_status AFTER INSERT ON public.m2_confirmation_snapshots FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_initialize_status();


--
-- Name: m2_instrument_versions m2_bcb_instrument_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_bcb_instrument_version BEFORE DELETE OR UPDATE ON public.m2_instrument_versions FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_freeze_definition();


--
-- Name: m2_item_versions m2_bcb_item_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_bcb_item_version BEFORE INSERT OR DELETE OR UPDATE ON public.m2_item_versions FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_freeze_definition();


--
-- Name: m2_research_clarifications m2_clarification_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_clarification_append_only BEFORE DELETE OR UPDATE ON public.m2_research_clarifications FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();


--
-- Name: m2_research_objective_sources m2_objective_source_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_objective_source_append_only BEFORE DELETE OR UPDATE ON public.m2_research_objective_sources FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();


--
-- Name: m2_candidate_owner_reviews m2_owner_review_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_owner_review_append_only BEFORE DELETE OR UPDATE ON public.m2_candidate_owner_reviews FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();


--
-- Name: m2_review_question_versions m2_question_version_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_question_version_append_only BEFORE DELETE OR UPDATE ON public.m2_review_question_versions FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();


--
-- Name: m2_research_revisions m2_revision_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER m2_revision_append_only BEFORE DELETE OR UPDATE ON public.m2_research_revisions FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();


--
-- Name: m2_assessments refresh_workflow; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER refresh_workflow AFTER INSERT OR DELETE OR UPDATE ON public.m2_assessments DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_change();


--
-- Name: m2_bdj_evaluations refresh_workflow; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER refresh_workflow AFTER INSERT OR DELETE OR UPDATE ON public.m2_bdj_evaluations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_change();


--
-- Name: m2_bdj_findings refresh_workflow; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER refresh_workflow AFTER INSERT OR DELETE OR UPDATE ON public.m2_bdj_findings DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_change();


--
-- Name: m2_business_context_builds refresh_workflow; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER refresh_workflow AFTER INSERT OR DELETE OR UPDATE ON public.m2_business_context_builds DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_change();


--
-- Name: m2_business_contexts refresh_workflow; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER refresh_workflow AFTER INSERT OR DELETE OR UPDATE ON public.m2_business_contexts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_change();


--
-- Name: m2_candidate_owner_reviews refresh_workflow; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER refresh_workflow AFTER INSERT OR DELETE OR UPDATE ON public.m2_candidate_owner_reviews DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_change();


--
-- Name: m2_clarification_events refresh_workflow; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER refresh_workflow AFTER INSERT OR DELETE OR UPDATE ON public.m2_clarification_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_change();


--
-- Name: m2_confirmation_snapshots refresh_workflow; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER refresh_workflow AFTER INSERT OR DELETE OR UPDATE ON public.m2_confirmation_snapshots DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_change();


--
-- Name: m2_desired_options refresh_workflow; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER refresh_workflow AFTER INSERT OR DELETE OR UPDATE ON public.m2_desired_options DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_change();


--
-- Name: m2_research_clarifications refresh_workflow; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER refresh_workflow AFTER INSERT OR DELETE OR UPDATE ON public.m2_research_clarifications DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_change();


--
-- Name: m2_research_objective_sources refresh_workflow; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER refresh_workflow AFTER INSERT OR DELETE OR UPDATE ON public.m2_research_objective_sources DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_change();


--
-- Name: m2_research_revisions refresh_workflow; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER refresh_workflow AFTER INSERT OR DELETE OR UPDATE ON public.m2_research_revisions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_change();


--
-- Name: m2_review_events refresh_workflow; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER refresh_workflow AFTER INSERT OR DELETE OR UPDATE ON public.m2_review_events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_change();


--
-- Name: m2_review_question_versions refresh_workflow; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER refresh_workflow AFTER INSERT OR DELETE OR UPDATE ON public.m2_review_question_versions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_change();


--
-- Name: assessment_workflow_projection assessment_workflow_projection_assessment_id_owner_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assessment_workflow_projection
    ADD CONSTRAINT assessment_workflow_projection_assessment_id_owner_user_id_fkey FOREIGN KEY (assessment_id, owner_user_id) REFERENCES public.m2_assessments(id, owner_user_id);


--
-- Name: m2_business_contexts fk_bcb_confirmation_source; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_business_contexts
    ADD CONSTRAINT fk_bcb_confirmation_source FOREIGN KEY (confirmation_id, assessment_id, assessment_revision, owner_user_id) REFERENCES public.m2_confirmation_snapshots(id, assessment_id, assessment_revision, actor_user_id);


--
-- Name: m2_confirmation_snapshots fk_m2_confirmation_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_confirmation_snapshots
    ADD CONSTRAINT fk_m2_confirmation_actor FOREIGN KEY (actor_user_id) REFERENCES public.users(user_id) ON DELETE RESTRICT;


--
-- Name: m2_confirmation_snapshots fk_m2_confirmation_owner; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_confirmation_snapshots
    ADD CONSTRAINT fk_m2_confirmation_owner FOREIGN KEY (assessment_id, actor_user_id) REFERENCES public.m2_assessments(id, owner_user_id);


--
-- Name: m2_assessment_links fk_m2_link_assessment_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_assessment_links
    ADD CONSTRAINT fk_m2_link_assessment_user FOREIGN KEY (m2_assessment_id, user_id) REFERENCES public.m2_assessments(id, owner_user_id) ON DELETE RESTRICT;


--
-- Name: m2_assessment_links fk_m2_link_created_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_assessment_links
    ADD CONSTRAINT fk_m2_link_created_by FOREIGN KEY (created_by) REFERENCES public.users(user_id) ON DELETE RESTRICT;


--
-- Name: m2_assessment_links fk_m2_link_revoked_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_assessment_links
    ADD CONSTRAINT fk_m2_link_revoked_by FOREIGN KEY (revoked_by) REFERENCES public.users(user_id) ON DELETE RESTRICT;


--
-- Name: m2_assessment_links fk_m2_link_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_assessment_links
    ADD CONSTRAINT fk_m2_link_user FOREIGN KEY (user_id) REFERENCES public.users(user_id) ON DELETE RESTRICT;


--
-- Name: m2_assessments fk_m2_owner_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_assessments
    ADD CONSTRAINT fk_m2_owner_user FOREIGN KEY (owner_user_id) REFERENCES public.users(user_id) ON DELETE RESTRICT;


--
-- Name: m2_review_events fk_m2_review_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_review_events
    ADD CONSTRAINT fk_m2_review_actor FOREIGN KEY (actor_user_id) REFERENCES public.users(user_id) ON DELETE RESTRICT;


--
-- Name: m2_review_events fk_m2_review_owner; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_review_events
    ADD CONSTRAINT fk_m2_review_owner FOREIGN KEY (assessment_id, actor_user_id) REFERENCES public.m2_assessments(id, owner_user_id);


--
-- Name: m2_confirmed_uncertainties fk_m2_uncertainty_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_confirmed_uncertainties
    ADD CONSTRAINT fk_m2_uncertainty_actor FOREIGN KEY (actor_user_id) REFERENCES public.users(user_id) ON DELETE RESTRICT;


--
-- Name: m2_answer_revisions m2_answer_revisions_assessment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_answer_revisions
    ADD CONSTRAINT m2_answer_revisions_assessment_id_fkey FOREIGN KEY (assessment_id) REFERENCES public.m2_assessments(id);


--
-- Name: m2_answer_revisions m2_answer_revisions_item_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_answer_revisions
    ADD CONSTRAINT m2_answer_revisions_item_version_id_fkey FOREIGN KEY (item_version_id) REFERENCES public.m2_item_versions(id);


--
-- Name: m2_assessments m2_assessments_instrument_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_assessments
    ADD CONSTRAINT m2_assessments_instrument_id_fkey FOREIGN KEY (instrument_id) REFERENCES public.m2_instrument_versions(id);


--
-- Name: m2_bdj_evaluations m2_bdj_evaluations_assessment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_bdj_evaluations
    ADD CONSTRAINT m2_bdj_evaluations_assessment_id_fkey FOREIGN KEY (assessment_id) REFERENCES public.m2_assessments(id);


--
-- Name: m2_bdj_findings m2_bdj_findings_assessment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_bdj_findings
    ADD CONSTRAINT m2_bdj_findings_assessment_id_fkey FOREIGN KEY (assessment_id) REFERENCES public.m2_assessments(id);


--
-- Name: m2_business_context_builds m2_business_context_builds_confirmation_id_assessment_id_a_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_business_context_builds
    ADD CONSTRAINT m2_business_context_builds_confirmation_id_assessment_id_a_fkey FOREIGN KEY (confirmation_id, assessment_id, assessment_revision, owner_user_id) REFERENCES public.m2_confirmation_snapshots(id, assessment_id, assessment_revision, actor_user_id);


--
-- Name: m2_business_context_builds m2_business_context_builds_context_id_confirmation_id_asse_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_business_context_builds
    ADD CONSTRAINT m2_business_context_builds_context_id_confirmation_id_asse_fkey FOREIGN KEY (context_id, confirmation_id, assessment_id, assessment_revision, owner_user_id) REFERENCES public.m2_business_contexts(context_id, confirmation_id, assessment_id, assessment_revision, owner_user_id);


--
-- Name: m2_business_context_builds m2_business_context_builds_context_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_business_context_builds
    ADD CONSTRAINT m2_business_context_builds_context_id_fkey FOREIGN KEY (context_id) REFERENCES public.m2_business_contexts(context_id);


--
-- Name: m2_candidate_owner_reviews m2_candidate_owner_reviews_candidate_id_reviewer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_candidate_owner_reviews
    ADD CONSTRAINT m2_candidate_owner_reviews_candidate_id_reviewer_id_fkey FOREIGN KEY (candidate_id, reviewer_id) REFERENCES public.m2_candidate_review_assignments(candidate_id, reviewer_id);


--
-- Name: m2_candidate_review_assignments m2_candidate_review_assignments_candidate_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_candidate_review_assignments
    ADD CONSTRAINT m2_candidate_review_assignments_candidate_id_fkey FOREIGN KEY (candidate_id) REFERENCES public.m2_review_question_versions(id);


--
-- Name: m2_clarification_events m2_clarification_events_assessment_id_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_clarification_events
    ADD CONSTRAINT m2_clarification_events_assessment_id_actor_user_id_fkey FOREIGN KEY (assessment_id, actor_user_id) REFERENCES public.m2_assessments(id, owner_user_id);


--
-- Name: m2_clarification_events m2_clarification_events_assessment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_clarification_events
    ADD CONSTRAINT m2_clarification_events_assessment_id_fkey FOREIGN KEY (assessment_id) REFERENCES public.m2_assessments(id);


--
-- Name: m2_clarification_events m2_clarification_events_finding_id_assessment_id_assessmen_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_clarification_events
    ADD CONSTRAINT m2_clarification_events_finding_id_assessment_id_assessmen_fkey FOREIGN KEY (finding_id, assessment_id, assessment_revision) REFERENCES public.m2_bdj_findings(id, assessment_id, assessment_revision);


--
-- Name: m2_confirmation_snapshots m2_confirmation_snapshots_assessment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_confirmation_snapshots
    ADD CONSTRAINT m2_confirmation_snapshots_assessment_id_fkey FOREIGN KEY (assessment_id) REFERENCES public.m2_assessments(id);


--
-- Name: m2_confirmed_uncertainties m2_confirmed_uncertainties_confirmation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_confirmed_uncertainties
    ADD CONSTRAINT m2_confirmed_uncertainties_confirmation_id_fkey FOREIGN KEY (confirmation_id) REFERENCES public.m2_confirmation_snapshots(id);


--
-- Name: m2_desired_options m2_desired_options_question_version_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_desired_options
    ADD CONSTRAINT m2_desired_options_question_version_fkey FOREIGN KEY (question_version) REFERENCES public.m2_review_question_versions(id);


--
-- Name: m2_item_versions m2_item_versions_instrument_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_item_versions
    ADD CONSTRAINT m2_item_versions_instrument_id_fkey FOREIGN KEY (instrument_id) REFERENCES public.m2_instrument_versions(id);


--
-- Name: m2_research_clarifications m2_research_clarifications_objective_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_research_clarifications
    ADD CONSTRAINT m2_research_clarifications_objective_id_fkey FOREIGN KEY (objective_id) REFERENCES public.m2_research_objective_sources(objective_id);


--
-- Name: m2_research_objective_sources m2_research_objective_sources_objective_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_research_objective_sources
    ADD CONSTRAINT m2_research_objective_sources_objective_id_fkey FOREIGN KEY (objective_id) REFERENCES public.m2_confirmed_uncertainties(id);


--
-- Name: m2_research_revisions m2_research_revisions_child_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_research_revisions
    ADD CONSTRAINT m2_research_revisions_child_id_fkey FOREIGN KEY (child_id) REFERENCES public.m2_research_objective_sources(objective_id);


--
-- Name: m2_research_revisions m2_research_revisions_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_research_revisions
    ADD CONSTRAINT m2_research_revisions_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.m2_research_clarifications(objective_id);


--
-- Name: m2_review_events m2_review_events_assessment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_review_events
    ADD CONSTRAINT m2_review_events_assessment_id_fkey FOREIGN KEY (assessment_id) REFERENCES public.m2_assessments(id);


--
-- Name: m2_review_question_versions m2_review_question_versions_objective_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_review_question_versions
    ADD CONSTRAINT m2_review_question_versions_objective_id_fkey FOREIGN KEY (objective_id) REFERENCES public.m2_research_objective_sources(objective_id);


--
-- Name: m2_review_question_versions m2_review_question_versions_supersedes_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_review_question_versions
    ADD CONSTRAINT m2_review_question_versions_supersedes_fkey FOREIGN KEY (supersedes) REFERENCES public.m2_review_question_versions(id);


--
-- Name: assessment_workflow_projection; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.assessment_workflow_projection ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_answer_revisions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_answer_revisions ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_assessment_links; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_assessment_links ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_assessments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_assessments ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_bdj_evaluations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_bdj_evaluations ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_bdj_findings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_bdj_findings ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_business_context_builds; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_business_context_builds ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_business_contexts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_business_contexts ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_candidate_owner_reviews; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_candidate_owner_reviews ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_candidate_review_assignments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_candidate_review_assignments ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_clarification_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_clarification_events ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_confirmation_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_confirmation_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_confirmed_uncertainties; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_confirmed_uncertainties ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_desired_options; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_desired_options ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_instrument_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_instrument_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_item_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_item_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_research_clarifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_research_clarifications ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_research_objective_sources; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_research_objective_sources ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_research_revisions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_research_revisions ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_review_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_review_events ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_review_question_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_review_question_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: assessment_workflow_projection owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.assessment_workflow_projection USING ((owner_user_id = (NULLIF(current_setting('project1.actor_id'::text, true), ''::text))::uuid)) WITH CHECK ((owner_user_id = (NULLIF(current_setting('project1.actor_id'::text, true), ''::text))::uuid));


--
-- Name: m2_answer_revisions owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_answer_revisions USING ((assessment_id IN ( SELECT m2_assessments.id
   FROM public.m2_assessments))) WITH CHECK ((assessment_id IN ( SELECT m2_assessments.id
   FROM public.m2_assessments)));


--
-- Name: m2_assessment_links owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_assessment_links USING ((user_id = (NULLIF(current_setting('project1.actor_id'::text, true), ''::text))::uuid)) WITH CHECK ((user_id = (NULLIF(current_setting('project1.actor_id'::text, true), ''::text))::uuid));


--
-- Name: m2_assessments owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_assessments USING ((owner_user_id = (NULLIF(current_setting('project1.actor_id'::text, true), ''::text))::uuid)) WITH CHECK ((owner_user_id = (NULLIF(current_setting('project1.actor_id'::text, true), ''::text))::uuid));


--
-- Name: m2_bdj_evaluations owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_bdj_evaluations USING ((assessment_id IN ( SELECT m2_assessments.id
   FROM public.m2_assessments))) WITH CHECK ((assessment_id IN ( SELECT m2_assessments.id
   FROM public.m2_assessments)));


--
-- Name: m2_bdj_findings owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_bdj_findings USING ((assessment_id IN ( SELECT m2_assessments.id
   FROM public.m2_assessments))) WITH CHECK ((assessment_id IN ( SELECT m2_assessments.id
   FROM public.m2_assessments)));


--
-- Name: m2_business_context_builds owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_business_context_builds USING ((owner_user_id = (NULLIF(current_setting('project1.actor_id'::text, true), ''::text))::uuid)) WITH CHECK ((owner_user_id = (NULLIF(current_setting('project1.actor_id'::text, true), ''::text))::uuid));


--
-- Name: m2_business_contexts owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_business_contexts USING ((owner_user_id = (NULLIF(current_setting('project1.actor_id'::text, true), ''::text))::uuid)) WITH CHECK ((owner_user_id = (NULLIF(current_setting('project1.actor_id'::text, true), ''::text))::uuid));


--
-- Name: m2_candidate_owner_reviews owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_candidate_owner_reviews FOR SELECT USING ((candidate_id IN ( SELECT m2_review_question_versions.id
   FROM public.m2_review_question_versions)));


--
-- Name: m2_clarification_events owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_clarification_events USING ((assessment_id IN ( SELECT m2_assessments.id
   FROM public.m2_assessments))) WITH CHECK ((assessment_id IN ( SELECT m2_assessments.id
   FROM public.m2_assessments)));


--
-- Name: m2_confirmation_snapshots owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_confirmation_snapshots USING ((assessment_id IN ( SELECT m2_assessments.id
   FROM public.m2_assessments))) WITH CHECK ((assessment_id IN ( SELECT m2_assessments.id
   FROM public.m2_assessments)));


--
-- Name: m2_confirmed_uncertainties owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_confirmed_uncertainties USING ((confirmation_id IN ( SELECT m2_confirmation_snapshots.id
   FROM public.m2_confirmation_snapshots))) WITH CHECK ((confirmation_id IN ( SELECT m2_confirmation_snapshots.id
   FROM public.m2_confirmation_snapshots)));


--
-- Name: m2_desired_options owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_desired_options FOR SELECT USING ((question_version IN ( SELECT m2_review_question_versions.id
   FROM public.m2_review_question_versions)));


--
-- Name: m2_research_clarifications owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_research_clarifications FOR SELECT USING ((objective_id IN ( SELECT m2_confirmed_uncertainties.id
   FROM public.m2_confirmed_uncertainties)));


--
-- Name: m2_research_objective_sources owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_research_objective_sources FOR SELECT USING ((objective_id IN ( SELECT m2_confirmed_uncertainties.id
   FROM public.m2_confirmed_uncertainties)));


--
-- Name: m2_research_revisions owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_research_revisions FOR SELECT USING ((parent_id IN ( SELECT m2_confirmed_uncertainties.id
   FROM public.m2_confirmed_uncertainties)));


--
-- Name: m2_review_events owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_review_events USING ((assessment_id IN ( SELECT m2_assessments.id
   FROM public.m2_assessments))) WITH CHECK ((assessment_id IN ( SELECT m2_assessments.id
   FROM public.m2_assessments)));


--
-- Name: m2_review_question_versions owner_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owner_scope ON public.m2_review_question_versions FOR SELECT USING ((objective_id IN ( SELECT m2_confirmed_uncertainties.id
   FROM public.m2_confirmed_uncertainties)));


--
-- Name: m2_instrument_versions reference_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY reference_read ON public.m2_instrument_versions FOR SELECT USING (true);


--
-- Name: m2_item_versions reference_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY reference_read ON public.m2_item_versions FOR SELECT USING (true);


--
-- PostgreSQL database dump complete
--

\unrestrict ZaCFGvJWO1cbemRrwaxdEVrLlJFtmqVP4Po108XtZN32W93wrEx9AUmmDVmnie6

