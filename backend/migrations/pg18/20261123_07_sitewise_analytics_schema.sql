-- =====================================================================
-- 20261123_07_sitewise_analytics_schema.sql
-- =====================================================================
-- Purpose
--   Restore ``sitewise_analytics`` (subject_features + transit_stop_
--   reconciliation) into the isolated PG18 E2E cluster.
--
--   Why it is required: the recommendation search ranks with the live
--   expanded64 model, whose feature loader reads
--   ``sitewise_analytics.subject_features``. Without the table every
--   ``GET /api/v1/recommendations/facets`` and
--   ``POST /api/v1/recommendations/search`` call fails with
--   ``UndefinedTable``, which the UI reports as "Filter choices could not be
--   updated".
--
-- Provenance
--   pg_dump -h 127.0.0.1 -p 5432 -U postgres -d Final_Location_Analysis \
--           --schema-only --no-owner --no-privileges \
--           --schema=sitewise_analytics
--   No extension and no geometry column in the dump.
--
-- Safety
--   Same guard discipline as migrations/pg18/*: only a ``project1_pg18_%``
--   database on port 5544 may run this file.
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
    IF to_regclass('sitewise_analytics.subject_features') IS NOT NULL THEN
        RAISE EXCEPTION 'REFUSED: sitewise_analytics.subject_features already exists';
    END IF;
    RAISE NOTICE 'sitewise_analytics restore accepted: % on port %', db, port;
END
$$;

--
-- PostgreSQL database dump
--

\restrict kAy41iAaLhxh48H0qzQkYcHTyHpWSegUgbmPued81TJcTb41T3a6K2Usrq0JXpV

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

--
-- Name: sitewise_analytics; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA sitewise_analytics;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: subject_features; Type: TABLE; Schema: sitewise_analytics; Owner: -
--

CREATE TABLE sitewise_analytics.subject_features (
    subject_id text NOT NULL,
    sample_class character(1) NOT NULL,
    canonical_property_id text,
    competitor_count_500m integer,
    competitor_count_1000m integer,
    cafe_count_500m integer,
    restaurant_count_500m integer,
    fast_food_count_500m integer,
    nearest_competitor_distance_m numeric,
    bus_stops_500m_walk integer,
    rail_stations_1km_walk integer,
    nearest_transit_walk_m numeric,
    nearest_major_road_m numeric,
    road_length_density_500m_km_km2 numeric,
    building_footprint_density_500m numeric,
    building_count_500m integer,
    parking_facilities_500m integer,
    nearest_parking_distance_m numeric,
    district_income_median_myr numeric,
    analysis_status text,
    parking_status text,
    reference_coverage text,
    self_exclusion_status text,
    feature_snapshot_at date,
    inventory_snapshot_at timestamp with time zone,
    source_file text NOT NULL,
    other_features jsonb DEFAULT '{}'::jsonb NOT NULL,
    imported_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT subject_features_sample_class_check CHECK ((sample_class = ANY (ARRAY['P'::bpchar, 'U'::bpchar])))
);


--
-- Name: transit_stop_reconciliation; Type: TABLE; Schema: sitewise_analytics; Owner: -
--

CREATE TABLE sitewise_analytics.transit_stop_reconciliation (
    canonical_identity text NOT NULL,
    feed text,
    gtfs_stop_id text,
    gtfs_name text,
    gtfs_lon double precision,
    gtfs_lat double precision,
    osm_stop_uid text,
    osm_mode text,
    osm_name text,
    match_distance_m numeric,
    match_class text,
    source_file text NOT NULL,
    imported_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: subject_features subject_features_pkey; Type: CONSTRAINT; Schema: sitewise_analytics; Owner: -
--

ALTER TABLE ONLY sitewise_analytics.subject_features
    ADD CONSTRAINT subject_features_pkey PRIMARY KEY (subject_id);


--
-- Name: transit_stop_reconciliation transit_stop_reconciliation_pkey; Type: CONSTRAINT; Schema: sitewise_analytics; Owner: -
--

ALTER TABLE ONLY sitewise_analytics.transit_stop_reconciliation
    ADD CONSTRAINT transit_stop_reconciliation_pkey PRIMARY KEY (canonical_identity);


--
-- Name: ix_sw_subject_features_competition; Type: INDEX; Schema: sitewise_analytics; Owner: -
--

CREATE INDEX ix_sw_subject_features_competition ON sitewise_analytics.subject_features USING btree (competitor_count_500m);


--
-- Name: ix_sw_subject_features_kind; Type: INDEX; Schema: sitewise_analytics; Owner: -
--

CREATE INDEX ix_sw_subject_features_kind ON sitewise_analytics.subject_features USING btree (sample_class, canonical_property_id);


--
-- Name: subject_features cp12_barrier; Type: TRIGGER; Schema: sitewise_analytics; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON sitewise_analytics.subject_features FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: transit_stop_reconciliation cp12_barrier; Type: TRIGGER; Schema: sitewise_analytics; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON sitewise_analytics.transit_stop_reconciliation FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: subject_features subject_features_subject_id_fkey; Type: FK CONSTRAINT; Schema: sitewise_analytics; Owner: -
--

ALTER TABLE ONLY sitewise_analytics.subject_features
    ADD CONSTRAINT subject_features_subject_id_fkey FOREIGN KEY (subject_id) REFERENCES demand_gen.subjects(subject_id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict kAy41iAaLhxh48H0qzQkYcHTyHpWSegUgbmPued81TJcTb41T3a6K2Usrq0JXpV

