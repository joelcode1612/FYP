-- =============================================================================
-- SiteWise database standardization — 04 RELATIONSHIP RECONCILIATION
-- Run on BOTH databases (guards auto-detect the side). Validates and repairs
-- cross-entity relationships after the canonical schema move.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- A. Cross-reference integrity report (NOTICES; failures block in 05).
--    Soft references support both numeric ids and MD-/EP- catalogue refs by
--    design — every value must resolve to one of the two.
-- ---------------------------------------------------------------------------
DO $soft$
DECLARE
    v bigint;
    vtext text;
BEGIN
    IF to_regclass('fyp.assessment') IS NOT NULL THEN
        SELECT COALESCE(string_agg(DISTINCT property_id, ', '), '') INTO vtext
        FROM fyp.assessment
        WHERE property_id IS NOT NULL
          AND property_id !~ '^[0-9]+$'
          AND property_id NOT IN (SELECT catalogue_id FROM fyp.rental_properties WHERE catalogue_id IS NOT NULL)
          AND property_id NOT IN (SELECT sitewise_property_id FROM fyp.property_subject_links WHERE sitewise_property_id IS NOT NULL);
        IF vtext <> '' THEN
            RAISE EXCEPTION 'assessment.property_id values resolve to neither numeric id nor catalogue ref: %', vtext;
        END IF;
    END IF;

    IF to_regclass('fyp.favorite_property') IS NOT NULL THEN
        SELECT COUNT(*) INTO v FROM fyp.favorite_property f
        WHERE f.property_id ~ '^[0-9]+$'
          AND NOT EXISTS (SELECT 1 FROM fyp.rental_properties r WHERE r.id::text = f.property_id);
        IF v > 0 THEN
            RAISE EXCEPTION 'favorite_property: % numeric property_id values reference missing listings', v;
        END IF;
    END IF;

    IF to_regclass('fyp.recommendation_result') IS NOT NULL THEN
        SELECT COUNT(*) INTO v FROM fyp.recommendation_result rr
        WHERE rr.property_id ~ '^[0-9]+$'
          AND NOT EXISTS (SELECT 1 FROM fyp.rental_properties r WHERE r.id::text = rr.property_id);
        IF v > 0 THEN
            RAISE EXCEPTION 'recommendation_result: % numeric property_id values reference missing listings', v;
        END IF;
    END IF;
    RAISE NOTICE 'soft-reference integrity: OK';
END
$soft$;

-- ---------------------------------------------------------------------------
-- B. Owner / agent relationship validation (data-preserving, no invention).
-- ---------------------------------------------------------------------------
DO $own$
DECLARE v bigint;
BEGIN
    IF to_regclass('fyp.rental_properties') IS NOT NULL
       AND to_regclass('public.users') IS NOT NULL THEN
        SELECT COUNT(*) INTO v FROM fyp.rental_properties r
        WHERE r.owner_user_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM public.users u WHERE u.user_id = r.owner_user_id);
        IF v > 0 THEN
            RAISE EXCEPTION '% rental_properties rows reference missing owner_user_id — mapping ambiguous, stopping', v;
        END IF;
    END IF;
    IF to_regclass('fyp.agent_listing_assignment') IS NOT NULL
       AND to_regclass('public.users') IS NOT NULL THEN
        SELECT COUNT(*) INTO v FROM fyp.agent_listing_assignment a
        WHERE a.assigned_by_user_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM public.users u WHERE u.user_id = a.assigned_by_user_id);
        IF v > 0 THEN
            RAISE EXCEPTION '% assignment rows reference missing assigned_by_user_id', v;
        END IF;
    END IF;
    RAISE NOTICE 'owner/agent relationships: OK';
END
$own$;

-- ---------------------------------------------------------------------------
-- C. Supabase side: reset stale mirror receipts (schema moved; revisions are
--    re-seeded by the outbox trigger + worker, never fabricated).
-- ---------------------------------------------------------------------------
DO $rc$
BEGIN
    IF to_regclass('public.assignment_sync_receipts') IS NOT NULL
       AND current_database() <> 'Final_Location_Analysis' THEN
        DELETE FROM public.assignment_sync_receipts;
        RAISE NOTICE 'assignment_sync_receipts reset (will be repopulated by the worker)';
    END IF;
END
$rc$;

-- ---------------------------------------------------------------------------
-- D. Supabase side: pano_listing_links validity after the rename (FK follows
--    by OID, but verify every link still resolves).
-- ---------------------------------------------------------------------------
DO $pll$
DECLARE v bigint;
BEGIN
    IF to_regclass('public.pano_listing_links') IS NOT NULL
       AND current_database() <> 'Final_Location_Analysis' THEN
        SELECT COUNT(*) INTO v FROM public.pano_listing_links l
        WHERE NOT EXISTS (SELECT 1 FROM fyp.rental_properties r WHERE r.id = l.listing_id);
        IF v > 0 THEN
            RAISE EXCEPTION '% pano_listing_links rows reference missing listings after rename', v;
        END IF;
        RAISE NOTICE 'pano_listing_links: OK';
    END IF;
END
$pll$;

COMMIT;
