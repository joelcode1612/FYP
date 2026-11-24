-- =====================================================================
-- 20261123_05_fyp_sitewise_schema.sql
-- =====================================================================
-- Purpose
--   Restore the DDL of the three schemas the application's *catalogue* and
--   *assessment selector* paths read, into the isolated PG18 E2E cluster:
--
--     sitewise_app.properties     the 955-row catalogue the app lists
--     sitewise_app.profiles       empty here, required by the schema
--     fyp.*                       operational listings + the
--                                 `catalogue_properties` view over
--                                 sitewise_app.properties
--     demand_gen.subjects         FK target of fyp.property_subject_links
--
--   Schema only. No rows are copied by this file; the approved 8-property
--   data copy is a separate, explicit step.
--
-- Provenance
--   Produced by:
--     pg_dump -h 127.0.0.1 -p 5432 -U postgres -d Final_Location_Analysis \
--             --schema-only --no-owner --no-privileges \
--             --schema=sitewise_app --schema=fyp --schema=demand_gen
--   Source is PostgreSQL 16.14; this cluster is PostgreSQL 18.6. The dump
--   contains no extension, no PostGIS type and no geometry column, which is
--   why it restores unchanged. (Measured: FLA has hstore/pgcrypto/plpgsql
--   only, and `fyp.rental_properties` has no `geom` column at all.)
--
-- Safety
--   The guard below refuses to run anywhere except a `project1_pg18_%`
--   database on port 5544. Dss and Final_Location_Analysis can never be
--   touched by this file even if it is invoked with a wrong URL.
-- =====================================================================

DO $$
DECLARE
    db   text := current_database();
    port int  := inet_server_port();
BEGIN
    IF db NOT LIKE 'project1\_pg18\_%' THEN
        RAISE EXCEPTION
            'REFUSED: % is not a project1_pg18_* database', db;
    END IF;
    IF port <> 5544 THEN
        RAISE EXCEPTION
            'REFUSED: port % is not the isolated PG18 cluster (5544)', port;
    END IF;
    IF db IN ('Dss', 'Final_Location_Analysis') THEN
        RAISE EXCEPTION 'REFUSED: % is a protected database', db;
    END IF;
    IF to_regclass('sitewise_app.properties') IS NOT NULL THEN
        RAISE EXCEPTION
            'REFUSED: sitewise_app.properties already exists — this file is not idempotent';
    END IF;
    RAISE NOTICE 'schema restore target accepted: % on port %', db, port;
END
$$;

--
-- PostgreSQL database dump
--

\restrict FauDyAPnqjcn7ui5mOu0pFMREyW7fshDs5dtM2TXFZLiVsebhv4i19DE9g6y4S1

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
-- Name: demand_gen; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA demand_gen;


--
-- Name: fyp; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA fyp;


--
-- Name: SCHEMA fyp; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA fyp IS 'Application schema for F&B geospatial recommendation FYP (Joel Tan Hou Jun 25WMD09957)';


--
-- Name: sitewise_app; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA sitewise_app;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: dedup_audit; Type: TABLE; Schema: demand_gen; Owner: -
--

CREATE TABLE demand_gen.dedup_audit (
    canonical_pk text,
    merged_pk text,
    poi_category text,
    rule text,
    distance_m double precision,
    name_canonical text,
    name_merged text
);


--
-- Name: features; Type: TABLE; Schema: demand_gen; Owner: -
--

CREATE TABLE demand_gen.features (
    subject_id text NOT NULL,
    sample_class text,
    state_dosm text,
    latitude double precision,
    longitude double precision,
    coordinate_quality text,
    operating_status_subject text,
    subject_category text,
    subject_name text,
    google_place_id text,
    office_pois_500m integer,
    schools_count_500m integer,
    universities_colleges_count_500m integer,
    retail_pois_500m integer,
    malls_count_500m integer,
    hospitals_count_500m integer,
    supermarkets_count_500m integer,
    office_pois_1000m integer,
    schools_count_1000m integer,
    universities_colleges_count_1000m integer,
    retail_pois_1000m integer,
    malls_count_1000m integer,
    hospitals_count_1000m integer,
    supermarkets_count_1000m integer,
    office_buildings_500m_qa integer,
    office_buildings_1000m_qa integer,
    nearest_office_m numeric(10,1),
    nearest_school_m numeric(10,1),
    nearest_university_college_m numeric(10,1),
    nearest_retail_m numeric(10,1),
    nearest_mall_m numeric(10,1),
    nearest_hospital_m numeric(10,1),
    nearest_supermarket_m numeric(10,1),
    has_null_coordinates boolean,
    source_coverage_status text,
    analysis_status text,
    feature_calculated_at text,
    feature_version text
);


--
-- Name: pois_master; Type: TABLE; Schema: demand_gen; Owner: -
--

CREATE TABLE demand_gen.pois_master (
    poi_pk text,
    source_platform text,
    element_type text,
    src_id text,
    name text,
    poi_category text,
    poi_subcategory text,
    original_category text,
    brand text,
    operator text,
    tags public.hstore,
    operating_status text,
    geometry_type text,
    longitude double precision,
    latitude double precision,
    orig_area_m2 double precision,
    addr_street text,
    addr_num text,
    state_canon text,
    district text,
    full_address text,
    license text,
    source_version text,
    source_observed_at text,
    collected_at text,
    poi_id text,
    dedup_status text,
    merged_source_ids text,
    verification_status text,
    active_for_analysis boolean,
    coordinate_precision text
);


