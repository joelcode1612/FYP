"use strict";

/**
 * Read-only access to the commercial property dataset.
 *
 * Keeps SQL out of the route handlers, mirroring the repository pattern the
 * Dart side already uses (`shared_logic/lib/src/domain/repositories/`). Routes
 * validate input and shape responses; this module owns the queries.
 *
 * ## Read-only by construction
 *
 * Every statement here is a `SELECT`. No migration, DDL or write of any kind
 * belongs in this file — the dataset is research data and the brief forbids
 * modifying it.
 *
 * ## Schema notes discovered by inspection
 *
 * The brief listed fourteen property fields. Eight map to real columns; six do
 * not exist in any schema of `Final_Location_Analysis`. [FIELD_MAP] records the
 * mapping and is served verbatim by `GET /api/properties/fields`, so the gap is
 * visible to a client rather than silently dropped.
 *
 * Data-quality facts that affect querying (measured, not assumed):
 *   * 227 rows total; 226 have `rental_price`, 191 `built_up_sqft`,
 *     212 `latitude`/`geom`. Filters on those columns therefore exclude rows
 *     with NULLs — which is the correct behaviour, but worth knowing when a
 *     result count looks low.
 *   * All 227 rows currently have `verification_status = 'approved'`, so
 *     filtering on it is presently a no-op.
 *   * One row has a full street address in `state`
 *     ("Jalan Puteri Bandar Puteri Puchong, …"). State matching is
 *     case-insensitive exact, so that row is only reachable by its own string.
 */

const { query } = require("./db");

/** Schema and table holding the property listings. */
const PROPERTY_TABLE = "fyp.rental_properties";

/**
 * The brief's field names mapped onto the columns that actually exist.
 *
 * `column: null` means no column by that concept was found in any schema. These
 * are reported rather than omitted, because a client asking for
 * `fnb_plausibility_class` deserves to be told it is unavailable instead of
 * receiving an object that quietly lacks it.
 */
const FIELD_MAP = [
  {
    requested: "canonical_property_id",
    column: "id",
    note: "bigint surrogate key. `listing_id` (varchar) is the external reference.",
  },
  {
    requested: "source_dataset",
    column: null,
    note: "Not present on this table. Closest elsewhere: fnb_a.overture_match.overture_source_dataset, public.combined_roads.data_source.",
  },
  {
    requested: "source_listing_id",
    column: "listing_id",
    note: "External listing reference.",
  },
  {
    requested: "normalized_listing_type",
    column: "property_type",
    note: "Free text, not a controlled vocabulary: 6 distinct values incl. 'Shop', 'Shop / Office', 'Puchong Shop'.",
  },
  {
    requested: "normalized_address",
    column: "address",
    note: "`city` and `state` are separate columns.",
  },
  { requested: "state", column: "state", note: "Exact match." },
  { requested: "latitude", column: "latitude", note: "double precision, WGS84." },
  {
    requested: "longitude",
    column: "longitude",
    note: "double precision, WGS84.",
  },
  {
    requested: "Monthly Rental Price (MYR)",
    column: "rental_price",
    note: "numeric. `psf` holds price per square foot.",
  },
  {
    requested: "Built-up Area (sq ft)",
    column: "built_up_sqft",
    note: "`size_sqft` and `land_area_sqft` also exist.",
  },
  {
    requested: "property_authenticity_status",
    column: null,
    note: "Not present in any schema. `verification_status` is the only status field on this table.",
  },
  {
    requested: "commercial_classification_status",
    column: null,
    note: "Not present. `property_type` and `is_fnb_suitable` are the nearest equivalents.",
  },
  {
    requested: "fnb_regulatory_status",
    column: null,
    note: "Not present in any schema. No licensing/regulatory field exists in this database.",
  },
  {
    requested: "validation_status",
    column: "verification_status",
    note: "Closest match. All 227 rows are currently 'approved'.",
  },
  {
    requested: "fnb_plausibility_class",
    column: null,
    note: "Not present. Closest elsewhere: fnb_a.outlet_labels_v2.fnb_classification_label / pu_label_source.",
  },
];

/**
 * Columns returned by [listProperties] and [getPropertyById].
 *
 * `bigint` and `numeric` are cast explicitly because `node-postgres` returns
 * both as **strings** by default — it refuses to guess at precision. That is
 * the safe default for a driver, but it is wrong for a JSON API: JSON has no
 * decimal type, so every number in the payload is already a float64. Returning
 * `"5500.00"` for a price would force every client to parse it back.
 *
 * The casts are lossless at these magnitudes: property ids are small integers,
 * and rental prices carry two decimal places, far inside float64's exact-integer
 * range of 2^53.
 */
const PROPERTY_COLUMNS = `
  id::int                         AS id,
  listing_id,
  name,
  property_type,
  address,
  city,
  state,
  latitude,
  longitude,
  rental_price::float8            AS rental_price,
  size_sqft::float8               AS size_sqft,
  built_up_sqft::float8           AS built_up_sqft,
  psf::float8                     AS psf,
  is_corner_lot,
  has_parking,
  is_freehold,
  is_fnb_suitable,
  verification_status,
  is_published,
  (geom IS NOT NULL)              AS has_geometry,
  created_at,
  updated_at`;

/** Hard ceiling on page size, so one request cannot pull the whole table. */
const MAX_LIMIT = 200;
const DEFAULT_LIMIT = 50;

/**
 * Coerces a query-string value to a finite number, or `undefined`.
 *
 * Query parameters arrive as strings. Anything non-numeric is treated as absent
 * rather than throwing, so a malformed optional filter degrades to "no filter"
 * instead of a 500.
 */
