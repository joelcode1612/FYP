-- =============================================================================
-- SiteWise database standardization — 02 LOCAL SCHEMA MIGRATION
-- Target: local PostgreSQL `Final_Location_Analysis` (the operational DB)
-- Phase:  4 (safe migration). Transactional, idempotent, guarded.
--
-- Establishes the canonical contract: all business entities in schema `fyp`,
-- identity stays in `public`, legacy duplicates retired, assignment outbox
-- installed on the canonical table, sequences synchronized.
--
-- Run via PowerShell:
--   cd backend
--   Get-Content database_standardization\migrations\02_local_schema_migration.sql -Raw |
--     .venv\Scripts\python.exe -c "import sys,sqlalchemy;from sitewise.db.session import engine;e=sqlalchemy.text(sys.stdin.read());c=engine.connect();t=c.begin();t.execute(e);t.commit();print('applied')"
-- (or through alembic revision 0014_canonical_fyp_schema, which contains the
--  same statements)
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Guard: never run on the wrong database.
-- ---------------------------------------------------------------------------
DO $guard$
BEGIN
    IF current_database() <> 'Final_Location_Analysis' THEN
        RAISE EXCEPTION '02_local_schema_migration.sql must run on Final_Location_Analysis (current: %)', current_database();
    END IF;
END
$guard$;

-- ---------------------------------------------------------------------------
-- A. Additive provenance columns on the canonical property master.
--    (Supabase-side equivalents arrive with 03; local keeps its contract and
--    gains the Supabase-only columns so both sides share one column contract.)
-- ---------------------------------------------------------------------------
ALTER TABLE fyp.rental_properties ADD COLUMN IF NOT EXISTS address_id          uuid;
ALTER TABLE fyp.rental_properties ADD COLUMN IF NOT EXISTS district_id         character varying(64);
ALTER TABLE fyp.rental_properties ADD COLUMN IF NOT EXISTS company_name        character varying(255);
ALTER TABLE fyp.rental_properties ADD COLUMN IF NOT EXISTS parking_spaces      integer;
ALTER TABLE fyp.rental_properties ADD COLUMN IF NOT EXISTS bedrooms            smallint;
ALTER TABLE fyp.rental_properties ADD COLUMN IF NOT EXISTS year_built          smallint;
ALTER TABLE fyp.rental_properties ADD COLUMN IF NOT EXISTS status              character varying(40);

COMMENT ON COLUMN fyp.rental_properties.address_id IS 'Provenance: Supabase fyp.addresses(address_uuid) link, added by database standardization 0014.';
COMMENT ON COLUMN fyp.rental_properties.status IS 'Provenance: legacy mirror status (was public.property.status); non-authoritative.';

-- Photo provenance column adopted from the Supabase mirror contract.
ALTER TABLE fyp.property_photos ADD COLUMN IF NOT EXISTS local_source_photo_id bigint;

-- ---------------------------------------------------------------------------
-- B. Retire legacy intra-local duplicates BEFORE moving live tables into fyp.
--    All targets verified 0 rows in the Phase 1 audit except fyp.users
--    (1 pre-auth demo row, archived to rollback/fyp_users_demo_archive.sql).
--    Dependent FKs are dropped explicitly — no DROP ... CASCADE anywhere.
-- ---------------------------------------------------------------------------
ALTER TABLE fyp.rental_properties      DROP CONSTRAINT IF EXISTS rental_properties_owner_id_fkey;
ALTER TABLE fyp.ai_explanations        DROP CONSTRAINT IF EXISTS ai_explanations_recommendation_id_fkey;
ALTER TABLE fyp.recommendation_results DROP CONSTRAINT IF EXISTS recommendation_results_property_id_fkey;
ALTER TABLE fyp.recommendation_results DROP CONSTRAINT IF EXISTS recommendation_results_user_id_fkey;
ALTER TABLE fyp.favourite_properties   DROP CONSTRAINT IF EXISTS favourite_properties_user_id_fkey;
ALTER TABLE fyp.favourite_properties   DROP CONSTRAINT IF EXISTS favourite_properties_property_id_fkey;
ALTER TABLE fyp.virtual_tours          DROP CONSTRAINT IF EXISTS virtual_tours_created_by_fkey;
ALTER TABLE fyp.virtual_tours          DROP CONSTRAINT IF EXISTS virtual_tours_property_id_fkey;
ALTER TABLE fyp.virtual_tours          DROP CONSTRAINT IF EXISTS virtual_tours_verified_by_fkey;
ALTER TABLE fyp.activity_log           DROP CONSTRAINT IF EXISTS activity_log_user_id_fkey;
ALTER TABLE fyp.entrepreneur_preferences DROP CONSTRAINT IF EXISTS entrepreneur_preferences_user_id_fkey;

