-- =====================================================================
-- 20261123_08_fyp_features_population_spatial.sql
-- =====================================================================
-- Purpose
--   Restore ``fyp_features.property_population_spatial`` — the WorldPop ring
--   table the expanded64 feature loader reads for population features.
--
--   ``sitewise.ml.pu_expanded`` queries it as
--     SELECT ... FROM fyp_features.property_population_spatial
--     WHERE source_record_id = ANY(:ids)
--   so a missing table (or missing rows) removes population features from the
--   live score instead of failing loudly — hence it is restored explicitly.
--
-- Provenance
--   pg_dump ... --schema-only --no-owner --no-privileges \
--           -t fyp_features.property_population_spatial
--   pg_dump does not emit CREATE SCHEMA for a single -t table, so the schema
--   is created here before the table.
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
    IF to_regclass('fyp_features.property_population_spatial') IS NOT NULL THEN
        RAISE EXCEPTION 'REFUSED: fyp_features.property_population_spatial already exists';
    END IF;
    RAISE NOTICE 'fyp_features restore accepted: % on port %', db, port;
END
$$;

CREATE SCHEMA IF NOT EXISTS fyp_features;

--
-- PostgreSQL database dump
--

\restrict ClIbDmD3WO9ZmR17vchWUbOZhxm7NFagvj2ZskYHkMeZpV8wDzWsvWcX9blM1NM

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
-- Name: property_population_spatial; Type: TABLE; Schema: fyp_features; Owner: -
--

CREATE TABLE fyp_features.property_population_spatial (
    source_record_type text NOT NULL,
    source_record_id text NOT NULL,
    original_identifier text,
    latitude double precision,
    longitude double precision,
    state text,
    gadm_state_code text,
    gadm_state_name text,
    gadm_admin2_code text,
    gadm_admin2_name text,
    dosm_district_key text,
    geography_match_status text,
    pop_ring_0_500m double precision,
    pop_ring_500_1km double precision,
    pop_ring_1km_3km double precision,
    pop_total_200m double precision,
    pop_total_1km double precision,
    pop_total_3km double precision,
    pop_density_km2 double precision,
    pop_density_500m_km2 double precision,
    pop_density_3km_km2 double precision,
    pop_core_share_500m_1km double precision,
    pop_growth_5yr double precision,
    ambient_population_1km double precision,
    ambient_to_resident_ratio_1km double precision,
    pop_age_0_14_1km double precision,
    pop_age_15_24_1km double precision,
    pop_age_25_34_1km double precision,
    pop_age_35_54_1km double precision,
    pop_age_55_64_1km double precision,
    pop_age_65plus_1km double precision,
    pct_age_20_34_1km double precision,
    pct_age_15_64_1km double precision,
    pct_age_18_35 double precision,
    residential_building_count_500m integer,
    residential_building_count_1km integer,
    residential_building_density_500m double precision,
    residential_floor_area_500m_m2 double precision,
    residential_landuse_share_500m_pct double precision,
    estimated_households_1km double precision,
    office_floor_area_500m_m2 double precision,
    schools_count_1km integer,
    malls_count_1km integer,
    dist_nearest_mall_m double precision,
    universities_count_1km integer,
    hospitals_count_1km integer,
    office_poi_count_500m integer,
    workplace_poi_density_1km double precision,
    population_source text,
    population_source_year integer,
    landscan_source_year integer,
    population_raster_coverage_pct double precision,
    population_quality_flag text,
    local_age_raster_status text,
    building_use_quality_flag text,
    source_snapshot_id text
);


--
-- Name: property_population_spatial property_population_spatial_pkey; Type: CONSTRAINT; Schema: fyp_features; Owner: -
--

ALTER TABLE ONLY fyp_features.property_population_spatial
    ADD CONSTRAINT property_population_spatial_pkey PRIMARY KEY (source_record_type, source_record_id);


--
-- Name: property_population_spatial cp12_barrier; Type: TRIGGER; Schema: fyp_features; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp_features.property_population_spatial FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- PostgreSQL database dump complete
--

\unrestrict ClIbDmD3WO9ZmR17vchWUbOZhxm7NFagvj2ZskYHkMeZpV8wDzWsvWcX9blM1NM

