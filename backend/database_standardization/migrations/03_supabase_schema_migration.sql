-- =============================================================================
-- SiteWise database standardization — 03 SUPABASE SCHEMA MIGRATION
-- Target: Supabase PostgreSQL (run in the Supabase SQL editor as a single
--         script, or psql with a direct DSN when one is configured).
--
-- Strategy: rename-in-place. `public.property` BECOMES `fyp.rental_properties`
-- (no second writable copy is ever created; all 916 rows, PKs, FKs and
-- dependent references survive because renames are OID-level operations).
--
-- Idempotent: every step is guarded. Dry-run first with 01_preflight.sql.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Guard
-- ---------------------------------------------------------------------------
DO $guard$
BEGIN
    IF current_database() = 'Final_Location_Analysis' THEN
        RAISE EXCEPTION '03 must run on the Supabase database, not the local operational DB';
    END IF;
    IF to_regclass('public.property') IS NULL AND to_regclass('fyp.rental_properties') IS NULL THEN
        RAISE EXCEPTION 'public.property not found — nothing to migrate';
    END IF;
END
$guard$;

CREATE SCHEMA IF NOT EXISTS fyp;

-- ---------------------------------------------------------------------------
-- 0. PostGIS (best effort — geom stays a documented local-only field if the
--    extension is unavailable on the Supabase project).
-- ---------------------------------------------------------------------------
DO $gis$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'postgis')
       AND NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis') THEN
        BEGIN
            CREATE EXTENSION IF NOT EXISTS postgis;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'PostGIS extension could not be created (%); geom documented as local-only', SQLERRM;
        END;
    END IF;
END
$gis$;

-- ---------------------------------------------------------------------------
-- 1. Type casts to the canonical contract (old names, pre-rename).
--    01_preflight guarantees castability.
-- ---------------------------------------------------------------------------
DO $casts$
BEGIN
    IF to_regclass('public.property') IS NOT NULL THEN
        ALTER TABLE public.property
            ALTER COLUMN normalized_address TYPE text USING normalized_address::text,
            ALTER COLUMN floor_level TYPE numeric(5,1)
                USING NULLIF(btrim(floor_level), '')::numeric(5,1),
            ALTER COLUMN bathroom_count TYPE numeric(4,1) USING bathroom_count::numeric(4,1),
            ALTER COLUMN unit_position TYPE text USING unit_position::text,
            ALTER COLUMN facing_direction TYPE text USING facing_direction::text,
            ALTER COLUMN price TYPE numeric(12,2) USING price::numeric(12,2),
            ALTER COLUMN built_up_area_sqft TYPE numeric(12,2) USING built_up_area_sqft::numeric(12,2),
            ALTER COLUMN land_area_sqft TYPE numeric(12,2) USING land_area_sqft::numeric(12,2),
            ALTER COLUMN frontage_ft TYPE numeric(8,2) USING frontage_ft::numeric(8,2),
            ALTER COLUMN depth_ft TYPE numeric(8,2) USING depth_ft::numeric(8,2);
    END IF;
END
$casts$;

-- ---------------------------------------------------------------------------
-- 2. Column renames on the property table (contract adoption).
-- ---------------------------------------------------------------------------
DO $ren$
BEGIN
    IF to_regclass('public.property') IS NOT NULL THEN
        ALTER TABLE public.property RENAME COLUMN property_id TO id;
        ALTER TABLE public.property RENAME COLUMN title TO name;
        ALTER TABLE public.property RENAME COLUMN normalized_address TO address;
        ALTER TABLE public.property RENAME COLUMN property_type_normalized TO property_type;
        ALTER TABLE public.property RENAME COLUMN price TO rental_price;
        ALTER TABLE public.property RENAME COLUMN built_up_area_sqft TO built_up_sqft;
        ALTER TABLE public.property RENAME COLUMN bathroom_count TO bathrooms;
        ALTER TABLE public.property RENAME COLUMN user_id TO owner_user_id;
        ALTER TABLE public.property RENAME COLUMN local_source_data TO catalogue_source_data;
    END IF;
END
$ren$;