--
-- Name: pois_raw; Type: TABLE; Schema: demand_gen; Owner: -
--

CREATE TABLE demand_gen.pois_raw (
    poi_pk text NOT NULL,
    source_platform text,
    element_type text,
    src_id text,
    name text,
    poi_category text,
    poi_subcategory text,
    original_category text,
    brand text,
    operator text,
    tags public.hstore,
    operating_status text,
    geometry_type text,
    longitude double precision,
    latitude double precision,
    orig_area_m2 double precision,
    addr_street text,
    addr_num text,
    state_canon text,
    district text,
    full_address text,
    license text,
    source_version text,
    source_observed_at text,
    collected_at text
);


--
-- Name: states; Type: TABLE; Schema: demand_gen; Owner: -
--

CREATE TABLE demand_gen.states (
    name text
);


--
-- Name: subject_poi_pairs; Type: TABLE; Schema: demand_gen; Owner: -
--

CREATE TABLE demand_gen.subject_poi_pairs (
    subject_id text,
    sample_class text,
    poi_id text,
    poi_name text,
    poi_category text,
    poi_source text,
    poi_verification_status text,
    poi_state text,
    subject_state text,
    distance_m double precision,
    within_500m boolean,
    within_1000m boolean
);


--
-- Name: subjects; Type: TABLE; Schema: demand_gen; Owner: -
--

CREATE TABLE demand_gen.subjects (
    subject_id text NOT NULL,
    sample_class text,
    subject_name text,
    state_dosm text,
    latitude double precision,
    longitude double precision,
    coordinate_source text,
    coordinate_quality text,
    operating_status_subject text,
    subject_category text,
    google_place_id text,
    in_study_state boolean
);


