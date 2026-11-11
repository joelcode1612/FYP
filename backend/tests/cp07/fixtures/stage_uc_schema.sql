--
-- PostgreSQL database dump
--

\restrict SNb0dQS0NSfgLGGkLb6glHRxcRoRA2OmAzb1OvpHQXFKdec586UkaSmJan6JuNA

-- Dumped from database version 16.14
-- Dumped by pg_dump version 16.14

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: project1_uc; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA project1_uc;


--
-- Name: SCHEMA project1_uc; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA project1_uc IS 'UC-20261110-v1 review candidate; canonical M2 remains in public; no production adoption implied';


--
-- Name: _decision_core(uuid, uuid, text, text, uuid); Type: FUNCTION; Schema: project1_uc; Owner: -
--

CREATE FUNCTION project1_uc._decision_core(p_event uuid, p_version uuid, p_action text, p_receipt text, p_actor uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE
    v project1_uc.candidate_versions%ROWTYPE;
    c project1_uc.candidates%ROWTYPE;
    previous project1_uc.candidate_events%ROWTYPE;
    next_number integer;
    canonical uuid;
BEGIN
    IF p_actor IS NULL OR p_event IS NULL
       OR p_version IS NULL THEN
        RAISE EXCEPTION 'UC missing identity or request';
    END IF;

    SELECT * INTO v
    FROM project1_uc.candidate_versions
    WHERE id = p_version;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'UC version absent';
    END IF;

    SELECT * INTO c
    FROM project1_uc.candidates
    WHERE id = v.candidate_id
    FOR UPDATE;

    PERFORM 1
    FROM public.m2_assessments
    WHERE id = c.assessment_id
      AND owner_user_id = p_actor
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'UC entrepreneur is not assessment owner'
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO previous
    FROM project1_uc.candidate_events
    WHERE id = p_event;

    IF FOUND THEN
        IF previous.version_id <> p_version
           OR previous.action IS DISTINCT FROM p_action
           OR previous.action_receipt_ref IS DISTINCT FROM p_receipt
           OR previous.actor_user_id <> p_actor THEN
            RAISE EXCEPTION 'UC idempotency payload mismatch';
        END IF;

        RETURN previous.confirmed_uncertainty_id;
    END IF;

    IF p_action IS NULL OR p_action NOT IN (
        'CONFIRMED', 'REJECTED', 'DEFERRED', 'WITHDRAWN'
    ) THEN
        RAISE EXCEPTION 'UC invalid action';
    END IF;

    IF p_action <> 'WITHDRAWN' THEN
        PERFORM project1_uc.assert_current(p_version);
    END IF;

    SELECT coalesce(max(event_no), 0) + 1
    INTO next_number
    FROM project1_uc.candidate_events
    WHERE version_id = v.id;

    IF p_action = 'CONFIRMED' THEN
        canonical := p_event;

        INSERT INTO public.m2_confirmed_uncertainties (
            id, confirmation_id, actor_user_id,
            exact_text, created_at
        )
        VALUES (
            canonical, v.source_snapshot_id, p_actor,
            v.exact_text, clock_timestamp()
        );
    END IF;

    INSERT INTO project1_uc.candidate_events (
        id, version_id, event_no, action,
        actor_user_id, action_receipt_ref,
        confirmed_uncertainty_id, created_by_login
    )
    VALUES (
        p_event, v.id, next_number, p_action,
        p_actor, p_receipt, canonical, session_user
    );

    RETURN canonical;
END;
$$;


--
-- Name: append_candidate_version(uuid, uuid, uuid, uuid, text, text, text, uuid, uuid[], jsonb); Type: FUNCTION; Schema: project1_uc; Owner: -
--

CREATE FUNCTION project1_uc.append_candidate_version(p_candidate uuid, p_version uuid, p_assessment uuid, p_snapshot uuid, p_origin text, p_text text, p_rationale text, p_finding uuid, p_answers uuid[], p_model_provenance jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    SET "TimeZone" TO 'UTC'
    AS $_$
DECLARE actor uuid; c project1_uc.candidates%ROWTYPE; a public.m2_assessments%ROWTYPE;
 s public.m2_confirmation_snapshots%ROWTYPE; f public.m2_bdj_findings%ROWTYPE;
 ar public.m2_answer_revisions%ROWTYPE; answer_id uuid; n integer; k text;
BEGIN
 IF p_origin='ENTREPRENEUR' THEN actor:=project1_uc.require_principal('ENTREPRENEUR');
 ELSIF p_origin='LLM' THEN PERFORM project1_uc.require_principal('LLM_WRITER');
 ELSE RAISE EXCEPTION 'UC invalid origin'; END IF;
 -- All create/append paths take the assessment lock first, then candidate.
 SELECT * INTO a FROM public.m2_assessments WHERE id=p_assessment FOR SHARE;
 IF NOT FOUND OR (p_origin='ENTREPRENEUR' AND a.owner_user_id IS DISTINCT FROM actor) THEN
 RAISE EXCEPTION 'UC assessment denied' USING ERRCODE='42501'; END IF;
 IF p_origin='LLM' AND NOT EXISTS(SELECT FROM project1_uc.principal_assessment_scopes
 WHERE login_role=session_user AND assessment_id=p_assessment) THEN
 RAISE EXCEPTION 'UC LLM assessment scope denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO s FROM public.m2_confirmation_snapshots WHERE id=p_snapshot FOR SHARE;
 IF NOT FOUND OR s.assessment_id<>a.id OR s.actor_user_id<>a.owner_user_id OR
 a.confirmed_revision IS DISTINCT FROM a.revision OR s.assessment_revision<>a.revision THEN
 RAISE EXCEPTION 'UC requires current entrepreneur-confirmed M2 snapshot'; END IF;
 IF p_model_provenance IS NULL OR jsonb_typeof(p_model_provenance)<>'object' THEN RAISE EXCEPTION 'UC provenance object required'; END IF;
 IF p_origin='LLM' THEN
 FOREACH k IN ARRAY ARRAY['provider','model','model_version','prompt_version','generation_ref','output_sha256','validator_version'] LOOP
 IF jsonb_typeof(p_model_provenance->k) IS DISTINCT FROM 'string' OR length(btrim(p_model_provenance->>k))=0 THEN
 RAISE EXCEPTION 'UC missing model provenance %',k; END IF;
 END LOOP;
 IF (p_model_provenance->>'output_sha256') !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'UC invalid output hash'; END IF;
 IF coalesce(cardinality(p_answers),0)=0 THEN RAISE EXCEPTION 'UC LLM suggestion requires source answers'; END IF;
 ELSIF p_model_provenance<>'{}'::jsonb THEN RAISE EXCEPTION 'UC entrepreneur provenance must not impersonate a model'; END IF;
 IF p_answers IS NULL OR array_position(p_answers,NULL) IS NOT NULL OR
 cardinality(p_answers)<>(SELECT count(DISTINCT x) FROM unnest(p_answers) x) THEN
 RAISE EXCEPTION 'UC sources must be a distinct, non-null array'; END IF;
 IF p_finding IS NOT NULL THEN
 SELECT * INTO f FROM public.m2_bdj_findings WHERE id=p_finding FOR SHARE;
 IF NOT FOUND OR f.assessment_id<>a.id OR f.assessment_revision<>s.assessment_revision THEN
 RAISE EXCEPTION 'UC finding outside exact assessment revision'; END IF;
 END IF;
 INSERT INTO project1_uc.candidates(id,assessment_id,created_by_login)
 VALUES(p_candidate,p_assessment,session_user) ON CONFLICT(id) DO NOTHING;
 SELECT * INTO c FROM project1_uc.candidates WHERE id=p_candidate FOR UPDATE;
 IF c.assessment_id<>p_assessment THEN RAISE EXCEPTION 'UC cross-assessment candidate'; END IF;
 SELECT coalesce(max(version_no),0)+1 INTO n FROM project1_uc.candidate_versions WHERE candidate_id=c.id;
 INSERT INTO project1_uc.candidate_versions(id,candidate_id,version_no,origin,suggested_by_user_id,source_snapshot_id,source_snapshot_hash,
 finding_id,finding_hash,exact_text,rationale,model_provenance,created_by_login)
 VALUES(p_version,c.id,n,p_origin,actor,s.id,sha256(convert_to(to_jsonb(s)::text,'UTF8')),p_finding,
 CASE WHEN p_finding IS NOT NULL THEN sha256(convert_to(to_jsonb(f)::text,'UTF8')) END,p_text,p_rationale,p_model_provenance,session_user);
 FOREACH answer_id IN ARRAY p_answers LOOP
 SELECT * INTO ar FROM public.m2_answer_revisions WHERE id=answer_id FOR SHARE;
 IF NOT FOUND OR ar.assessment_id<>a.id OR ar.assessment_revision>s.assessment_revision THEN
 RAISE EXCEPTION 'UC answer outside source assessment/revision'; END IF;
 INSERT INTO project1_uc.version_sources VALUES(p_version,ar.id,sha256(convert_to(to_jsonb(ar)::text,'UTF8')));
 END LOOP;
 PERFORM project1_uc.assert_current(p_version);
 RETURN p_version;
END $_$;


--
-- Name: assert_current(uuid); Type: FUNCTION; Schema: project1_uc; Owner: -
--

CREATE FUNCTION project1_uc.assert_current(p_version uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    SET "TimeZone" TO 'UTC'
    AS $$
DECLARE v project1_uc.candidate_versions%ROWTYPE;
 c project1_uc.candidates%ROWTYPE; a public.m2_assessments%ROWTYPE;
 s public.m2_confirmation_snapshots%ROWTYPE; f public.m2_bdj_findings%ROWTYPE;
 r record; ar public.m2_answer_revisions%ROWTYPE;
BEGIN
 SELECT * INTO v FROM project1_uc.candidate_versions WHERE id=p_version;
 IF NOT FOUND THEN RAISE EXCEPTION 'UC version absent'; END IF;
 SELECT * INTO c FROM project1_uc.candidates WHERE id=v.candidate_id FOR UPDATE;
 IF v.version_no<>(SELECT max(version_no) FROM project1_uc.candidate_versions WHERE candidate_id=c.id) THEN
 RAISE EXCEPTION 'UC candidate version superseded'; END IF;
 SELECT * INTO a FROM public.m2_assessments WHERE id=c.assessment_id FOR SHARE;
 SELECT * INTO s FROM public.m2_confirmation_snapshots WHERE id=v.source_snapshot_id FOR SHARE;
 IF s.assessment_id<>a.id OR s.actor_user_id<>a.owner_user_id OR
 a.confirmed_revision IS DISTINCT FROM a.revision OR s.assessment_revision<>a.revision OR
 sha256(convert_to(to_jsonb(s)::text,'UTF8'))<>v.source_snapshot_hash THEN
 RAISE EXCEPTION 'UC M2 source stale or mismatched'; END IF;
 IF v.finding_id IS NOT NULL THEN
 SELECT * INTO f FROM public.m2_bdj_findings WHERE id=v.finding_id FOR SHARE;
 IF f.assessment_id<>a.id OR f.assessment_revision<>s.assessment_revision OR
 sha256(convert_to(to_jsonb(f)::text,'UTF8'))<>v.finding_hash THEN
 RAISE EXCEPTION 'UC finding stale or mismatched'; END IF;
 END IF;
 FOR r IN SELECT * FROM project1_uc.version_sources WHERE version_id=v.id ORDER BY answer_revision_id LOOP
 SELECT * INTO ar FROM public.m2_answer_revisions WHERE id=r.answer_revision_id FOR SHARE;
 IF ar.assessment_id<>a.id OR ar.assessment_revision>s.assessment_revision OR
 sha256(convert_to(to_jsonb(ar)::text,'UTF8'))<>r.answer_hash OR
 EXISTS(SELECT FROM public.m2_answer_revisions newer WHERE newer.assessment_id=a.id
 AND newer.item_version_id=ar.item_version_id AND newer.assessment_revision<=s.assessment_revision
 AND newer.assessment_revision>ar.assessment_revision) THEN
 RAISE EXCEPTION 'UC answer source stale or mismatched'; END IF;
 END LOOP;
END $$;


--
-- Name: confirmed_input(uuid); Type: FUNCTION; Schema: project1_uc; Owner: -
--

CREATE FUNCTION project1_uc.confirmed_input(p_event uuid) RETURNS TABLE(uncertainty_id uuid, candidate_version_id uuid, assessment_id uuid, source_snapshot_id uuid, exact_text text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE e project1_uc.candidate_events%ROWTYPE; v project1_uc.candidate_versions%ROWTYPE;
 u public.m2_confirmed_uncertainties%ROWTYPE; c project1_uc.candidates%ROWTYPE;
BEGIN
 SELECT * INTO e FROM project1_uc.candidate_events WHERE id=p_event;
 IF NOT FOUND OR e.action<>'CONFIRMED' THEN RAISE EXCEPTION 'UC explicit entrepreneur confirmation absent'; END IF;
 PERFORM project1_uc.assert_current(e.version_id);
 SELECT * INTO v FROM project1_uc.candidate_versions WHERE id=e.version_id;
 SELECT * INTO c FROM project1_uc.candidates WHERE id=v.candidate_id;
 IF NOT EXISTS(SELECT FROM project1_uc.principal_assessment_scopes
 WHERE login_role=session_user AND principal_assessment_scopes.assessment_id=c.assessment_id) THEN
 RAISE EXCEPTION 'UC QJ assessment scope denied' USING ERRCODE='42501'; END IF;
 IF e.event_no<>(SELECT max(event_no) FROM project1_uc.candidate_events WHERE version_id=e.version_id) THEN
 RAISE EXCEPTION 'UC confirmation superseded or withdrawn'; END IF;
 SELECT * INTO u FROM public.m2_confirmed_uncertainties WHERE id=e.confirmed_uncertainty_id FOR SHARE;
 IF NOT FOUND OR u.confirmation_id<>v.source_snapshot_id OR u.actor_user_id<>e.actor_user_id OR u.exact_text<>v.exact_text OR
 NOT EXISTS(SELECT FROM public.m2_assessments a WHERE a.id=c.assessment_id AND a.owner_user_id=e.actor_user_id) THEN
 RAISE EXCEPTION 'UC canonical confirmation changed or mismatched'; END IF;
 RETURN QUERY SELECT u.id,v.id,c.assessment_id,v.source_snapshot_id,u.exact_text;
END $$;


--
-- Name: deny_mutation(); Type: FUNCTION; Schema: project1_uc; Owner: -
--

CREATE FUNCTION project1_uc.deny_mutation() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog'
    AS $$
BEGIN RAISE EXCEPTION 'UC history is append-only; append a new version/event'; END $$;


--
-- Name: pin_qj_input(uuid, uuid); Type: FUNCTION; Schema: project1_uc; Owner: -
--

CREATE FUNCTION project1_uc.pin_qj_input(p_pin uuid, p_event uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE old project1_uc.qj_input_pins%ROWTYPE;
BEGIN
 PERFORM project1_uc.require_principal('QJ_READER');
 PERFORM * FROM project1_uc.confirmed_input(p_event);
 SELECT * INTO old FROM project1_uc.qj_input_pins WHERE id=p_pin;
 IF FOUND THEN
 IF old.confirmation_event_id<>p_event OR old.created_by_login<>session_user THEN RAISE EXCEPTION 'UC pin idempotency mismatch'; END IF;
 RETURN old.id; END IF;
 INSERT INTO project1_uc.qj_input_pins VALUES(p_pin,p_event,session_user,clock_timestamp());
 RETURN p_pin;
END $$;


--
-- Name: read_qj_input(uuid); Type: FUNCTION; Schema: project1_uc; Owner: -
--

CREATE FUNCTION project1_uc.read_qj_input(p_pin uuid) RETURNS TABLE(uncertainty_id uuid, candidate_version_id uuid, assessment_id uuid, source_snapshot_id uuid, exact_text text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE pin project1_uc.qj_input_pins%ROWTYPE;
BEGIN
 PERFORM project1_uc.require_principal('QJ_READER');
 SELECT * INTO pin FROM project1_uc.qj_input_pins WHERE id=p_pin;
 IF NOT FOUND OR pin.created_by_login<>session_user THEN RAISE EXCEPTION 'UC pin denied' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT * FROM project1_uc.confirmed_input(pin.confirmation_event_id);
END $$;


--
-- Name: record_authenticated_entrepreneur_decision(uuid, uuid, uuid, text, text); Type: FUNCTION; Schema: project1_uc; Owner: -
--

CREATE FUNCTION project1_uc.record_authenticated_entrepreneur_decision(p_actor uuid, p_event uuid, p_version uuid, p_action text, p_receipt text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
BEGIN
    IF session_user <> 'p1uc_stage_human' THEN
        RAISE EXCEPTION 'UC human gateway role denied'
            USING ERRCODE = '42501';
    END IF;

    RETURN project1_uc._decision_core(
        p_event, p_version, p_action, p_receipt, p_actor
    );
END;
$$;


--
-- Name: record_entrepreneur_decision(uuid, uuid, text, text); Type: FUNCTION; Schema: project1_uc; Owner: -
--

CREATE FUNCTION project1_uc.record_entrepreneur_decision(p_event uuid, p_version uuid, p_action text, p_receipt text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
BEGIN
    RETURN project1_uc._decision_core(
        p_event,
        p_version,
        p_action,
        p_receipt,
        project1_uc.require_principal('ENTREPRENEUR')
    );
END;
$$;


--
-- Name: require_principal(text); Type: FUNCTION; Schema: project1_uc; Owner: -
--

CREATE FUNCTION project1_uc.require_principal(p_kind text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE p project1_uc.principal_bindings%ROWTYPE;
BEGIN
 IF current_setting('transaction_isolation')<>'read committed' THEN
 RAISE EXCEPTION 'UC requires READ COMMITTED for fresh boundary checks'; END IF;
 SELECT * INTO p FROM project1_uc.principal_bindings WHERE login_role=session_user AND enabled;
 IF NOT FOUND OR p.principal_kind<>p_kind THEN RAISE EXCEPTION 'UC principal denied' USING ERRCODE='42501'; END IF;
 RETURN p.actor_user_id;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: candidate_events; Type: TABLE; Schema: project1_uc; Owner: -
--

CREATE TABLE project1_uc.candidate_events (
    id uuid NOT NULL,
    version_id uuid NOT NULL,
    event_no integer NOT NULL,
    action text NOT NULL,
    actor_user_id uuid NOT NULL,
    action_receipt_ref text NOT NULL,
    confirmed_uncertainty_id uuid,
    created_by_login name NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT candidate_events_action_check CHECK ((action = ANY (ARRAY['CONFIRMED'::text, 'REJECTED'::text, 'DEFERRED'::text, 'WITHDRAWN'::text]))),
    CONSTRAINT candidate_events_action_receipt_ref_check CHECK (((length(btrim(action_receipt_ref)) >= 1) AND (length(btrim(action_receipt_ref)) <= 2000))),
    CONSTRAINT candidate_events_check CHECK (((action = 'CONFIRMED'::text) = (confirmed_uncertainty_id IS NOT NULL))),
    CONSTRAINT candidate_events_event_no_check CHECK ((event_no > 0))
);


--
-- Name: candidate_versions; Type: TABLE; Schema: project1_uc; Owner: -
--

CREATE TABLE project1_uc.candidate_versions (
    id uuid NOT NULL,
    candidate_id uuid NOT NULL,
    version_no integer NOT NULL,
    origin text NOT NULL,
    suggested_by_user_id uuid,
    source_snapshot_id uuid NOT NULL,
    source_snapshot_hash bytea NOT NULL,
    finding_id uuid,
    finding_hash bytea,
    exact_text text NOT NULL,
    rationale text NOT NULL,
    model_provenance jsonb NOT NULL,
    created_by_login name NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT candidate_versions_check CHECK (((origin = 'ENTREPRENEUR'::text) = (suggested_by_user_id IS NOT NULL))),
    CONSTRAINT candidate_versions_check1 CHECK (((finding_id IS NULL) = (finding_hash IS NULL))),
    CONSTRAINT candidate_versions_exact_text_check CHECK ((((length(btrim(exact_text)) >= 1) AND (length(btrim(exact_text)) <= 16000)) AND (octet_length(exact_text) <= 64000))),
    CONSTRAINT candidate_versions_finding_hash_check CHECK (((finding_hash IS NULL) OR (octet_length(finding_hash) = 32))),
    CONSTRAINT candidate_versions_model_provenance_check CHECK (((jsonb_typeof(model_provenance) = 'object'::text) AND (octet_length((model_provenance)::text) <= 16000))),
    CONSTRAINT candidate_versions_origin_check CHECK ((origin = ANY (ARRAY['LLM'::text, 'ENTREPRENEUR'::text]))),
    CONSTRAINT candidate_versions_rationale_check CHECK ((((length(btrim(rationale)) >= 1) AND (length(btrim(rationale)) <= 16000)) AND (octet_length(rationale) <= 64000))),
    CONSTRAINT candidate_versions_source_snapshot_hash_check CHECK ((octet_length(source_snapshot_hash) = 32)),
    CONSTRAINT candidate_versions_version_no_check CHECK ((version_no > 0))
);


--
-- Name: candidates; Type: TABLE; Schema: project1_uc; Owner: -
--

CREATE TABLE project1_uc.candidates (
    id uuid NOT NULL,
    assessment_id uuid NOT NULL,
    created_by_login name NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL
);


--
-- Name: principal_assessment_scopes; Type: TABLE; Schema: project1_uc; Owner: -
--

CREATE TABLE project1_uc.principal_assessment_scopes (
    login_role name NOT NULL,
    assessment_id uuid NOT NULL
);


--
-- Name: principal_bindings; Type: TABLE; Schema: project1_uc; Owner: -
--

CREATE TABLE project1_uc.principal_bindings (
    login_role name NOT NULL,
    principal_kind text NOT NULL,
    actor_user_id uuid,
    enabled boolean DEFAULT false NOT NULL,
    CONSTRAINT principal_bindings_check CHECK (((principal_kind = 'ENTREPRENEUR'::text) = (actor_user_id IS NOT NULL))),
    CONSTRAINT principal_bindings_principal_kind_check CHECK ((principal_kind = ANY (ARRAY['ENTREPRENEUR'::text, 'LLM_WRITER'::text, 'QJ_READER'::text])))
);


--
-- Name: qj_input_pins; Type: TABLE; Schema: project1_uc; Owner: -
--

CREATE TABLE project1_uc.qj_input_pins (
    id uuid NOT NULL,
    confirmation_event_id uuid NOT NULL,
    created_by_login name NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL
);


--
-- Name: version_sources; Type: TABLE; Schema: project1_uc; Owner: -
--

CREATE TABLE project1_uc.version_sources (
    version_id uuid NOT NULL,
    answer_revision_id uuid NOT NULL,
    answer_hash bytea NOT NULL,
    CONSTRAINT version_sources_answer_hash_check CHECK ((octet_length(answer_hash) = 32))
);


--
-- Name: candidate_events candidate_events_confirmed_uncertainty_id_key; Type: CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.candidate_events
    ADD CONSTRAINT candidate_events_confirmed_uncertainty_id_key UNIQUE (confirmed_uncertainty_id);


--
-- Name: candidate_events candidate_events_pkey; Type: CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.candidate_events
    ADD CONSTRAINT candidate_events_pkey PRIMARY KEY (id);


--
-- Name: candidate_events candidate_events_version_id_event_no_key; Type: CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.candidate_events
    ADD CONSTRAINT candidate_events_version_id_event_no_key UNIQUE (version_id, event_no);


--
-- Name: candidate_versions candidate_versions_candidate_id_version_no_key; Type: CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.candidate_versions
    ADD CONSTRAINT candidate_versions_candidate_id_version_no_key UNIQUE (candidate_id, version_no);


--
-- Name: candidate_versions candidate_versions_pkey; Type: CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.candidate_versions
    ADD CONSTRAINT candidate_versions_pkey PRIMARY KEY (id);


--
-- Name: candidates candidates_pkey; Type: CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.candidates
    ADD CONSTRAINT candidates_pkey PRIMARY KEY (id);


--
-- Name: principal_assessment_scopes principal_assessment_scopes_pkey; Type: CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.principal_assessment_scopes
    ADD CONSTRAINT principal_assessment_scopes_pkey PRIMARY KEY (login_role, assessment_id);


--
-- Name: principal_bindings principal_bindings_pkey; Type: CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.principal_bindings
    ADD CONSTRAINT principal_bindings_pkey PRIMARY KEY (login_role);


--
-- Name: qj_input_pins qj_input_pins_pkey; Type: CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.qj_input_pins
    ADD CONSTRAINT qj_input_pins_pkey PRIMARY KEY (id);


--
-- Name: version_sources version_sources_pkey; Type: CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.version_sources
    ADD CONSTRAINT version_sources_pkey PRIMARY KEY (version_id, answer_revision_id);


--
-- Name: candidates_assessment_idx; Type: INDEX; Schema: project1_uc; Owner: -
--

CREATE INDEX candidates_assessment_idx ON project1_uc.candidates USING btree (assessment_id);


--
-- Name: pins_event_idx; Type: INDEX; Schema: project1_uc; Owner: -
--

CREATE INDEX pins_event_idx ON project1_uc.qj_input_pins USING btree (confirmation_event_id);


--
-- Name: sources_answer_idx; Type: INDEX; Schema: project1_uc; Owner: -
--

CREATE INDEX sources_answer_idx ON project1_uc.version_sources USING btree (answer_revision_id);


--
-- Name: versions_finding_idx; Type: INDEX; Schema: project1_uc; Owner: -
--

CREATE INDEX versions_finding_idx ON project1_uc.candidate_versions USING btree (finding_id);


--
-- Name: versions_snapshot_idx; Type: INDEX; Schema: project1_uc; Owner: -
--

CREATE INDEX versions_snapshot_idx ON project1_uc.candidate_versions USING btree (source_snapshot_id);


--
-- Name: candidate_events uc_no_mutation; Type: TRIGGER; Schema: project1_uc; Owner: -
--

CREATE TRIGGER uc_no_mutation BEFORE DELETE OR UPDATE OR TRUNCATE ON project1_uc.candidate_events FOR EACH STATEMENT EXECUTE FUNCTION project1_uc.deny_mutation();


--
-- Name: candidate_versions uc_no_mutation; Type: TRIGGER; Schema: project1_uc; Owner: -
--

CREATE TRIGGER uc_no_mutation BEFORE DELETE OR UPDATE OR TRUNCATE ON project1_uc.candidate_versions FOR EACH STATEMENT EXECUTE FUNCTION project1_uc.deny_mutation();


--
-- Name: candidates uc_no_mutation; Type: TRIGGER; Schema: project1_uc; Owner: -
--

CREATE TRIGGER uc_no_mutation BEFORE DELETE OR UPDATE OR TRUNCATE ON project1_uc.candidates FOR EACH STATEMENT EXECUTE FUNCTION project1_uc.deny_mutation();


--
-- Name: qj_input_pins uc_no_mutation; Type: TRIGGER; Schema: project1_uc; Owner: -
--

CREATE TRIGGER uc_no_mutation BEFORE DELETE OR UPDATE OR TRUNCATE ON project1_uc.qj_input_pins FOR EACH STATEMENT EXECUTE FUNCTION project1_uc.deny_mutation();


--
-- Name: version_sources uc_no_mutation; Type: TRIGGER; Schema: project1_uc; Owner: -
--

CREATE TRIGGER uc_no_mutation BEFORE DELETE OR UPDATE OR TRUNCATE ON project1_uc.version_sources FOR EACH STATEMENT EXECUTE FUNCTION project1_uc.deny_mutation();


--
-- Name: candidate_events candidate_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.candidate_events
    ADD CONSTRAINT candidate_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(user_id) ON DELETE RESTRICT;


--
-- Name: candidate_events candidate_events_confirmed_uncertainty_id_fkey; Type: FK CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.candidate_events
    ADD CONSTRAINT candidate_events_confirmed_uncertainty_id_fkey FOREIGN KEY (confirmed_uncertainty_id) REFERENCES public.m2_confirmed_uncertainties(id) ON DELETE RESTRICT;


--
-- Name: candidate_events candidate_events_version_id_fkey; Type: FK CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.candidate_events
    ADD CONSTRAINT candidate_events_version_id_fkey FOREIGN KEY (version_id) REFERENCES project1_uc.candidate_versions(id) ON DELETE RESTRICT;


--
-- Name: candidate_versions candidate_versions_candidate_id_fkey; Type: FK CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.candidate_versions
    ADD CONSTRAINT candidate_versions_candidate_id_fkey FOREIGN KEY (candidate_id) REFERENCES project1_uc.candidates(id) ON DELETE RESTRICT;


--
-- Name: candidate_versions candidate_versions_finding_id_fkey; Type: FK CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.candidate_versions
    ADD CONSTRAINT candidate_versions_finding_id_fkey FOREIGN KEY (finding_id) REFERENCES public.m2_bdj_findings(id) ON DELETE RESTRICT;


--
-- Name: candidate_versions candidate_versions_source_snapshot_id_fkey; Type: FK CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.candidate_versions
    ADD CONSTRAINT candidate_versions_source_snapshot_id_fkey FOREIGN KEY (source_snapshot_id) REFERENCES public.m2_confirmation_snapshots(id) ON DELETE RESTRICT;


--
-- Name: candidate_versions candidate_versions_suggested_by_user_id_fkey; Type: FK CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.candidate_versions
    ADD CONSTRAINT candidate_versions_suggested_by_user_id_fkey FOREIGN KEY (suggested_by_user_id) REFERENCES public.users(user_id) ON DELETE RESTRICT;


--
-- Name: candidates candidates_assessment_id_fkey; Type: FK CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.candidates
    ADD CONSTRAINT candidates_assessment_id_fkey FOREIGN KEY (assessment_id) REFERENCES public.m2_assessments(id) ON DELETE RESTRICT;


--
-- Name: principal_assessment_scopes principal_assessment_scopes_assessment_id_fkey; Type: FK CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.principal_assessment_scopes
    ADD CONSTRAINT principal_assessment_scopes_assessment_id_fkey FOREIGN KEY (assessment_id) REFERENCES public.m2_assessments(id) ON DELETE RESTRICT;


--
-- Name: principal_assessment_scopes principal_assessment_scopes_login_role_fkey; Type: FK CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.principal_assessment_scopes
    ADD CONSTRAINT principal_assessment_scopes_login_role_fkey FOREIGN KEY (login_role) REFERENCES project1_uc.principal_bindings(login_role) ON DELETE RESTRICT;


--
-- Name: principal_bindings principal_bindings_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.principal_bindings
    ADD CONSTRAINT principal_bindings_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(user_id) ON DELETE RESTRICT;


--
-- Name: qj_input_pins qj_input_pins_confirmation_event_id_fkey; Type: FK CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.qj_input_pins
    ADD CONSTRAINT qj_input_pins_confirmation_event_id_fkey FOREIGN KEY (confirmation_event_id) REFERENCES project1_uc.candidate_events(id) ON DELETE RESTRICT;


--
-- Name: version_sources version_sources_answer_revision_id_fkey; Type: FK CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.version_sources
    ADD CONSTRAINT version_sources_answer_revision_id_fkey FOREIGN KEY (answer_revision_id) REFERENCES public.m2_answer_revisions(id) ON DELETE RESTRICT;


--
-- Name: version_sources version_sources_version_id_fkey; Type: FK CONSTRAINT; Schema: project1_uc; Owner: -
--

ALTER TABLE ONLY project1_uc.version_sources
    ADD CONSTRAINT version_sources_version_id_fkey FOREIGN KEY (version_id) REFERENCES project1_uc.candidate_versions(id) ON DELETE RESTRICT;


--
-- Name: candidate_events; Type: ROW SECURITY; Schema: project1_uc; Owner: -
--

ALTER TABLE project1_uc.candidate_events ENABLE ROW LEVEL SECURITY;

--
-- Name: candidate_versions; Type: ROW SECURITY; Schema: project1_uc; Owner: -
--

ALTER TABLE project1_uc.candidate_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: candidates; Type: ROW SECURITY; Schema: project1_uc; Owner: -
--

ALTER TABLE project1_uc.candidates ENABLE ROW LEVEL SECURITY;

--
-- Name: principal_assessment_scopes; Type: ROW SECURITY; Schema: project1_uc; Owner: -
--

ALTER TABLE project1_uc.principal_assessment_scopes ENABLE ROW LEVEL SECURITY;

--
-- Name: principal_bindings; Type: ROW SECURITY; Schema: project1_uc; Owner: -
--

ALTER TABLE project1_uc.principal_bindings ENABLE ROW LEVEL SECURITY;

--
-- Name: qj_input_pins; Type: ROW SECURITY; Schema: project1_uc; Owner: -
--

ALTER TABLE project1_uc.qj_input_pins ENABLE ROW LEVEL SECURITY;

--
-- Name: version_sources; Type: ROW SECURITY; Schema: project1_uc; Owner: -
--

ALTER TABLE project1_uc.version_sources ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA project1_uc; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA project1_uc TO p1uc_stage_human;
GRANT USAGE ON SCHEMA project1_uc TO p1uc_stage_llm;
GRANT USAGE ON SCHEMA project1_uc TO p1uc_stage_qj;


--
-- Name: FUNCTION _decision_core(p_event uuid, p_version uuid, p_action text, p_receipt text, p_actor uuid); Type: ACL; Schema: project1_uc; Owner: -
--

REVOKE ALL ON FUNCTION project1_uc._decision_core(p_event uuid, p_version uuid, p_action text, p_receipt text, p_actor uuid) FROM PUBLIC;


--
-- Name: FUNCTION append_candidate_version(p_candidate uuid, p_version uuid, p_assessment uuid, p_snapshot uuid, p_origin text, p_text text, p_rationale text, p_finding uuid, p_answers uuid[], p_model_provenance jsonb); Type: ACL; Schema: project1_uc; Owner: -
--

REVOKE ALL ON FUNCTION project1_uc.append_candidate_version(p_candidate uuid, p_version uuid, p_assessment uuid, p_snapshot uuid, p_origin text, p_text text, p_rationale text, p_finding uuid, p_answers uuid[], p_model_provenance jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION project1_uc.append_candidate_version(p_candidate uuid, p_version uuid, p_assessment uuid, p_snapshot uuid, p_origin text, p_text text, p_rationale text, p_finding uuid, p_answers uuid[], p_model_provenance jsonb) TO p1uc_stage_llm;


--
-- Name: FUNCTION assert_current(p_version uuid); Type: ACL; Schema: project1_uc; Owner: -
--

REVOKE ALL ON FUNCTION project1_uc.assert_current(p_version uuid) FROM PUBLIC;


--
-- Name: FUNCTION confirmed_input(p_event uuid); Type: ACL; Schema: project1_uc; Owner: -
--

REVOKE ALL ON FUNCTION project1_uc.confirmed_input(p_event uuid) FROM PUBLIC;


--
-- Name: FUNCTION deny_mutation(); Type: ACL; Schema: project1_uc; Owner: -
--

REVOKE ALL ON FUNCTION project1_uc.deny_mutation() FROM PUBLIC;


--
-- Name: FUNCTION pin_qj_input(p_pin uuid, p_event uuid); Type: ACL; Schema: project1_uc; Owner: -
--

REVOKE ALL ON FUNCTION project1_uc.pin_qj_input(p_pin uuid, p_event uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION project1_uc.pin_qj_input(p_pin uuid, p_event uuid) TO p1uc_stage_qj;


--
-- Name: FUNCTION read_qj_input(p_pin uuid); Type: ACL; Schema: project1_uc; Owner: -
--

REVOKE ALL ON FUNCTION project1_uc.read_qj_input(p_pin uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION project1_uc.read_qj_input(p_pin uuid) TO p1uc_stage_qj;


--
-- Name: FUNCTION record_authenticated_entrepreneur_decision(p_actor uuid, p_event uuid, p_version uuid, p_action text, p_receipt text); Type: ACL; Schema: project1_uc; Owner: -
--

REVOKE ALL ON FUNCTION project1_uc.record_authenticated_entrepreneur_decision(p_actor uuid, p_event uuid, p_version uuid, p_action text, p_receipt text) FROM PUBLIC;
GRANT ALL ON FUNCTION project1_uc.record_authenticated_entrepreneur_decision(p_actor uuid, p_event uuid, p_version uuid, p_action text, p_receipt text) TO p1uc_stage_human;


--
-- Name: FUNCTION record_entrepreneur_decision(p_event uuid, p_version uuid, p_action text, p_receipt text); Type: ACL; Schema: project1_uc; Owner: -
--

REVOKE ALL ON FUNCTION project1_uc.record_entrepreneur_decision(p_event uuid, p_version uuid, p_action text, p_receipt text) FROM PUBLIC;


--
-- Name: FUNCTION require_principal(p_kind text); Type: ACL; Schema: project1_uc; Owner: -
--

REVOKE ALL ON FUNCTION project1_uc.require_principal(p_kind text) FROM PUBLIC;


--
-- PostgreSQL database dump complete
--

\unrestrict SNb0dQS0NSfgLGGkLb6glHRxcRoRA2OmAzb1OvpHQXFKdec586UkaSmJan6JuNA