-- ---------------------------------------------------------------------------
-- 3. Missing columns (additive; local contract + defaults, data-preserving).
-- ---------------------------------------------------------------------------
DO $cols$
BEGIN
    IF to_regclass('public.property') IS NOT NULL THEN
        ALTER TABLE public.property
            ADD COLUMN IF NOT EXISTS owner_id bigint,
            ADD COLUMN IF NOT EXISTS listing_id character varying(120),
            ADD COLUMN IF NOT EXISTS city character varying(120),
            ADD COLUMN IF NOT EXISTS state character varying(255),
            ADD COLUMN IF NOT EXISTS psf numeric(8,2),
            ADD COLUMN IF NOT EXISTS size_sqft numeric(10,2),
            ADD COLUMN IF NOT EXISTS furnishing character varying(255),
            ADD COLUMN IF NOT EXISTS availability character varying(255),
            ADD COLUMN IF NOT EXISTS is_corner_lot smallint NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS has_parking smallint NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS is_freehold smallint NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS is_fnb_suitable smallint NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS created_at timestamptz,
            ADD COLUMN IF NOT EXISTS updated_at timestamptz,
            ADD COLUMN IF NOT EXISTS floor_description text,
            ADD COLUMN IF NOT EXISTS availability_verified_at timestamptz,
            ADD COLUMN IF NOT EXISTS postcode character varying(5),
            ADD COLUMN IF NOT EXISTS address_validation_status character varying(24),
            ADD COLUMN IF NOT EXISTS address_formatted text,
            ADD COLUMN IF NOT EXISTS address_validated_at timestamptz,
            ADD COLUMN IF NOT EXISTS catalogue_id text,
            ADD COLUMN IF NOT EXISTS catalogue_image_url text,
            ADD COLUMN IF NOT EXISTS catalogue_source_url text,
            ADD COLUMN IF NOT EXISTS catalogue_suitability_score double precision,
            ADD COLUMN IF NOT EXISTS catalogue_dataset_validation text,
            ADD COLUMN IF NOT EXISTS catalogue_source_workbook text,
            ADD COLUMN IF NOT EXISTS catalogue_source_sheet text,
            ADD COLUMN IF NOT EXISTS catalogue_source_row integer,
            ADD COLUMN IF NOT EXISTS catalogue_imported_at timestamptz;

        -- created_at/updated_at: backfill from published_at, then enforce.
        UPDATE public.property SET created_at = COALESCE(published_at, now()) WHERE created_at IS NULL;
        UPDATE public.property SET updated_at = COALESCE(published_at, now()) WHERE updated_at IS NULL;
        ALTER TABLE public.property ALTER COLUMN created_at SET DEFAULT now();
        ALTER TABLE public.property ALTER COLUMN created_at SET NOT NULL;
        ALTER TABLE public.property ALTER COLUMN updated_at SET DEFAULT now();

        -- Nullability enforced only where the live data proves it safe.
        EXECUTE 'ALTER TABLE public.property ALTER COLUMN name SET NOT NULL';
        EXECUTE 'ALTER TABLE public.property ALTER COLUMN property_type SET DEFAULT ''Shop''';
    END IF;
END
$cols$;

-- geom (only when PostGIS is actually present): computed default mirrors local.
DO $geom$
BEGIN
    IF to_regclass('public.property') IS NOT NULL
       AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis') THEN
        ALTER TABLE public.property ADD COLUMN IF NOT EXISTS geom geometry(Point,4326);
        ALTER TABLE public.property ALTER COLUMN geom SET DEFAULT
            CASE WHEN latitude IS NOT NULL AND longitude IS NOT NULL
                 THEN st_setsrid(st_makepoint(longitude, latitude), 4326)
                 ELSE NULL END;
        UPDATE public.property
           SET geom = CASE WHEN latitude IS NOT NULL AND longitude IS NOT NULL
                           THEN st_setsrid(st_makepoint(longitude, latitude), 4326)
                           ELSE NULL END
         WHERE geom IS NULL AND latitude IS NOT NULL AND longitude IS NOT NULL;
    END IF;
END
$geom$;

