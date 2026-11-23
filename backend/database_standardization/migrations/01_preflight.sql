-- =============================================================================
-- SiteWise database standardization — 01 PREFLIGHT (READ-ONLY)
-- Detects collisions, duplicates, orphans and ambiguous mappings BEFORE any
-- DDL runs. Fails loudly (DO blocks raise exceptions) on blocking conditions.
-- Run on BOTH databases. Read-only transaction.
-- =============================================================================

SET TRANSACTION READ ONLY;

-- ---------------------------------------------------------------------------
-- 1. Blocking preconditions
-- ---------------------------------------------------------------------------
DO $p$
DECLARE v bigint; vtext text;
BEGIN
    -- Property master exists and holds the expected population.
    IF to_regclass('fyp.rental_properties') IS NULL THEN
        RAISE EXCEPTION 'preflight: fyp.rental_properties missing';
    END IF;
    SELECT COUNT(*) INTO v FROM fyp.rental_properties;
    IF v < 916 THEN
        RAISE EXCEPTION 'preflight: property master has % rows (<916) — stop and investigate', v;
    END IF;

    -- Duplicate numeric ids / natural keys on the master.
    SELECT COUNT(*) INTO v FROM (
        SELECT id FROM fyp.rental_properties GROUP BY id HAVING COUNT(*) > 1) d;
    IF v > 0 THEN
        RAISE EXCEPTION 'preflight: % duplicate property id group(s)', v;
    END IF;
    SELECT COUNT(*) INTO v FROM (
        SELECT listing_id FROM fyp.rental_properties
        WHERE listing_id IS NOT NULL
        GROUP BY listing_id HAVING COUNT(*) > 1) d;
    IF v > 0 THEN
        RAISE EXCEPTION 'preflight: % duplicate listing_id group(s)', v;
    END IF;

    -- Orphaned soft references that would break reconciliation.
    SELECT COUNT(*) INTO v FROM fyp.rental_properties r
    WHERE r.owner_user_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM public.users u WHERE u.user_id = r.owner_user_id);
    IF v > 0 THEN
        RAISE EXCEPTION 'preflight: % properties reference missing owner_user_id', v;
    END IF;

    -- Supabase mirror state (run on Supabase; silently skipped locally).
    IF to_regclass('public.property') IS NOT NULL THEN
        SELECT COUNT(*) INTO v
        FROM public.property p
        WHERE p.user_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM public.users u WHERE u.user_id = p.user_id);
        IF v > 0 THEN
            RAISE EXCEPTION 'preflight (Supabase): % property rows reference missing users', v;
        END IF;
        SELECT COUNT(*) INTO v FROM public.property_photo ph
        WHERE NOT EXISTS (SELECT 1 FROM public.property p WHERE p.property_id = ph.property_id);
        IF v > 0 THEN
            RAISE EXCEPTION 'preflight (Supabase): % orphaned photo rows', v;
        END IF;
        -- floor_level must be castable to numeric(5,1) for the canonical contract.
        SELECT COALESCE(string_agg(DISTINCT floor_level, ', '), '') INTO vtext
        FROM public.property
        WHERE floor_level IS NOT NULL
          AND NULLIF(btrim(floor_level), '') IS NOT NULL
          AND NULLIF(btrim(floor_level), '')::text !~ '^-?[0-9]+(\.[0-9]+)?$';
        IF vtext <> '' THEN
            RAISE EXCEPTION 'preflight (Supabase): non-numeric floor_level values need review: %', vtext;
        END IF;
        -- price values must fit numeric(12,2) without rounding.
        SELECT COUNT(*) INTO v FROM public.property
        WHERE price IS NOT NULL AND price <> round(price, 2);
        IF v > 0 THEN
            RAISE EXCEPTION 'preflight (Supabase): % price values exceed 2 decimal places', v;
        END IF;
    END IF;

    RAISE NOTICE 'preflight: no blocking conditions detected';
END
$p$;

-- ---------------------------------------------------------------------------
-- 2. Informational inventory (NOTICES) — expected values from the audit:
--    local: rental_properties=920 (916+4 drafts), property_photos=5711,
--           users=128 (123 entrepreneur / 2 agent / 2 owner / 1 admin),
--           assessment=2, favorite_property=4, recommendation_result=20,
--           entrepreneur_preferences=1, agent_listing_assignment=2
--    supabase: property=916 (all status='approved'), property_photo=5711,
--           addresses=916, verification_audit=916, users=114
-- ---------------------------------------------------------------------------
DO $n$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT 'fyp.rental_properties' t, COUNT(*)::text c FROM fyp.rental_properties
        UNION ALL SELECT 'fyp.property_photos', COUNT(*)::text FROM fyp.property_photos
        UNION ALL SELECT 'public.users', COUNT(*)::text FROM public.users
        UNION ALL SELECT 'public.assessment', COUNT(*)::text FROM public.assessment
        UNION ALL SELECT 'public.favorite_property', COUNT(*)::text FROM public.favorite_property
        UNION ALL SELECT 'public.recommendation_result', COUNT(*)::text FROM public.recommendation_result
        UNION ALL SELECT 'public.entrepreneur_preferences', COUNT(*)::text FROM public.entrepreneur_preferences
        UNION ALL SELECT 'public.agent_listing_assignment', COUNT(*)::text FROM public.agent_listing_assignment
    LOOP
        RAISE NOTICE 'pre  %: %', r.t, r.c;
    END LOOP;
END
$n$;

ROLLBACK; -- read-only transaction ends without side effects
