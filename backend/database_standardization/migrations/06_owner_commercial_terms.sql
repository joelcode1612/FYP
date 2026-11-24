-- Additive owner-declared commercial rental terms.
-- Existing rows remain NULL where these values were never collected.
BEGIN;

ALTER TABLE fyp.rental_properties
    ADD COLUMN IF NOT EXISTS lease_duration_months smallint,
    ADD COLUMN IF NOT EXISTS lease_duration_negotiable boolean,
    ADD COLUMN IF NOT EXISTS available_from date,
    ADD COLUMN IF NOT EXISTS rental_deposit_myr numeric(12, 2),
    ADD COLUMN IF NOT EXISTS title_type text,
    ADD COLUMN IF NOT EXISTS landlord_fnb_permission text,
    -- Distinguishes newly owner-declared false from legacy 0 defaults.
    ADD COLUMN IF NOT EXISTS parking_owner_declared boolean;

-- NULL represents an owner who selected "Not sure". Preserve historical 0/1.
ALTER TABLE fyp.rental_properties
    ALTER COLUMN has_parking DROP NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'fyp.rental_properties'::regclass
          AND conname = 'rental_properties_lease_duration_positive'
    ) THEN
        ALTER TABLE fyp.rental_properties
            ADD CONSTRAINT rental_properties_lease_duration_positive
            CHECK (lease_duration_months IS NULL OR lease_duration_months > 0);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'fyp.rental_properties'::regclass
          AND conname = 'rental_properties_rental_deposit_nonnegative'
    ) THEN
        ALTER TABLE fyp.rental_properties
            ADD CONSTRAINT rental_properties_rental_deposit_nonnegative
            CHECK (rental_deposit_myr IS NULL OR rental_deposit_myr >= 0);
    END IF;
END $$;

COMMIT;