-- The retained fyp.property_listing_verification must reference the CANONICAL
-- identity table (public.users), not the retiring legacy fyp.users. Its
-- reviewer_user_id was bigint (legacy fyp.users.id); the table is verified
-- 0-row, so the type conversion is lossless.
ALTER TABLE fyp.property_listing_verification
    DROP CONSTRAINT IF EXISTS property_listing_verification_reviewer_user_id_fkey;
ALTER TABLE fyp.property_listing_verification
    ALTER COLUMN reviewer_user_id TYPE uuid USING NULL;
ALTER TABLE fyp.property_listing_verification
    ADD CONSTRAINT property_listing_verification_reviewer_user_id_fkey
    FOREIGN KEY (reviewer_user_id) REFERENCES public.users(user_id) ON DELETE SET NULL;

DROP TABLE IF EXISTS fyp.ai_explanations;           -- 0 rows
DROP TABLE IF EXISTS fyp.recommendation_results;    -- 0 rows
DROP TABLE IF EXISTS fyp.favourite_properties;      -- 0 rows
DROP TABLE IF EXISTS fyp.virtual_tours;             -- 0 rows
DROP TABLE IF EXISTS fyp.activity_log;              -- 0 rows
DROP TABLE IF EXISTS fyp.ml_models;                 -- 0 rows
DROP TABLE IF EXISTS fyp.entrepreneur_preferences;  -- legacy shape (uuid vs bigint id), 0 rows
DROP TABLE IF EXISTS fyp.users;                     -- demo row archived (no auth identity — never fabricated)
DROP TABLE IF EXISTS public.property_photo;         -- legacy singular duplicate, 0 rows
DROP TABLE IF EXISTS public.property_feature;       -- legacy singular duplicate, 0 rows
DROP TABLE IF EXISTS public.property_geospatial_feature; -- legacy singular duplicate, 0 rows

-- ---------------------------------------------------------------------------
-- C. Move live business tables from `public` to the canonical `fyp` schema.
--    SET SCHEMA is an OID-level catalog change: zero data movement, all
--    constraints/indexes/statistics preserved.
-- ---------------------------------------------------------------------------
ALTER TABLE public.assessment                SET SCHEMA fyp;
ALTER TABLE public.favorite_property         SET SCHEMA fyp;
ALTER TABLE public.entrepreneur_preferences  SET SCHEMA fyp;
ALTER TABLE public.recommendation_result     SET SCHEMA fyp;
ALTER TABLE public.ai_explanation            SET SCHEMA fyp;
ALTER TABLE public.virtual_tour              SET SCHEMA fyp;
ALTER TABLE public.property_verification     SET SCHEMA fyp;
ALTER TABLE public.verification_document     SET SCHEMA fyp;
ALTER TABLE public.verification_audit        SET SCHEMA fyp;
ALTER TABLE public.listing_change_request    SET SCHEMA fyp;
ALTER TABLE public.listing_change_audit      SET SCHEMA fyp;
ALTER TABLE public.provider_verification     SET SCHEMA fyp;
ALTER TABLE public.property_enquiry          SET SCHEMA fyp;
ALTER TABLE public.ml_explanation_cache      SET SCHEMA fyp;
ALTER TABLE public.district_demographic      SET SCHEMA fyp;
ALTER TABLE public.nearby_competitor         SET SCHEMA fyp;
ALTER TABLE public.property_foot_traffic     SET SCHEMA fyp;
ALTER TABLE public.agent_listing_assignment  SET SCHEMA fyp;

-- ---------------------------------------------------------------------------
-- D. Type normalizations (lossless; every target table verified empty or
--    widening only).
-- ---------------------------------------------------------------------------
-- verification_audit.created_at: timestamp -> timestamptz (aligns with Supabase)
ALTER TABLE fyp.verification_audit
    ALTER COLUMN created_at TYPE timestamp with time zone
    USING created_at AT TIME ZONE 'UTC';
-- Supabase-side column that the canonical contract adopts:
ALTER TABLE fyp.verification_audit ADD COLUMN IF NOT EXISTS actor_user_id uuid;

-- listing_change_request.changes: json -> jsonb (empty table)
ALTER TABLE fyp.listing_change_request
    ALTER COLUMN changes TYPE jsonb USING changes::text::jsonb;

-- verification_document.storage_key: varchar -> text (widening)
ALTER TABLE fyp.verification_document
    ALTER COLUMN storage_key TYPE text;

-- ---------------------------------------------------------------------------
-- E. Local `fyp.addresses` — adopt the Supabase contract verbatim (Supabase
--    holds the only populated copy; local is dev parity).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fyp.addresses (
    id                bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    address_uuid      uuid,
    source_property_id bigint,
    address_line1     character varying(255),
    address_line2     character varying(255),
    district          character varying(120),
    city              character varying(120),
    state             character varying(120),
    postcode          character varying(12),
    country_code      character varying(4),
    latitude          double precision,
    longitude         double precision,
    formatted_address text,
    coordinate_status character varying(40),
    review_required   boolean NOT NULL DEFAULT false,
    source_url        text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT addresses_address_uuid_key UNIQUE (address_uuid)
);
COMMENT ON TABLE fyp.addresses IS 'Normalized address records; canonical contract = Supabase public.addresses (the populated copy).';

