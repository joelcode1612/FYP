-- SUPABASE ONLY — manual approval required. NOT executed by the application.
--
-- Purpose: give Supabase the SAME canonical capture table names and structures
-- already present in the authoritative local PostgreSQL database:
--   fyp.capture_sessions, fyp.capture_frames, fyp.panorama_jobs, fyp.panoramas
--
-- Safety:
-- * every statement is CREATE ... IF NOT EXISTS / idempotent guard;
-- * no DROP, TRUNCATE, DELETE or ALTER of existing data;
-- * the legacy public.pano_capture_sessions / pano_capture_frames / pano_jobs
--   / pano_listing_links tables are LEFT INTACT. They are still read by the
--   standalone panorama bridge and were all verified empty before this file
--   was prepared, so no legacy rows are silently remapped;
-- * fyp stays service-role-only: no anon/authenticated grants, RLS enabled.
--
-- Run AFTER 03_supabase_schema_migration*.sql has exposed the fyp schema.

BEGIN;

CREATE SCHEMA IF NOT EXISTS fyp;
GRANT USAGE ON SCHEMA fyp TO service_role;

-- ---------------------------------------------------------------------------
-- fyp.capture_sessions — one authorized 38-target capture per local session.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fyp.capture_sessions (
    id                   uuid PRIMARY KEY,
    property_id          text NOT NULL,
    owner_id             uuid NOT NULL,
    status               text NOT NULL DEFAULT 'capturing',
    expected_frames      integer NOT NULL DEFAULT 38,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    capture_mode         text NOT NULL DEFAULT 'device_38',
    capture_plan_version text NOT NULL DEFAULT '1',
    CONSTRAINT capture_sessions_expected_frames_check CHECK (expected_frames > 0),
    CONSTRAINT capture_sessions_status_check CHECK (status IN (
        'capturing', 'pending_upload', 'uploading', 'uploaded',
        'processing', 'completed', 'failed', 'cancelled'))
);
CREATE INDEX IF NOT EXISTS idx_capture_sessions_property
    ON fyp.capture_sessions (property_id);

-- ---------------------------------------------------------------------------
-- fyp.capture_frames — one manifest row per confirmed target, no JPEG bytes.
-- Original JPEGs live ONLY in the private property-panoramas Storage bucket.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fyp.capture_frames (
    id              uuid PRIMARY KEY,
    session_id      uuid NOT NULL REFERENCES fyp.capture_sessions(id) ON DELETE CASCADE,
    target_index    integer NOT NULL,
    storage_path    text NOT NULL,
    checksum_sha256 text,
    uploaded_at     timestamptz NOT NULL DEFAULT now(),
    image_width     integer,
    image_height    integer,
    capture_pose    jsonb,
    captured_at     timestamptz,
    upload_status   text NOT NULL DEFAULT 'confirmed',
    CONSTRAINT capture_frames_session_target_key UNIQUE (session_id, target_index),
    CONSTRAINT capture_frames_target_index_check CHECK (target_index >= 0),
    CONSTRAINT capture_frames_image_width_check CHECK (image_width IS NULL OR image_width > 0),
    CONSTRAINT capture_frames_image_height_check CHECK (image_height IS NULL OR image_height > 0)
);
CREATE INDEX IF NOT EXISTS idx_capture_frames_session
    ON fyp.capture_frames (session_id, target_index);

-- ---------------------------------------------------------------------------
-- fyp.panorama_jobs — the ONE durable job queue. The partial unique index is
-- what makes repeated /process requests return the same live job.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fyp.panorama_jobs (
    id                  uuid PRIMARY KEY,
    session_id          uuid NOT NULL REFERENCES fyp.capture_sessions(id) ON DELETE CASCADE,
    status              text NOT NULL DEFAULT 'queued',
    output_storage_path text,
    error_message       text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    progress            smallint NOT NULL DEFAULT 0,
    processing_stage    text,
    retry_count         integer NOT NULL DEFAULT 0,
    started_at          timestamptz,
    completed_at        timestamptz,
    claimed_at          timestamptz,
    claimed_by          text,
    CONSTRAINT panorama_jobs_status_check CHECK (status IN ('queued', 'processing', 'done', 'error')),
    CONSTRAINT panorama_jobs_progress_check CHECK (progress >= 0 AND progress <= 100)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_panorama_jobs_session_live
    ON fyp.panorama_jobs (session_id)
    WHERE status IN ('queued', 'processing');
CREATE INDEX IF NOT EXISTS idx_panorama_jobs_claim
    ON fyp.panorama_jobs (status, created_at);

-- ---------------------------------------------------------------------------
-- fyp.panoramas — canonical processed result, one per session.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fyp.panoramas (
    panorama_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id          uuid NOT NULL UNIQUE REFERENCES fyp.capture_sessions(id) ON DELETE CASCADE,
    property_id         text NOT NULL,
    storage_path        text NOT NULL,
    format              text NOT NULL DEFAULT 'equirectangular_2_1',
    width               integer NOT NULL,
    height              integer NOT NULL,
    verification_status text NOT NULL DEFAULT 'pending',
    published_at        timestamptz,
    coverage_report     jsonb,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    reviewed_by         uuid,
    reviewed_at         timestamptz,
    review_reason       text,
    CONSTRAINT panoramas_width_check CHECK (width > 0),
    CONSTRAINT panoramas_height_check CHECK (height > 0),
    CONSTRAINT panoramas_verification_status_check CHECK (verification_status IN ('pending', 'approved', 'rejected'))
);
CREATE INDEX IF NOT EXISTS idx_panoramas_property ON fyp.panoramas (property_id);

-- ---------------------------------------------------------------------------
-- Service-role-only access. FastAPI is the only writer; mobile clients read
-- through signed URLs issued by FastAPI, never through PostgREST directly.
-- ---------------------------------------------------------------------------
DO $sec$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'capture_sessions', 'capture_frames', 'panorama_jobs', 'panoramas'
    ] LOOP
        EXECUTE format('ALTER TABLE fyp.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('REVOKE ALL ON fyp.%I FROM PUBLIC, anon, authenticated', t);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON fyp.%I TO service_role', t);
    END LOOP;
END $sec$;

NOTIFY pgrst, 'reload schema';
COMMIT;