function optionalNumber(value) {
  if (value === undefined || value === null || value === "") return undefined;
  const n = Number(value);
  return Number.isFinite(n) ? n : undefined;
}

/** Coerces a query-string value to a trimmed string, or `undefined`. */
function optionalText(value) {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed === "" ? undefined : trimmed;
}

/** Coerces a query-string flag. Only "true"/"1" are truthy. */
function optionalFlag(value) {
  if (value === true) return true;
  if (typeof value !== "string") return false;
  const v = value.trim().toLowerCase();
  return v === "true" || v === "1";
}

/**
 * Builds the shared `WHERE` clause for property queries.
 *
 * Values are pushed onto `params` and referenced as `$n`. No user input is ever
 * concatenated into the SQL text.
 */
function buildFilters(filters) {
  const clauses = [];
  const params = [];

  const state = optionalText(filters.state);
  if (state) {
    params.push(state);
    clauses.push(`LOWER(state) = LOWER($${params.length})`);
  }

  const propertyType = optionalText(filters.propertyType);
  if (propertyType) {
    // `property_type` is free text with inconsistent casing and spacing, so a
    // substring match is more useful than equality here.
    params.push(`%${propertyType}%`);
    clauses.push(`property_type ILIKE $${params.length}`);
  }

  const minRent = optionalNumber(filters.minRent);
  if (minRent !== undefined) {
    params.push(minRent);
    clauses.push(`rental_price >= $${params.length}`);
  }

  const maxRent = optionalNumber(filters.maxRent);
  if (maxRent !== undefined) {
    params.push(maxRent);
    clauses.push(`rental_price <= $${params.length}`);
  }

  const minSize = optionalNumber(filters.minSizeSqft);
  if (minSize !== undefined) {
    params.push(minSize);
    clauses.push(`built_up_sqft >= $${params.length}`);
  }

  const maxSize = optionalNumber(filters.maxSizeSqft);
  if (maxSize !== undefined) {
    params.push(maxSize);
    clauses.push(`built_up_sqft <= $${params.length}`);
  }

  if (optionalFlag(filters.fnbSuitableOnly)) {
    clauses.push("is_fnb_suitable = 1");
  }

  if (optionalFlag(filters.hasCoordinatesOnly)) {
    clauses.push("latitude IS NOT NULL AND longitude IS NOT NULL");
  }

  // Listings are only public once approved and published. Both conditions are
  // applied together so an unpublished row can never leak through a filter.
  if (!optionalFlag(filters.includeUnpublished)) {
    clauses.push("is_published = true");
    clauses.push("verification_status = 'approved'");
  }

  return {
    where: clauses.length ? `WHERE ${clauses.join(" AND ")}` : "",
    params,
  };
}

/**
 * Lists properties matching [filters], with pagination.
 *
 * Returns `{ total, limit, offset, items }`. `total` is the full match count,
 * so a client can paginate without guessing.
 */
async function listProperties(filters = {}) {
  const { where, params } = buildFilters(filters);

  const limit = Math.min(
    Math.max(optionalNumber(filters.limit) ?? DEFAULT_LIMIT, 1),
    MAX_LIMIT,
  );
  const offset = Math.max(optionalNumber(filters.offset) ?? 0, 0);

  // Count and page share the same WHERE and params, so the total can never
  // disagree with the rows returned.
  const countResult = await query(
    `SELECT count(*)::int AS total FROM ${PROPERTY_TABLE} ${where}`,
    params,
  );

  const rowsResult = await query(
    `SELECT ${PROPERTY_COLUMNS}
       FROM ${PROPERTY_TABLE}
       ${where}
      ORDER BY id
      LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, limit, offset],
  );

  return {
    total: countResult.rows[0].total,
    limit,
    offset,
    items: rowsResult.rows,
  };
}

/**
 * Fetches one property by its `id`.
 *
 * Returns `null` when no row matches, so the route can answer 404 without
 * treating "absent" as an error.
 */
async function getPropertyById(id) {
  const numericId = Number(id);
  if (!Number.isInteger(numericId)) return null;

  const { rows } = await query(
    `SELECT ${PROPERTY_COLUMNS}
       FROM ${PROPERTY_TABLE}
      WHERE id = $1`,
    [numericId],
  );

  return rows[0] ?? null;
}

/**
 * Aggregate summary of the dataset.
 *
 * Read-only. Useful as a smoke test that the table is reachable and populated,
 * and as the basis for a coverage panel later.
 */
async function propertyStats() {
  const { rows } = await query(
    `SELECT
       count(*)::int                                    AS total,
       count(rental_price)::int                         AS with_rental_price,
       count(built_up_sqft)::int                        AS with_built_up_area,
       count(latitude)::int                             AS with_coordinates,
       count(geom)::int                                 AS with_geometry,
       count(*) FILTER (WHERE is_fnb_suitable = 1)::int AS fnb_suitable,
       count(DISTINCT state)::int                       AS distinct_states,
       min(rental_price)::float8                        AS min_rental_price,
       max(rental_price)::float8                        AS max_rental_price,
       round(avg(rental_price)::numeric, 2)::float8     AS avg_rental_price
     FROM ${PROPERTY_TABLE}`,
  );

  const states = await query(
    `SELECT state, count(*)::int AS count
       FROM ${PROPERTY_TABLE}
      WHERE state IS NOT NULL
      GROUP BY state
      ORDER BY count DESC, state`,
  );

  return { ...rows[0], byState: states.rows };
}

module.exports = {
  FIELD_MAP,
  PROPERTY_TABLE,
  MAX_LIMIT,
  DEFAULT_LIMIT,
  listProperties,
  getPropertyById,
  propertyStats,
};