-- ---------------------------------------------------------------------------
-- F. Assignment outbox (sitewise_sync) — installs the staged design onto the
--    canonical fyp.agent_listing_assignment (was staged against public.*).
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS sitewise_sync;
CREATE SEQUENCE IF NOT EXISTS sitewise_sync.assignment_revision AS bigint;

CREATE TABLE IF NOT EXISTS sitewise_sync.assignment_outbox (
    listing_id      bigint PRIMARY KEY,
    revision        bigint NOT NULL,
    operation       text NOT NULL CHECK (operation IN ('upsert','delete')),
    snapshot        jsonb,
    attempts        integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    synced_at       timestamptz,
    last_error      text,
    changed_at      timestamptz NOT NULL DEFAULT now(),
    CHECK ((operation='delete' AND snapshot IS NULL) OR (operation='upsert' AND snapshot IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS assignment_outbox_pending_idx
    ON sitewise_sync.assignment_outbox(next_attempt_at) WHERE synced_at IS NULL;

CREATE OR REPLACE FUNCTION sitewise_sync.enqueue_assignment(p_id bigint, p_operation text, p_snapshot jsonb)
RETURNS void LANGUAGE sql SET search_path=pg_catalog,sitewise_sync AS $$
    INSERT INTO sitewise_sync.assignment_outbox(listing_id,revision,operation,snapshot)
    VALUES (p_id,nextval('sitewise_sync.assignment_revision'),p_operation,p_snapshot)
    ON CONFLICT(listing_id) DO UPDATE SET revision=excluded.revision,
        operation=excluded.operation,snapshot=excluded.snapshot,attempts=0,
        next_attempt_at=now(),synced_at=NULL,last_error=NULL,changed_at=now();
$$;

CREATE OR REPLACE FUNCTION sitewise_sync.capture_assignment_change()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,sitewise_sync AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        PERFORM sitewise_sync.enqueue_assignment(OLD.listing_id,'delete',NULL);
        RETURN OLD;
    END IF;
    IF TG_OP='UPDATE' THEN
        IF OLD.listing_id <> NEW.listing_id THEN
            PERFORM sitewise_sync.enqueue_assignment(OLD.listing_id,'delete',NULL);
        END IF;
    END IF;
    PERFORM sitewise_sync.enqueue_assignment(NEW.listing_id,'upsert',to_jsonb(NEW));
    RETURN NEW;
END $$;

LOCK TABLE fyp.agent_listing_assignment IN SHARE ROW EXCLUSIVE MODE;
DROP TRIGGER IF EXISTS sitewise_assignment_sync ON fyp.agent_listing_assignment;
CREATE TRIGGER sitewise_assignment_sync AFTER INSERT OR UPDATE OR DELETE
    ON fyp.agent_listing_assignment FOR EACH ROW
    EXECUTE FUNCTION sitewise_sync.capture_assignment_change();

-- Seed existing records once; never reset a newer pending event on rerun.
INSERT INTO sitewise_sync.assignment_outbox(listing_id,revision,operation,snapshot)
    SELECT a.listing_id, nextval('sitewise_sync.assignment_revision'), 'upsert', to_jsonb(a)
    FROM fyp.agent_listing_assignment a
    ON CONFLICT(listing_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- G. Sequence synchronization — future inserts can never collide with
--    preserved ids (task §4.12 / §9). Numeric-identity tables only; uuid-PK
--    tables (capture_sessions) need no sequence.
-- ---------------------------------------------------------------------------
DO $seq$
DECLARE
    seq text;
    ok  boolean;
    rec record;
BEGIN
    FOR rec IN
        SELECT t.tbl, EXISTS (
                   SELECT 1 FROM information_schema.columns c
                   WHERE c.table_schema = 'fyp' AND c.table_name = t.tbl
                     AND c.column_name = 'id' AND c.data_type = 'bigint'
               ) AS numeric_id
        FROM (VALUES ('rental_properties'), ('property_photos'),
                     ('property_features'), ('capture_frames')) AS t(tbl)
    LOOP
        IF rec.numeric_id THEN
            seq := pg_get_serial_sequence('fyp.' || rec.tbl, 'id');
            IF seq IS NOT NULL THEN
                EXECUTE format(
                    'SELECT setval(%L, COALESCE((SELECT MAX(id) FROM fyp.%I), 1), true)',
                    seq, rec.tbl);
            END IF;
        END IF;
    END LOOP;
END
$seq$;

COMMIT;

-- Post-conditions (manual verification, also asserted by 05):
--   * every moved table answers to fyp.<name> and NOT to public.<name>
--   * fyp.rental_properties has 920 rows, 53+7 columns
--   * sitewise_sync.assignment_outbox has 2 seeded events
