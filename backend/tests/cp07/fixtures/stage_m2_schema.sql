--
-- PostgreSQL database dump
--

\restrict q9zyt3Gdu6XfsFu2nmhsuiMHibspifNnIiPRPJDz4fju5KPphoJ3wB5XiFDVBM4

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

SET default_tablespace = '';

SET default_table_access_method = heap;

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
-- Name: m2_answer_revisions m2_answer_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_answer_revisions
    ADD CONSTRAINT m2_answer_revisions_pkey PRIMARY KEY (id);


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
-- Name: m2_review_events m2_review_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_review_events
    ADD CONSTRAINT m2_review_events_pkey PRIMARY KEY (id);


--
-- Name: m2_answer_revisions uq_m2_answer_revision; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_answer_revisions
    ADD CONSTRAINT uq_m2_answer_revision UNIQUE (assessment_id, item_version_id, assessment_revision);


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
-- Name: m2_confirmation_snapshots uq_m2_confirmation_revision; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_confirmation_snapshots
    ADD CONSTRAINT uq_m2_confirmation_revision UNIQUE (assessment_id, assessment_revision);


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
-- Name: ix_m2_review_events_assessment_revision; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_m2_review_events_assessment_revision ON public.m2_review_events USING btree (assessment_id, assessment_revision);


--
-- Name: ix_m2_uncertainties_confirmation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_m2_uncertainties_confirmation_id ON public.m2_confirmed_uncertainties USING btree (confirmation_id);


--
-- Name: m2_confirmation_snapshots fk_m2_confirmation_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_confirmation_snapshots
    ADD CONSTRAINT fk_m2_confirmation_actor FOREIGN KEY (actor_user_id) REFERENCES public.users(user_id) ON DELETE RESTRICT;


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
-- Name: m2_item_versions m2_item_versions_instrument_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_item_versions
    ADD CONSTRAINT m2_item_versions_instrument_id_fkey FOREIGN KEY (instrument_id) REFERENCES public.m2_instrument_versions(id);


--
-- Name: m2_review_events m2_review_events_assessment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.m2_review_events
    ADD CONSTRAINT m2_review_events_assessment_id_fkey FOREIGN KEY (assessment_id) REFERENCES public.m2_assessments(id);


--
-- Name: m2_answer_revisions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_answer_revisions ENABLE ROW LEVEL SECURITY;

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
-- Name: m2_confirmation_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_confirmation_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_confirmed_uncertainties; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_confirmed_uncertainties ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_instrument_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_instrument_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_item_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_item_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: m2_review_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.m2_review_events ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

\unrestrict q9zyt3Gdu6XfsFu2nmhsuiMHibspifNnIiPRPJDz4fju5KPphoJ3wB5XiFDVBM4

