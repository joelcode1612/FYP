-- Run in Supabase SQL Editor. Verify FK before applying remote migration.
SELECT conname,pg_get_constraintdef(oid) FROM pg_constraint
WHERE conrelid='fyp.agent_listing_assignment'::regclass;
SELECT property_id,title,normalized_address,user_id FROM public.property ORDER BY property_id;
-- After remote migration:
SELECT * FROM public.pano_listing_links ORDER BY listing_id;
SELECT * FROM public.assignment_sync_receipts ORDER BY local_listing_id;
SELECT listing_id,agent_id,workflow_status,updated_at FROM fyp.agent_listing_assignment ORDER BY listing_id;