--
-- Name: activity_log; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.activity_log (
    id bigint NOT NULL,
    user_id bigint,
    action character varying(80) NOT NULL,
    entity_type character varying(60),
    entity_id bigint,
    details jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: activity_log_id_seq; Type: SEQUENCE; Schema: fyp; Owner: -
--

CREATE SEQUENCE fyp.activity_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_log_id_seq; Type: SEQUENCE OWNED BY; Schema: fyp; Owner: -
--

ALTER SEQUENCE fyp.activity_log_id_seq OWNED BY fyp.activity_log.id;


--
-- Name: ai_explanations; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.ai_explanations (
    id bigint NOT NULL,
    recommendation_id bigint NOT NULL,
    overall_summary text,
    strengths jsonb,
    weaknesses jsonb,
    contribution_order jsonb,
    model_version character varying(60),
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ai_explanations_id_seq; Type: SEQUENCE; Schema: fyp; Owner: -
--

CREATE SEQUENCE fyp.ai_explanations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_explanations_id_seq; Type: SEQUENCE OWNED BY; Schema: fyp; Owner: -
--

ALTER SEQUENCE fyp.ai_explanations_id_seq OWNED BY fyp.ai_explanations.id;


--
-- Name: properties; Type: TABLE; Schema: sitewise_app; Owner: -
--

CREATE TABLE sitewise_app.properties (
    id text NOT NULL,
    title text NOT NULL,
    address text NOT NULL,
    city text DEFAULT ''::text NOT NULL,
    state text NOT NULL,
    postcode text DEFAULT ''::text NOT NULL,
    rental_rm double precision NOT NULL,
    size_sqft double precision NOT NULL,
    latitude double precision NOT NULL,
    longitude double precision NOT NULL,
    property_type text NOT NULL,
    image_url text,
    source_url text,
    suitability_score double precision,
    dataset_validation text NOT NULL,
    source_workbook text NOT NULL,
    source_sheet text NOT NULL,
    source_row integer NOT NULL,
    source_data jsonb NOT NULL,
    imported_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT properties_latitude_check CHECK (((latitude >= ('-90'::integer)::double precision) AND (latitude <= (90)::double precision))),
    CONSTRAINT properties_longitude_check CHECK (((longitude >= ('-180'::integer)::double precision) AND (longitude <= (180)::double precision))),
    CONSTRAINT properties_rental_rm_check CHECK ((rental_rm >= (0)::double precision)),
    CONSTRAINT properties_size_sqft_check CHECK ((size_sqft > (0)::double precision)),
    CONSTRAINT properties_suitability_score_check CHECK (((suitability_score >= (0)::double precision) AND (suitability_score <= (100)::double precision)))
);


--
-- Name: catalogue_properties; Type: VIEW; Schema: fyp; Owner: -
--

CREATE VIEW fyp.catalogue_properties AS
 SELECT id,
    title,
    address,
    city,
    state,
    postcode,
    rental_rm,
    size_sqft,
    latitude,
    longitude,
    property_type,
    image_url,
    source_url,
    suitability_score,
    dataset_validation,
    source_workbook,
    source_sheet,
    source_row,
    source_data,
    imported_at
   FROM sitewise_app.properties;


--
-- Name: entrepreneur_preferences; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.entrepreneur_preferences (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    budget_min numeric(12,2),
    budget_max numeric(12,2),
    business_type character varying(80),
    preferred_states text[],
    min_size_sqft numeric(10,2),
    min_score double precision,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    service_model text,
    target_customers text[],
    recommendation_priority text,
    target_price_segment text
);


--
-- Name: entrepreneur_preferences_id_seq; Type: SEQUENCE; Schema: fyp; Owner: -
--

CREATE SEQUENCE fyp.entrepreneur_preferences_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: entrepreneur_preferences_id_seq; Type: SEQUENCE OWNED BY; Schema: fyp; Owner: -
--

ALTER SEQUENCE fyp.entrepreneur_preferences_id_seq OWNED BY fyp.entrepreneur_preferences.id;


--
-- Name: favourite_properties; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.favourite_properties (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    property_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: favourite_properties_id_seq; Type: SEQUENCE; Schema: fyp; Owner: -
--

CREATE SEQUENCE fyp.favourite_properties_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: favourite_properties_id_seq; Type: SEQUENCE OWNED BY; Schema: fyp; Owner: -
--

ALTER SEQUENCE fyp.favourite_properties_id_seq OWNED BY fyp.favourite_properties.id;


--
-- Name: ml_models; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.ml_models (
    id bigint NOT NULL,
    version character varying(60) NOT NULL,
    algorithm character varying(80),
    feature_count integer,
    training_rows integer,
    positive_rows integer,
    metrics jsonb,
    model_path text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ml_models_id_seq; Type: SEQUENCE; Schema: fyp; Owner: -
--

CREATE SEQUENCE fyp.ml_models_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ml_models_id_seq; Type: SEQUENCE OWNED BY; Schema: fyp; Owner: -
--

ALTER SEQUENCE fyp.ml_models_id_seq OWNED BY fyp.ml_models.id;


--
-- Name: property_enrichment_category; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.property_enrichment_category (
    property_id bigint NOT NULL,
    category text NOT NULL,
    phase text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    measurement jsonb,
    provenance jsonb,
    coordinate_hash text,
    calculation_version text,
    attempt_count integer DEFAULT 0 NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    last_error text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_pec_category CHECK ((category = ANY (ARRAY['fnb_competitors'::text, 'demand_generators'::text, 'roads_transport'::text, 'parking'::text, 'population'::text, 'age_population'::text]))),
    CONSTRAINT ck_pec_phase CHECK ((phase = ANY (ARRAY['postgis'::text, 'population'::text]))),
    CONSTRAINT ck_pec_status CHECK ((status = ANY (ARRAY['pending'::text, 'running'::text, 'current'::text, 'unavailable'::text, 'failed'::text, 'stale'::text])))
);


--
-- Name: property_feature_freshness; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.property_feature_freshness (
    property_id bigint NOT NULL,
    refresh_status text DEFAULT 'pending'::text NOT NULL,
    calculation_version text,
    features_calculated_at timestamp with time zone,
    last_refresh_attempt_at timestamp with time zone,
    last_successful_refresh_at timestamp with time zone,
    source_release text,
    competitor_source text DEFAULT 'osm'::text NOT NULL,
    last_error text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_property_freshness_status CHECK ((refresh_status = ANY (ARRAY['current'::text, 'stale'::text, 'pending'::text, 'failed'::text, 'unavailable'::text])))
);


--
-- Name: property_features; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.property_features (
    id bigint NOT NULL,
    property_id bigint NOT NULL,
    suitable_for text,
    nearby_landmarks text,
    amenities jsonb,
    remarks text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: property_features_id_seq; Type: SEQUENCE; Schema: fyp; Owner: -
--

CREATE SEQUENCE fyp.property_features_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: property_features_id_seq; Type: SEQUENCE OWNED BY; Schema: fyp; Owner: -
--

ALTER SEQUENCE fyp.property_features_id_seq OWNED BY fyp.property_features.id;


--
-- Name: property_geospatial_features; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.property_geospatial_features (
    id bigint NOT NULL,
    property_id bigint NOT NULL,
    population_500m double precision,
    population_1km double precision,
    population_level character varying(20),
    competitor_count_500m integer,
    competitor_count_1km integer,
    demand_generator_count_500m integer,
    demand_generator_count_1km integer,
    accessibility_road_km_1km double precision,
    accessibility_score double precision,
    nearest_major_road_m double precision,
    district_name character varying(120),
    state_name character varying(120),
    income_median numeric(12,2),
    income_mean numeric(12,2),
    market_segment character varying(40),
    overall_location_score double precision,
    last_calculated_at timestamp with time zone DEFAULT now() NOT NULL,
    parking_facilities_500m integer,
    parking_facilities_1km integer,
    nearest_parking_m double precision,
    transit_stops_500m integer,
    transit_stops_1km integer,
    coordinate_hash text,
    enrichment_status text,
    enrichment_provenance jsonb,
    pop_age_0_14_500m double precision,
    pop_age_15_24_500m double precision,
    pop_age_25_34_500m double precision,
    pop_age_35_49_500m double precision,
    pop_age_50_64_500m double precision,
    pop_age_65_plus_500m double precision,
    pop_age_0_14_1km double precision,
    pop_age_15_24_1km double precision,
    pop_age_25_34_1km double precision,
    pop_age_35_49_1km double precision,
    pop_age_50_64_1km double precision,
    pop_age_65_plus_1km double precision,
    share_age_15_34_500m double precision,
    share_age_15_34_1km double precision,
    age_coverage_500m double precision,
    age_coverage_1km double precision,
    age_data_source text,
    age_data_year integer,
    age_data_status text
);


--
-- Name: property_geospatial_features_id_seq; Type: SEQUENCE; Schema: fyp; Owner: -
--

CREATE SEQUENCE fyp.property_geospatial_features_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: property_geospatial_features_id_seq; Type: SEQUENCE OWNED BY; Schema: fyp; Owner: -
--

ALTER SEQUENCE fyp.property_geospatial_features_id_seq OWNED BY fyp.property_geospatial_features.id;


--
-- Name: property_listing_sources; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.property_listing_sources (
    id bigint NOT NULL,
    property_id bigint NOT NULL,
    source_platform text NOT NULL,
    source_listing_id text,
    source_url text,
    source_availability text,
    source_observed_at timestamp with time zone,
    source_checked_at timestamp with time zone,
    usage_rights_note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: property_listing_sources_id_seq; Type: SEQUENCE; Schema: fyp; Owner: -
--

ALTER TABLE fyp.property_listing_sources ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME fyp.property_listing_sources_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: property_listing_verification; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.property_listing_verification (
    property_id bigint NOT NULL,
    reviewer_user_id bigint,
    verification_method text,
    evidence_reference text,
    review_notes text,
    reviewed_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: property_photos; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.property_photos (
    id bigint NOT NULL,
    property_id bigint NOT NULL,
    url text NOT NULL,
    caption character varying(255),
    is_primary boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: property_photos_id_seq; Type: SEQUENCE; Schema: fyp; Owner: -
--

CREATE SEQUENCE fyp.property_photos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: property_photos_id_seq; Type: SEQUENCE OWNED BY; Schema: fyp; Owner: -
--

ALTER SEQUENCE fyp.property_photos_id_seq OWNED BY fyp.property_photos.id;


--
-- Name: property_subject_links; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.property_subject_links (
    property_id bigint NOT NULL,
    subject_id text,
    sitewise_property_id text,
    match_method text,
    match_evidence text,
    match_verified boolean DEFAULT false NOT NULL,
    linked_at timestamp with time zone DEFAULT now() NOT NULL,
    verified_at timestamp with time zone,
    CONSTRAINT verified_link_has_identifier CHECK (((NOT match_verified) OR (subject_id IS NOT NULL) OR (sitewise_property_id IS NOT NULL)))
);


--
-- Name: recommendation_results; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.recommendation_results (
    id bigint NOT NULL,
    batch_id uuid NOT NULL,
    user_id bigint NOT NULL,
    property_id bigint NOT NULL,
    suitability_score double precision NOT NULL,
    ranking integer NOT NULL,
    preference_snapshot jsonb,
    feature_snapshot jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: recommendation_results_id_seq; Type: SEQUENCE; Schema: fyp; Owner: -
--

CREATE SEQUENCE fyp.recommendation_results_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: recommendation_results_id_seq; Type: SEQUENCE OWNED BY; Schema: fyp; Owner: -
--

ALTER SEQUENCE fyp.recommendation_results_id_seq OWNED BY fyp.recommendation_results.id;


--
-- Name: rental_properties; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.rental_properties (
    id bigint NOT NULL,
    owner_id bigint,
    listing_id character varying(120),
    name character varying(255) NOT NULL,
    property_type character varying(255) DEFAULT 'Shop'::character varying NOT NULL,
    description text,
    address text,
    city character varying(120),
    state character varying(255),
    latitude double precision,
    longitude double precision,
    rental_price numeric(12,2),
    size_sqft numeric(10,2),
    psf numeric(8,2),
    bathrooms numeric(4,1),
    floor_level numeric(5,1),
    frontage_ft numeric(8,2),
    depth_ft numeric(8,2),
    land_area_sqft numeric(12,2),
    built_up_sqft numeric(12,2),
    tenure character varying(255),
    furnishing character varying(255),
    availability character varying(255),
    is_corner_lot smallint DEFAULT 0 NOT NULL,
    has_parking smallint DEFAULT 0 NOT NULL,
    is_freehold smallint DEFAULT 0 NOT NULL,
    is_fnb_suitable smallint DEFAULT 0 NOT NULL,
    verification_status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    rejection_reason text,
    is_published boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    floor_description text,
    unit_position text,
    facing_direction text,
    availability_verified_at timestamp with time zone,
    published_at timestamp with time zone,
    owner_user_id uuid,
    postcode character varying(5),
    address_validation_status character varying(24),
    address_formatted text,
    address_validated_at timestamp with time zone,
    CONSTRAINT rental_properties_address_validation_status_check CHECK (((address_validation_status IS NULL) OR ((address_validation_status)::text = ANY (ARRAY[('validated'::character varying)::text, ('partially_validated'::character varying)::text, ('unconfirmed'::character varying)::text])))),
    CONSTRAINT rental_properties_verification_status_check CHECK (((verification_status)::text = ANY (ARRAY[('draft'::character varying)::text, ('pending'::character varying)::text, ('approved'::character varying)::text, ('rejected'::character varying)::text])))
);


--
-- Name: rental_properties_id_seq; Type: SEQUENCE; Schema: fyp; Owner: -
--

CREATE SEQUENCE fyp.rental_properties_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rental_properties_id_seq; Type: SEQUENCE OWNED BY; Schema: fyp; Owner: -
--

ALTER SEQUENCE fyp.rental_properties_id_seq OWNED BY fyp.rental_properties.id;


--
-- Name: users; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.users (
    id bigint NOT NULL,
    email character varying(255) NOT NULL,
    password_hash character varying(255) NOT NULL,
    full_name character varying(150) NOT NULL,
    phone character varying(30),
    role character varying(20) DEFAULT 'entrepreneur'::character varying NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT users_role_check CHECK (((role)::text = ANY (ARRAY[('admin'::character varying)::text, ('owner'::character varying)::text, ('entrepreneur'::character varying)::text])))
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: fyp; Owner: -
--

CREATE SEQUENCE fyp.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: fyp; Owner: -
--

ALTER SEQUENCE fyp.users_id_seq OWNED BY fyp.users.id;


--
-- Name: virtual_tours; Type: TABLE; Schema: fyp; Owner: -
--

CREATE TABLE fyp.virtual_tours (
    id bigint NOT NULL,
    property_id bigint NOT NULL,
    created_by bigint,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    tour_type character varying(20) DEFAULT 'panorama'::character varying NOT NULL,
    panorama_path text,
    image_count integer DEFAULT 0 NOT NULL,
    processing_note text,
    capture_date date,
    rejection_reason text,
    submitted_at timestamp with time zone,
    verified_at timestamp with time zone,
    verified_by bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT virtual_tours_status_check CHECK (((status)::text = ANY (ARRAY[('draft'::character varying)::text, ('processing'::character varying)::text, ('submitted'::character varying)::text, ('approved'::character varying)::text, ('rejected'::character varying)::text]))),
    CONSTRAINT virtual_tours_tour_type_check CHECK (((tour_type)::text = ANY (ARRAY[('panorama'::character varying)::text, ('cubemap'::character varying)::text])))
);


--
-- Name: virtual_tours_id_seq; Type: SEQUENCE; Schema: fyp; Owner: -
--

CREATE SEQUENCE fyp.virtual_tours_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: virtual_tours_id_seq; Type: SEQUENCE OWNED BY; Schema: fyp; Owner: -
--

ALTER SEQUENCE fyp.virtual_tours_id_seq OWNED BY fyp.virtual_tours.id;


--
-- Name: profiles; Type: TABLE; Schema: sitewise_app; Owner: -
--

CREATE TABLE sitewise_app.profiles (
    user_id uuid NOT NULL,
    email text NOT NULL,
    display_name text NOT NULL,
    role text DEFAULT 'entrepreneur'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT profiles_role_check CHECK ((role = ANY (ARRAY['entrepreneur'::text, 'owner'::text, 'admin'::text])))
);


--
-- Name: activity_log id; Type: DEFAULT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.activity_log ALTER COLUMN id SET DEFAULT nextval('fyp.activity_log_id_seq'::regclass);


--
-- Name: ai_explanations id; Type: DEFAULT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.ai_explanations ALTER COLUMN id SET DEFAULT nextval('fyp.ai_explanations_id_seq'::regclass);


--
-- Name: entrepreneur_preferences id; Type: DEFAULT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.entrepreneur_preferences ALTER COLUMN id SET DEFAULT nextval('fyp.entrepreneur_preferences_id_seq'::regclass);


--
-- Name: favourite_properties id; Type: DEFAULT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.favourite_properties ALTER COLUMN id SET DEFAULT nextval('fyp.favourite_properties_id_seq'::regclass);


--
-- Name: ml_models id; Type: DEFAULT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.ml_models ALTER COLUMN id SET DEFAULT nextval('fyp.ml_models_id_seq'::regclass);


--
-- Name: property_features id; Type: DEFAULT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_features ALTER COLUMN id SET DEFAULT nextval('fyp.property_features_id_seq'::regclass);


--
-- Name: property_geospatial_features id; Type: DEFAULT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_geospatial_features ALTER COLUMN id SET DEFAULT nextval('fyp.property_geospatial_features_id_seq'::regclass);


--
-- Name: property_photos id; Type: DEFAULT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_photos ALTER COLUMN id SET DEFAULT nextval('fyp.property_photos_id_seq'::regclass);


--
-- Name: recommendation_results id; Type: DEFAULT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.recommendation_results ALTER COLUMN id SET DEFAULT nextval('fyp.recommendation_results_id_seq'::regclass);


--
-- Name: rental_properties id; Type: DEFAULT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.rental_properties ALTER COLUMN id SET DEFAULT nextval('fyp.rental_properties_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.users ALTER COLUMN id SET DEFAULT nextval('fyp.users_id_seq'::regclass);


--
-- Name: virtual_tours id; Type: DEFAULT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.virtual_tours ALTER COLUMN id SET DEFAULT nextval('fyp.virtual_tours_id_seq'::regclass);


--
-- Name: features features_pkey; Type: CONSTRAINT; Schema: demand_gen; Owner: -
--

ALTER TABLE ONLY demand_gen.features
    ADD CONSTRAINT features_pkey PRIMARY KEY (subject_id);


--
-- Name: pois_raw pois_raw_pkey; Type: CONSTRAINT; Schema: demand_gen; Owner: -
--

ALTER TABLE ONLY demand_gen.pois_raw
    ADD CONSTRAINT pois_raw_pkey PRIMARY KEY (poi_pk);


--
-- Name: subjects subjects_pkey; Type: CONSTRAINT; Schema: demand_gen; Owner: -
--

ALTER TABLE ONLY demand_gen.subjects
    ADD CONSTRAINT subjects_pkey PRIMARY KEY (subject_id);


--
-- Name: activity_log activity_log_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.activity_log
    ADD CONSTRAINT activity_log_pkey PRIMARY KEY (id);


--
-- Name: ai_explanations ai_explanations_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.ai_explanations
    ADD CONSTRAINT ai_explanations_pkey PRIMARY KEY (id);


--
-- Name: entrepreneur_preferences entrepreneur_preferences_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.entrepreneur_preferences
    ADD CONSTRAINT entrepreneur_preferences_pkey PRIMARY KEY (id);


--
-- Name: entrepreneur_preferences entrepreneur_preferences_user_id_key; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.entrepreneur_preferences
    ADD CONSTRAINT entrepreneur_preferences_user_id_key UNIQUE (user_id);


--
-- Name: favourite_properties favourite_properties_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.favourite_properties
    ADD CONSTRAINT favourite_properties_pkey PRIMARY KEY (id);


--
-- Name: favourite_properties favourite_properties_user_id_property_id_key; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.favourite_properties
    ADD CONSTRAINT favourite_properties_user_id_property_id_key UNIQUE (user_id, property_id);


--
-- Name: ml_models ml_models_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.ml_models
    ADD CONSTRAINT ml_models_pkey PRIMARY KEY (id);


--
-- Name: ml_models ml_models_version_key; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.ml_models
    ADD CONSTRAINT ml_models_version_key UNIQUE (version);


--
-- Name: property_enrichment_category property_enrichment_category_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_enrichment_category
    ADD CONSTRAINT property_enrichment_category_pkey PRIMARY KEY (property_id, category);


--
-- Name: property_feature_freshness property_feature_freshness_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_feature_freshness
    ADD CONSTRAINT property_feature_freshness_pkey PRIMARY KEY (property_id);


--
-- Name: property_features property_features_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_features
    ADD CONSTRAINT property_features_pkey PRIMARY KEY (id);


--
-- Name: property_features property_features_property_id_key; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_features
    ADD CONSTRAINT property_features_property_id_key UNIQUE (property_id);


--
-- Name: property_geospatial_features property_geospatial_features_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_geospatial_features
    ADD CONSTRAINT property_geospatial_features_pkey PRIMARY KEY (id);


--
-- Name: property_geospatial_features property_geospatial_features_property_id_key; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_geospatial_features
    ADD CONSTRAINT property_geospatial_features_property_id_key UNIQUE (property_id);


--
-- Name: property_listing_sources property_listing_sources_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_listing_sources
    ADD CONSTRAINT property_listing_sources_pkey PRIMARY KEY (id);


--
-- Name: property_listing_verification property_listing_verification_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_listing_verification
    ADD CONSTRAINT property_listing_verification_pkey PRIMARY KEY (property_id);


--
-- Name: property_photos property_photos_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_photos
    ADD CONSTRAINT property_photos_pkey PRIMARY KEY (id);


--
-- Name: property_subject_links property_subject_links_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_subject_links
    ADD CONSTRAINT property_subject_links_pkey PRIMARY KEY (property_id);


--
-- Name: property_subject_links property_subject_links_sitewise_property_id_key; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_subject_links
    ADD CONSTRAINT property_subject_links_sitewise_property_id_key UNIQUE (sitewise_property_id);


--
-- Name: property_subject_links property_subject_links_subject_id_key; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_subject_links
    ADD CONSTRAINT property_subject_links_subject_id_key UNIQUE (subject_id);


--
-- Name: recommendation_results recommendation_results_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.recommendation_results
    ADD CONSTRAINT recommendation_results_pkey PRIMARY KEY (id);


--
-- Name: rental_properties rental_properties_listing_id_key; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.rental_properties
    ADD CONSTRAINT rental_properties_listing_id_key UNIQUE (listing_id);


--
-- Name: rental_properties rental_properties_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.rental_properties
    ADD CONSTRAINT rental_properties_pkey PRIMARY KEY (id);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: virtual_tours virtual_tours_pkey; Type: CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.virtual_tours
    ADD CONSTRAINT virtual_tours_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: sitewise_app; Owner: -
--

ALTER TABLE ONLY sitewise_app.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (user_id);


--
-- Name: properties properties_pkey; Type: CONSTRAINT; Schema: sitewise_app; Owner: -
--

ALTER TABLE ONLY sitewise_app.properties
    ADD CONSTRAINT properties_pkey PRIMARY KEY (id);


--
-- Name: pois_master_poi_category_idx; Type: INDEX; Schema: demand_gen; Owner: -
--

CREATE INDEX pois_master_poi_category_idx ON demand_gen.pois_master USING btree (poi_category);


--
-- Name: pois_raw_cat_idx; Type: INDEX; Schema: demand_gen; Owner: -
--

CREATE INDEX pois_raw_cat_idx ON demand_gen.pois_raw USING btree (poi_category);


--
-- Name: subject_poi_pairs_poi_category_idx; Type: INDEX; Schema: demand_gen; Owner: -
--

CREATE INDEX subject_poi_pairs_poi_category_idx ON demand_gen.subject_poi_pairs USING btree (poi_category);


--
-- Name: subject_poi_pairs_subject_id_idx; Type: INDEX; Schema: demand_gen; Owner: -
--

CREATE INDEX subject_poi_pairs_subject_id_idx ON demand_gen.subject_poi_pairs USING btree (subject_id);


--
-- Name: idx_expl_rec; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_expl_rec ON fyp.ai_explanations USING btree (recommendation_id);


--
-- Name: idx_log_action; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_log_action ON fyp.activity_log USING btree (action, created_at DESC);


--
-- Name: idx_log_user; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_log_user ON fyp.activity_log USING btree (user_id, created_at DESC);


--
-- Name: idx_pec_category_status; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_pec_category_status ON fyp.property_enrichment_category USING btree (category, status);


--
-- Name: idx_pec_property; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_pec_property ON fyp.property_enrichment_category USING btree (property_id);


--
-- Name: idx_pec_status; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_pec_status ON fyp.property_enrichment_category USING btree (status);


--
-- Name: idx_pgf_property; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_pgf_property ON fyp.property_geospatial_features USING btree (property_id);


--
-- Name: idx_photos_property; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_photos_property ON fyp.property_photos USING btree (property_id);


--
-- Name: idx_rec_batch; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_rec_batch ON fyp.recommendation_results USING btree (batch_id);


--
-- Name: idx_rec_prop; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_rec_prop ON fyp.recommendation_results USING btree (property_id);


--
-- Name: idx_rec_user; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_rec_user ON fyp.recommendation_results USING btree (user_id, created_at DESC);


--
-- Name: idx_rp_city; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_rp_city ON fyp.rental_properties USING btree (city);


--
-- Name: idx_rp_listing; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_rp_listing ON fyp.rental_properties USING btree (listing_id);


--
-- Name: idx_rp_owner; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_rp_owner ON fyp.rental_properties USING btree (owner_id);


--
-- Name: idx_rp_price; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_rp_price ON fyp.rental_properties USING btree (rental_price);


--
-- Name: idx_rp_state; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_rp_state ON fyp.rental_properties USING btree (state);


--
-- Name: idx_rp_status; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_rp_status ON fyp.rental_properties USING btree (verification_status, is_published);


--
-- Name: idx_tours_property; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_tours_property ON fyp.virtual_tours USING btree (property_id);


--
-- Name: idx_tours_status; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX idx_tours_status ON fyp.virtual_tours USING btree (status);


--
-- Name: ix_rental_properties_postcode; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX ix_rental_properties_postcode ON fyp.rental_properties USING btree (postcode);


--
-- Name: ix_sw_listing_sources_property_id; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX ix_sw_listing_sources_property_id ON fyp.property_listing_sources USING btree (property_id);


--
-- Name: rental_properties_owner_user_idx; Type: INDEX; Schema: fyp; Owner: -
--

CREATE INDEX rental_properties_owner_user_idx ON fyp.rental_properties USING btree (owner_user_id);


--
-- Name: uq_sw_listing_source_external_id; Type: INDEX; Schema: fyp; Owner: -
--

CREATE UNIQUE INDEX uq_sw_listing_source_external_id ON fyp.property_listing_sources USING btree (source_platform, source_listing_id) WHERE (source_listing_id IS NOT NULL);


--
-- Name: sitewise_property_state; Type: INDEX; Schema: sitewise_app; Owner: -
--

CREATE INDEX sitewise_property_state ON sitewise_app.properties USING btree (state);


--
-- Name: dedup_audit cp12_barrier; Type: TRIGGER; Schema: demand_gen; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON demand_gen.dedup_audit FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: features cp12_barrier; Type: TRIGGER; Schema: demand_gen; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON demand_gen.features FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: pois_master cp12_barrier; Type: TRIGGER; Schema: demand_gen; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON demand_gen.pois_master FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: pois_raw cp12_barrier; Type: TRIGGER; Schema: demand_gen; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON demand_gen.pois_raw FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: states cp12_barrier; Type: TRIGGER; Schema: demand_gen; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON demand_gen.states FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: subject_poi_pairs cp12_barrier; Type: TRIGGER; Schema: demand_gen; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON demand_gen.subject_poi_pairs FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: subjects cp12_barrier; Type: TRIGGER; Schema: demand_gen; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON demand_gen.subjects FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: activity_log cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.activity_log FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: ai_explanations cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.ai_explanations FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: entrepreneur_preferences cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.entrepreneur_preferences FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: favourite_properties cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.favourite_properties FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: ml_models cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.ml_models FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: property_enrichment_category cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.property_enrichment_category FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: property_feature_freshness cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.property_feature_freshness FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: property_features cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.property_features FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: property_geospatial_features cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.property_geospatial_features FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: property_listing_sources cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.property_listing_sources FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: property_listing_verification cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.property_listing_verification FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: property_photos cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.property_photos FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: property_subject_links cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.property_subject_links FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: recommendation_results cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.recommendation_results FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: rental_properties cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.rental_properties FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: users cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.users FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: virtual_tours cp12_barrier; Type: TRIGGER; Schema: fyp; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON fyp.virtual_tours FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: profiles cp12_barrier; Type: TRIGGER; Schema: sitewise_app; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON sitewise_app.profiles FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: properties cp12_barrier; Type: TRIGGER; Schema: sitewise_app; Owner: -
--

CREATE TRIGGER cp12_barrier BEFORE INSERT OR DELETE OR UPDATE ON sitewise_app.properties FOR EACH ROW EXECUTE FUNCTION cp12.market_barrier();


--
-- Name: activity_log activity_log_user_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.activity_log
    ADD CONSTRAINT activity_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES fyp.users(id) ON DELETE SET NULL;


--
-- Name: ai_explanations ai_explanations_recommendation_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.ai_explanations
    ADD CONSTRAINT ai_explanations_recommendation_id_fkey FOREIGN KEY (recommendation_id) REFERENCES fyp.recommendation_results(id) ON DELETE CASCADE;


--
-- Name: entrepreneur_preferences entrepreneur_preferences_user_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.entrepreneur_preferences
    ADD CONSTRAINT entrepreneur_preferences_user_id_fkey FOREIGN KEY (user_id) REFERENCES fyp.users(id) ON DELETE CASCADE;


--
-- Name: favourite_properties favourite_properties_property_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.favourite_properties
    ADD CONSTRAINT favourite_properties_property_id_fkey FOREIGN KEY (property_id) REFERENCES fyp.rental_properties(id) ON DELETE CASCADE;


--
-- Name: favourite_properties favourite_properties_user_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.favourite_properties
    ADD CONSTRAINT favourite_properties_user_id_fkey FOREIGN KEY (user_id) REFERENCES fyp.users(id) ON DELETE CASCADE;


--
-- Name: property_features property_features_property_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_features
    ADD CONSTRAINT property_features_property_id_fkey FOREIGN KEY (property_id) REFERENCES fyp.rental_properties(id) ON DELETE CASCADE;


--
-- Name: property_geospatial_features property_geospatial_features_property_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_geospatial_features
    ADD CONSTRAINT property_geospatial_features_property_id_fkey FOREIGN KEY (property_id) REFERENCES fyp.rental_properties(id) ON DELETE CASCADE;


--
-- Name: property_listing_sources property_listing_sources_property_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_listing_sources
    ADD CONSTRAINT property_listing_sources_property_id_fkey FOREIGN KEY (property_id) REFERENCES fyp.rental_properties(id) ON DELETE CASCADE;


--
-- Name: property_listing_verification property_listing_verification_property_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_listing_verification
    ADD CONSTRAINT property_listing_verification_property_id_fkey FOREIGN KEY (property_id) REFERENCES fyp.rental_properties(id) ON DELETE CASCADE;


--
-- Name: property_listing_verification property_listing_verification_reviewer_user_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_listing_verification
    ADD CONSTRAINT property_listing_verification_reviewer_user_id_fkey FOREIGN KEY (reviewer_user_id) REFERENCES fyp.users(id) ON DELETE SET NULL;


--
-- Name: property_photos property_photos_property_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_photos
    ADD CONSTRAINT property_photos_property_id_fkey FOREIGN KEY (property_id) REFERENCES fyp.rental_properties(id) ON DELETE CASCADE;


--
-- Name: property_subject_links property_subject_links_property_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_subject_links
    ADD CONSTRAINT property_subject_links_property_id_fkey FOREIGN KEY (property_id) REFERENCES fyp.rental_properties(id) ON DELETE CASCADE;


--
-- Name: property_subject_links property_subject_links_sitewise_property_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_subject_links
    ADD CONSTRAINT property_subject_links_sitewise_property_id_fkey FOREIGN KEY (sitewise_property_id) REFERENCES sitewise_app.properties(id) ON DELETE SET NULL;


--
-- Name: property_subject_links property_subject_links_subject_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.property_subject_links
    ADD CONSTRAINT property_subject_links_subject_id_fkey FOREIGN KEY (subject_id) REFERENCES demand_gen.subjects(subject_id) ON DELETE SET NULL;


--
-- Name: recommendation_results recommendation_results_property_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.recommendation_results
    ADD CONSTRAINT recommendation_results_property_id_fkey FOREIGN KEY (property_id) REFERENCES fyp.rental_properties(id) ON DELETE CASCADE;


--
-- Name: recommendation_results recommendation_results_user_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.recommendation_results
    ADD CONSTRAINT recommendation_results_user_id_fkey FOREIGN KEY (user_id) REFERENCES fyp.users(id) ON DELETE CASCADE;


--
-- Name: rental_properties rental_properties_owner_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.rental_properties
    ADD CONSTRAINT rental_properties_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES fyp.users(id) ON DELETE SET NULL;


--
-- Name: virtual_tours virtual_tours_created_by_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.virtual_tours
    ADD CONSTRAINT virtual_tours_created_by_fkey FOREIGN KEY (created_by) REFERENCES fyp.users(id) ON DELETE SET NULL;


--
-- Name: virtual_tours virtual_tours_property_id_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.virtual_tours
    ADD CONSTRAINT virtual_tours_property_id_fkey FOREIGN KEY (property_id) REFERENCES fyp.rental_properties(id) ON DELETE CASCADE;


--
-- Name: virtual_tours virtual_tours_verified_by_fkey; Type: FK CONSTRAINT; Schema: fyp; Owner: -
--

ALTER TABLE ONLY fyp.virtual_tours
    ADD CONSTRAINT virtual_tours_verified_by_fkey FOREIGN KEY (verified_by) REFERENCES fyp.users(id) ON DELETE SET NULL;


--
-- PostgreSQL database dump complete
--

\unrestrict FauDyAPnqjcn7ui5mOu0pFMREyW7fshDs5dtM2TXFZLiVsebhv4i19DE9g6y4S1