-- ---------------------------------------------------------------------------
-- 4. addresses + cross-reference + owner FK
-- ---------------------------------------------------------------------------
DO $adr$
BEGIN
    IF to_regclass('public.addresses') IS NOT NULL THEN
        ALTER TABLE public.addresses SET SCHEMA fyp;
    END IF;
END
$adr$;

DO $adrk$
BEGIN
    IF to_regclass('fyp.addresses') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'addresses_address_uuid_key'
                       AND conrelid = 'fyp.addresses'::regclass) THEN
        ALTER TABLE fyp.addresses ADD CONSTRAINT addresses_address_uuid_key UNIQUE (address_uuid);
    END IF;
END
$adrk$;

-- owner FK on the (renamed) owner_user_id column
DO $ownfk$
BEGIN
    IF to_regclass('public.property') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_constraint
                       WHERE conname = 'rental_properties_owner_user_id_fkey') THEN
        ALTER TABLE public.property
            ADD CONSTRAINT rental_properties_owner_user_id_fkey
            FOREIGN KEY (owner_user_id) REFERENCES public.users(user_id) ON DELETE SET NULL;
    END IF;
END
$ownfk$;

-- ---------------------------------------------------------------------------
-- 5. Move the property master into fyp and adopt its canonical name.
--    (Dependent FKs — property_photo, addresses, verification_audit,
--     pano_listing_links, assignment tables — follow automatically.)
-- ---------------------------------------------------------------------------
DO $mv$
BEGIN
    IF to_regclass('public.property') IS NOT NULL THEN
        ALTER TABLE public.property SET SCHEMA fyp;
        ALTER TABLE fyp.property RENAME TO rental_properties;
        ALTER INDEX IF EXISTS fyp.property_pkey RENAME TO rental_properties_pkey;
        -- Sequence sync: future inserts can never collide with preserved ids.
        IF pg_get_serial_sequence('fyp.rental_properties','id') IS NOT NULL THEN
            PERFORM setval(pg_get_serial_sequence('fyp.rental_properties','id'),
                           (SELECT MAX(id) FROM fyp.rental_properties), true);
        END IF;
    END IF;
END
$mv$;

-- ---------------------------------------------------------------------------
-- 6. Photos
-- ---------------------------------------------------------------------------
DO $ph$
BEGIN
    IF to_regclass('public.property_photo') IS NOT NULL THEN
        ALTER TABLE public.property_photo RENAME COLUMN photo_id TO id;
        ALTER TABLE public.property_photo SET SCHEMA fyp;
        ALTER TABLE fyp.property_photo RENAME TO property_photos;
        IF pg_get_serial_sequence('fyp.property_photos','id') IS NOT NULL THEN
            PERFORM setval(pg_get_serial_sequence('fyp.property_photos','id'),
                           (SELECT MAX(id) FROM fyp.property_photos), true);
        END IF;
    END IF;
END
$ph$;

