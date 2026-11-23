-- Execute in Supabase SQL Editor only after comparing the real schemas.
-- Explicit bridge from the operational catalogue to the legacy pano pipeline.
-- NOTE (2026-11-22): schema migration 03 folded public.property into
-- fyp.rental_properties (property_id -> id); the capture-property FK targets
-- the migrated table. The integer IDs are NOT assumed equal. No duplicate
-- panorama/job tables.
BEGIN;
CREATE TABLE IF NOT EXISTS public.pano_listing_links (
    listing_id bigint PRIMARY KEY REFERENCES fyp.rental_properties(id) ON DELETE RESTRICT,
    public_property_id bigint NOT NULL UNIQUE REFERENCES fyp.rental_properties(id) ON DELETE RESTRICT,
    linked_by uuid NOT NULL REFERENCES public.users(user_id),
    linked_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pano_listing_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pano_listing_links FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.pano_listing_links TO service_role;
-- Exactly one live published 360 tour per capture property. If existing rows
-- violate this constraint, inspect and reconcile them rather than dropping data.
CREATE UNIQUE INDEX IF NOT EXISTS pano_jobs_one_published_per_property
    ON public.pano_jobs (property_id)
    WHERE published_tour_id IS NOT NULL;
COMMIT;
