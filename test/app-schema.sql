-- Application storage is separate from the existing research schemas.
CREATE SCHEMA IF NOT EXISTS sitewise_app;
CREATE TABLE IF NOT EXISTS sitewise_app.profiles (
  user_id uuid PRIMARY KEY,
  email text NOT NULL,
  display_name text NOT NULL,
  role text NOT NULL DEFAULT 'entrepreneur' CHECK (role IN ('entrepreneur','owner','admin')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS sitewise_app.properties (
  id text PRIMARY KEY,
  title text NOT NULL,
  address text NOT NULL,
  city text NOT NULL DEFAULT '',
  state text NOT NULL,
  postcode text NOT NULL DEFAULT '',
  rental_rm double precision NOT NULL CHECK (rental_rm >= 0),
  size_sqft double precision NOT NULL CHECK (size_sqft > 0),
  latitude double precision NOT NULL CHECK (latitude BETWEEN -90 AND 90),
  longitude double precision NOT NULL CHECK (longitude BETWEEN -180 AND 180),
  property_type text NOT NULL,
  image_url text,
  source_url text,
  suitability_score double precision NOT NULL CHECK (suitability_score BETWEEN 0 AND 100),
  dataset_validation text NOT NULL,
  source_workbook text NOT NULL,
  source_sheet text NOT NULL,
  source_row integer NOT NULL,
  source_data jsonb NOT NULL,
  imported_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sitewise_property_state ON sitewise_app.properties(state);
