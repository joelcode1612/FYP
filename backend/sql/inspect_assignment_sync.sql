-- Run on local Final_Location_Analysis AFTER the local migration.
SELECT current_database();
SELECT listing_id, revision, operation, attempts, synced_at, last_error, next_attempt_at
FROM sitewise_sync.assignment_outbox ORDER BY listing_id;
-- Source property identity (verify the relationship against Supabase before linking):
SELECT p.id, p.name, p.address, p.owner_user_id, a.agent_id
FROM fyp.rental_properties p JOIN fyp.agent_listing_assignment a ON a.listing_id=p.id
ORDER BY p.id;
