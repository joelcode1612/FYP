-- =====================================================================
-- 20261123_09_favorite_property_property_id_text.sql
-- =====================================================================
-- Why this file exists
--   ``public.favorite_property`` was restored from the ``Dss`` baseline, where
--   ``property_id`` is ``integer`` and carries a foreign key to the legacy
--   ``public.property(property_id)`` catalogue. The application does not use
--   that shape:
--
--     src/sitewise/db/models/favourite_property.py
--         property_id: str = Field(nullable=False, max_length=64)
--       "property_id holds the catalogue's text id (EP-01051, ...). It is a
--        soft reference validated at write time ... the database does not
--        enforce a foreign key into it."
--
--   Measured on the two live databases:
--
--     Dss                        property_id integer   + FK -> public.property
--     Final_Location_Analysis    property_id text      + no such FK
--
--   ``Final_Location_Analysis`` is the database ``backend/.env`` points at, so
--   it is the authoritative shape. Against the Dss shape every save fails:
--
--     psycopg2.errors.InvalidTextRepresentation:
--       invalid input syntax for type integer: "EP-02087"
--
--   This file brings the test database in line with the schema the code
--   actually runs against. It changes no application behaviour and no data
--   semantics: catalogue ids are text, and they were never integers.
--
-- Safety
--   Guarded like every file in migrations/pg18; refuses to run if the table
--   already holds rows it would have to reinterpret.
-- =====================================================================

DO $$
DECLARE
    db   text := current_database();
    port int  := inet_server_port();
    n    bigint;
    typ  text;
BEGIN
    IF db NOT LIKE 'project1\_pg18\_%' THEN
        RAISE EXCEPTION 'REFUSED: % is not a project1_pg18_* database', db;
    END IF;
    IF port <> 5544 THEN
        RAISE EXCEPTION 'REFUSED: port % is not the isolated PG18 cluster (5544)', port;
    END IF;
    IF to_regclass('public.favorite_property') IS NULL THEN
        RAISE EXCEPTION 'REFUSED: public.favorite_property is missing';
    END IF;

    SELECT format_type(a.atttypid, a.atttypmod) INTO typ
    FROM pg_attribute a
    WHERE a.attrelid = 'public.favorite_property'::regclass
      AND a.attname = 'property_id'
      AND a.attnum > 0 AND NOT a.attisdropped;

    SELECT count(*) INTO n FROM public.favorite_property;

    IF typ = 'text' THEN
        RAISE NOTICE 'favorite_property.property_id is already text; nothing to do';
        RETURN;
    END IF;

    IF n > 0 THEN
        RAISE EXCEPTION
            'REFUSED: favorite_property holds % row(s); converting integer ids to text needs a review',
            n;
    END IF;

    RAISE NOTICE 'converting favorite_property.property_id % -> text (table is empty)', typ;
END
$$;

-- The legacy FK cannot survive a type change, and the model deliberately has
-- no FK into the catalogue: catalogue ids are validated at write time.
ALTER TABLE public.favorite_property
    DROP CONSTRAINT IF EXISTS favorite_property_property_id_fkey;

ALTER TABLE public.favorite_property
    ALTER COLUMN property_id TYPE text USING property_id::text;

COMMENT ON COLUMN public.favorite_property.property_id IS
    'Catalogue text id (EP-01051 / MD-04816). Soft reference validated at write '
    'time against fyp.catalogue_properties; deliberately not a foreign key. '
    'Converted from integer by 20261123_09 to match the application model and '
    'the live Final_Location_Analysis schema.';
