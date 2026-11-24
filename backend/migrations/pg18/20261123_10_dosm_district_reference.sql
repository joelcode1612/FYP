-- =====================================================================
-- 20261123_10_dosm_district_reference.sql
-- =====================================================================
-- Purpose
--   Restore the three official DOSM district reference tables the assessment
--   payload resolves through ``CatalogRepository.get_evidence``:
--
--     public.district_population      175 rows
--     public.district_age_population  3,150 rows
--     public.hh_income_district        74 rows
--
--   Why it is required (measured, not assumed): creating an assessment calls
--
--     POST /api/v1/assessments/            assessments.py:67
--       -> AssessmentService.payload       assessment_service.py:840
--         -> CatalogRepository.get_evidence catalog_repository.py:477
--           -> _dosm_district_keys         catalog_repository.py:525
--             -> _POPULATION_SQL / _DISTRICT_NAME_SQL / _DISTRICT_PAIR_SQL
--
--   and without these tables the whole request fails with
--     psycopg2.errors.UndefinedTable: relation "public.district_population"
--     does not exist
--   i.e. HTTP 500 on assessment creation — not merely a missing detail panel.
--
--   These are aggregate government statistics published by DOSM. They contain
--   no property record and no personal data, so the approved "8 properties"
--   scope limit does not apply: the full reference set is restored because a
--   partial district table would report wrong demographics for a district it
--   only half covers.
--
-- Provenance
--   pg_dump -h 127.0.0.1 -p 5432 -U postgres -d Final_Location_Analysis \
--           --schema-only --no-owner --no-privileges \
--           -t public.district_population \
--           -t public.district_age_population \
--           -t public.hh_income_district
--
-- Safety
--   Only a ``project1_pg18_%`` database on port 5544 may run this file.
-- =====================================================================

DO $$
DECLARE
    db   text := current_database();
    port int  := inet_server_port();
BEGIN
    IF db NOT LIKE 'project1\_pg18\_%' THEN
        RAISE EXCEPTION 'REFUSED: % is not a project1_pg18_* database', db;
    END IF;
    IF port <> 5544 THEN
        RAISE EXCEPTION 'REFUSED: port % is not the isolated PG18 cluster (5544)', port;
    END IF;
    IF to_regclass('public.district_population') IS NOT NULL
       OR to_regclass('public.district_age_population') IS NOT NULL
       OR to_regclass('public.hh_income_district') IS NOT NULL THEN
        RAISE EXCEPTION 'REFUSED: a DOSM reference table already exists';
    END IF;
    RAISE NOTICE 'DOSM reference restore accepted: % on port %', db, port;
END
$$;

--
-- PostgreSQL database dump
--

\restrict XOP3AfqYXShTMe40jNJeMWHJzcdhc9KMYTTLQDsw3TKqEflhQ4FkUuSt7HKYCDE

-- Dumped from database version 16.14
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

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: district_age_population; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.district_age_population (
    state character varying(100) NOT NULL,
    district character varying(150) NOT NULL,
    date date NOT NULL,
    age character varying(30) NOT NULL,
    population_persons bigint NOT NULL,
    CONSTRAINT district_age_population_pop_check CHECK ((population_persons >= 0))
);


--
-- Name: TABLE district_age_population; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.district_age_population IS 'DOSM population by district x age group; unit: persons; source age labels preserved';


--
-- Name: district_population; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.district_population (
    state character varying(100) NOT NULL,
    district character varying(150) NOT NULL,
    date date NOT NULL,
    population_persons bigint NOT NULL,
    CONSTRAINT district_population_pop_check CHECK ((population_persons >= 0))
);


--
-- Name: TABLE district_population; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.district_population IS 'DOSM population by district, study states, 2020-2026; unit: persons';


--
-- Name: COLUMN district_population.population_persons; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.district_population.population_persons IS 'persons (converted from thousands at source load; import as-is)';


--
-- Name: hh_income_district; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hh_income_district (
    state character varying(100),
    district character varying(150),
    date date,
    income_mean numeric(12,2),
    income_median numeric(12,2),
    expenditure_mean numeric(12,2),
    gini numeric(6,4),
    poverty numeric(6,3),
    CONSTRAINT hh_income_district_expenditure_check CHECK (((expenditure_mean IS NULL) OR (expenditure_mean >= (0)::numeric))),
    CONSTRAINT hh_income_district_gini_check CHECK (((gini IS NULL) OR ((gini >= (0)::numeric) AND (gini <= (1)::numeric)))),
    CONSTRAINT hh_income_district_income_mean_check CHECK (((income_mean IS NULL) OR (income_mean >= (0)::numeric))),
    CONSTRAINT hh_income_district_income_median_check CHECK (((income_median IS NULL) OR (income_median >= (0)::numeric))),
    CONSTRAINT hh_income_district_poverty_check CHECK (((poverty IS NULL) OR ((poverty >= (0)::numeric) AND (poverty <= (100)::numeric))))
);


--
-- Name: TABLE hh_income_district; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.hh_income_district IS 'DOSM household income by district (RM/month) enriched with HIES expenditure/gini/poverty';


--
-- Name: COLUMN hh_income_district.expenditure_mean; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.hh_income_district.expenditure_mean IS 'mean monthly household expenditure, RM/month (HIES 2022/2024)';


--
-- Name: COLUMN hh_income_district.gini; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.hh_income_district.gini IS 'Gini coefficient, ratio 0-1 (HIES)';


--
-- Name: COLUMN hh_income_district.poverty; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.hh_income_district.poverty IS 'absolute poverty rate, percent 0-100 (HIES)';


--
-- Name: district_age_population district_age_population_nk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.district_age_population
    ADD CONSTRAINT district_age_population_nk UNIQUE (state, district, date, age);


--
-- Name: district_population district_population_nk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.district_population
    ADD CONSTRAINT district_population_nk UNIQUE (state, district, date);


--
-- Name: hh_income_district hh_income_district_nk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hh_income_district
    ADD CONSTRAINT hh_income_district_nk UNIQUE (state, district, date);


--
-- Name: district_age_population cp12_barrier; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON public.district_age_population FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: district_population cp12_barrier; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON public.district_population FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: hh_income_district cp12_barrier; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON public.hh_income_district FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- PostgreSQL database dump complete
--

\unrestrict XOP3AfqYXShTMe40jNJeMWHJzcdhc9KMYTTLQDsw3TKqEflhQ4FkUuSt7HKYCDE