-- ---------------------------------------------------------------------------
-- 7. Empty mirrors / workflow tables -> fyp
-- ---------------------------------------------------------------------------
DO $mv2$
DECLARE v bigint;
BEGIN
    -- property_features: Supabase copy lacks the canonical `id` PK; verified
    -- empty, so recreate under the exact contract.
    IF to_regclass('public.property_features') IS NOT NULL THEN
        SELECT COUNT(*) INTO v FROM public.property_features;
        IF v <> 0 THEN
            RAISE EXCEPTION 'public.property_features unexpectedly has % rows; reconcile before migrating', v;
        END IF;
        DROP TABLE public.property_features;
    END IF;
    CREATE TABLE IF NOT EXISTS fyp.property_features (
        id                bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
        property_id       bigint NOT NULL REFERENCES fyp.rental_properties(id) ON DELETE CASCADE,
        suitable_for      text,
        nearby_landmarks  text,
        amenities         jsonb,
        remarks           text,
        created_at        timestamptz NOT NULL DEFAULT now()
    );

    IF to_regclass('public.verification_audit') IS NOT NULL THEN
        ALTER TABLE public.verification_audit SET SCHEMA fyp;
    END IF;
    IF to_regclass('public.verification_document') IS NOT NULL THEN
        ALTER TABLE public.verification_document SET SCHEMA fyp;
    END IF;
    IF to_regclass('public.property_verification') IS NOT NULL THEN
        ALTER TABLE public.property_verification SET SCHEMA fyp;
    END IF;
    IF to_regclass('public.listing_change_request') IS NOT NULL THEN
        ALTER TABLE public.listing_change_request SET SCHEMA fyp;
    END IF;
    IF to_regclass('public.listing_change_audit') IS NOT NULL THEN
        ALTER TABLE public.listing_change_audit SET SCHEMA fyp;
    END IF;
    IF to_regclass('public.favorite_property') IS NOT NULL THEN
        ALTER TABLE public.favorite_property
            ALTER COLUMN property_id TYPE text USING property_id::text;  -- canonical: catalogue refs allowed
        ALTER TABLE public.favorite_property SET SCHEMA fyp;
    END IF;
    IF to_regclass('public.agent_listing_assignment') IS NOT NULL THEN
        ALTER TABLE public.agent_listing_assignment SET SCHEMA fyp;
    END IF;
    IF to_regclass('public.property_source_mapping') IS NOT NULL THEN
        ALTER TABLE public.property_source_mapping SET SCHEMA fyp;
    END IF;

    -- Local-only research artifact: drop the empty Supabase mirror.
    IF to_regclass('public.property_geospatial_features') IS NOT NULL THEN
        SELECT COUNT(*) INTO v FROM public.property_geospatial_features;
        IF v <> 0 THEN
            RAISE EXCEPTION 'public.property_geospatial_features has % rows; investigate before dropping', v;
        END IF;
        DROP TABLE public.property_geospatial_features;
    END IF;
END
$mv2$;

-- ---------------------------------------------------------------------------
-- 8. address cross-reference backfill + FK (relationships phase, structural
--    part is safe here because the FK is on a nullable column)
-- ---------------------------------------------------------------------------
DO $xref$
BEGIN
    IF to_regclass('fyp.addresses') IS NOT NULL
       AND to_regclass('fyp.rental_properties') IS NOT NULL THEN
        UPDATE fyp.rental_properties r
           SET address_id = a.address_uuid
          FROM fyp.addresses a
         WHERE a.source_property_id = r.id AND r.address_id IS NULL;
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                       WHERE conname = 'rental_properties_address_id_fkey') THEN
            ALTER TABLE fyp.rental_properties
                ADD CONSTRAINT rental_properties_address_id_fkey
                FOREIGN KEY (address_id) REFERENCES fyp.addresses(address_uuid)
                ON DELETE SET NULL;
        END IF;
    END IF;
END
$xref$;

-- ---------------------------------------------------------------------------
-- 9. Supabase security model: fyp is backend/service_role-only.
--    anon/authenticated get nothing (new schema = locked by default; explicit
--    revokes are defense in depth). RLS enabled everywhere (service_role
--    bypasses RLS; clients cannot reach the schema at all).
-- ---------------------------------------------------------------------------
DO $sec$
DECLARE t record;
BEGIN
    GRANT USAGE ON SCHEMA fyp TO service_role;
    ALTER DEFAULT PRIVILEGES IN SCHEMA fyp REVOKE ALL ON TABLES FROM PUBLIC;
    FOR t IN
        SELECT c.relname FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'fyp' AND c.relkind = 'r'
    LOOP
        EXECUTE format('REVOKE ALL ON fyp.%I FROM PUBLIC, anon, authenticated', t.relname);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON fyp.%I TO service_role', t.relname);
        EXECUTE format('ALTER TABLE fyp.%I ENABLE ROW LEVEL SECURITY', t.relname);
    END LOOP;
END
$sec$;

COMMIT;

-- Post-conditions (asserted by 05 / verify_database_consistency.py):
--   fyp.rental_properties = 916 rows, 60-column contract
--   fyp.property_photos   = 5711 rows
--   fyp.addresses         = 916 rows
--   fyp.verification_audit= 916 rows
--   public.property / public.property_photo / public.addresses GONE
--   assignment mirror worker uses Accept-Profile: fyp
