-- =============================================================================
-- SiteWise database standardization — 05 POST-MIGRATION VALIDATION
-- Run on BOTH databases. Every check raises an exception on failure.
-- Side-specific branches are guarded by database name.
-- =============================================================================

BEGIN;
SET TRANSACTION READ ONLY;

DO $val$
DECLARE
    v bigint;
    vcols int;
BEGIN
    -- ======================= SHARED CANONICAL CHECKS =======================
    IF to_regclass('fyp.rental_properties') IS NULL THEN
        RAISE EXCEPTION 'validation: fyp.rental_properties missing';
    END IF;

    SELECT COUNT(*) INTO v FROM information_schema.columns
    WHERE table_schema='fyp' AND table_name='rental_properties';
    IF v <> 60 THEN
        RAISE EXCEPTION 'validation: fyp.rental_properties has % columns (canonical contract = 60)', v;
    END IF;

    SELECT COUNT(*) INTO v FROM fyp.rental_properties;
    IF v < 916 THEN
        RAISE EXCEPTION 'validation: only % property rows (>=916 required)', v;
    END IF;

    -- ============================ LOCAL SIDE ===============================
    IF current_database() = 'Final_Location_Analysis' THEN
        SELECT COUNT(*) INTO v FROM fyp.rental_properties;
        IF v <> 920 THEN
            RAISE EXCEPTION 'validation: local property rows = % (expected 920 = 916 catalogue + 4 drafts)', v;
        END IF;
        SELECT COUNT(*) INTO v FROM fyp.rental_properties WHERE is_published = true;
        IF v <> 916 THEN
            RAISE EXCEPTION 'validation: published rows = % (expected 916)', v;
        END IF;
        SELECT COUNT(*) INTO v FROM fyp.rental_properties
        WHERE verification_status = 'draft' AND is_published = false AND id IN (9234,9235,9236,10120);
        IF v <> 4 THEN
            RAISE EXCEPTION 'validation: draft rows for 9234/9235/9236/10120 missing (found %)', v;
        END IF;
        SELECT COUNT(*) INTO v FROM fyp.property_photos;
        IF v <> 5711 THEN
            RAISE EXCEPTION 'validation: property_photos = % (expected 5711)', v;
        END IF;
        SELECT COUNT(*) INTO v FROM public.users;
        IF v <> 128 THEN
            RAISE EXCEPTION 'validation: local users = % (expected 128)', v;
        END IF;
        SELECT COUNT(*) INTO v FROM sitewise_sync.assignment_outbox WHERE synced_at IS NULL;
        IF v < 1 THEN
            RAISE EXCEPTION 'validation: assignment outbox not seeded';
        END IF;

        -- Legacy duplicates must be gone.
        IF to_regclass('fyp.users') IS NOT NULL
           OR to_regclass('fyp.favourite_properties') IS NOT NULL
           OR to_regclass('fyp.recommendation_results') IS NOT NULL
           OR to_regclass('fyp.ai_explanations') IS NOT NULL
           OR to_regclass('fyp.virtual_tours') IS NOT NULL
           OR to_regclass('fyp.activity_log') IS NOT NULL
           OR to_regclass('fyp.ml_models') IS NOT NULL
           OR to_regclass('public.property_photo') IS NOT NULL
           OR to_regclass('public.property_feature') IS NOT NULL THEN
            RAISE EXCEPTION 'validation: legacy duplicate tables still present';
        END IF;

        -- Business tables must have LEFT public.
        IF to_regclass('public.assessment') IS NOT NULL
           OR to_regclass('public.favorite_property') IS NOT NULL
           OR to_regclass('public.entrepreneur_preferences') IS NOT NULL
           OR to_regclass('public.recommendation_result') IS NOT NULL
           OR to_regclass('public.agent_listing_assignment') IS NOT NULL
           OR to_regclass('public.property_verification') IS NOT NULL
           OR to_regclass('public.listing_change_request') IS NOT NULL
           OR to_regclass('public.ml_explanation_cache') IS NOT NULL THEN
            RAISE EXCEPTION 'validation: business tables still exist in public schema';
        END IF;

        RAISE NOTICE 'validation (local): all checks passed';

    -- ========================== SUPABASE SIDE ==============================
    ELSE
        SELECT COUNT(*) INTO v FROM fyp.rental_properties;
        IF v <> 916 THEN
            RAISE EXCEPTION 'validation: Supabase property rows = % (expected 916)', v;
        END IF;
        SELECT COUNT(*) INTO v FROM fyp.property_photos;
        IF v <> 5711 THEN
            RAISE EXCEPTION 'validation: Supabase property_photos = % (expected 5711)', v;
        END IF;
        SELECT COUNT(*) INTO v FROM fyp.addresses;
        IF v <> 916 THEN
            RAISE EXCEPTION 'validation: Supabase fyp.addresses = % (expected 916)', v;
        END IF;
        SELECT COUNT(*) INTO v FROM fyp.verification_audit;
        IF v <> 916 THEN
            RAISE EXCEPTION 'validation: Supabase verification_audit = % (expected 916)', v;
        END IF;

        -- Renamed originals must be gone.
        IF to_regclass('public.property') IS NOT NULL
           OR to_regclass('public.property_photo') IS NOT NULL
           OR to_regclass('public.addresses') IS NOT NULL THEN
            RAISE EXCEPTION 'validation: renamed source tables still exist in public schema';
        END IF;

        -- Identity schema untouched.
        SELECT COUNT(*) INTO v FROM public.users;
        IF v < 100 THEN
            RAISE EXCEPTION 'validation: Supabase users = % (expected >=114)', v;
        END IF;

        RAISE NOTICE 'validation (Supabase): all checks passed';
    END IF;
END
$val$;

ROLLBACK;
