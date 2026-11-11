-- ---------------------------------------------------------------------------
-- SiteWise — ownership bridge for owner-submitted listings
--
-- WHY: fyp.rental_properties.owner_id is int8 -> fyp.users.id (legacy demo
-- accounts). The application's identity is the Supabase UUID. Without a UUID
-- owner column an authenticated owner submission cannot record its owner.
--
-- WHAT: one nullable additive column + index. No data is modified, no
-- existing column is renamed or dropped, no constraint is relaxed.
-- Legacy rows keep owner_user_id = NULL; owner_id remains untouched.
--
-- REVERSIBLE: ALTER TABLE fyp.rental_properties DROP COLUMN IF EXISTS owner_user_id;
-- ---------------------------------------------------------------------------
ALTER TABLE fyp.rental_properties
    ADD COLUMN IF NOT EXISTS owner_user_id uuid;

CREATE INDEX IF NOT EXISTS rental_properties_owner_user_idx
    ON fyp.rental_properties (owner_user_id);
