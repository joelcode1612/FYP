"use strict";

/**
 * Sitewise backend — Express 4.
 *
 * Extends the existing test-map server rather than replacing it. The three CSV
 * endpoints it already served are unchanged and still work exactly as before;
 * the PostgreSQL layer is added alongside them.
 *
 * ## Endpoints
 *
 * Pre-existing (CSV-backed, unchanged):
 *   GET /api/businesses
 *   GET /api/businesses/filter?minRating=&minReviews=
 *   GET /api/businesses/nearby?lat=&lng=&radius=
 *
 * Added (PostgreSQL-backed, read-only):
 *   GET /api/health/database          connectivity probe, no secrets
 *   GET /api/db/schema                tables and columns
 *   GET /api/properties/fields        brief-field → column mapping
 *   GET /api/properties/stats         dataset summary
 *   GET /api/properties               filtered, paginated retrieval
 *   GET /api/properties/:id           single property
 *
 * ## Response shape
 *
 * The new database endpoints use an envelope:
 *     success  { "ok": true,  "data": …, "meta": … }
 *     failure  { "ok": false, "error": { "code": …, "message": … } }
 *
 * The pre-existing CSV endpoints deliberately keep their original bare-array
 * shape. Changing them would break any client already consuming them, and the
 * brief requires existing behaviour to be preserved.
 *
 * ## Credentials
 *
 * No credential ever reaches a response. `db.js` maps driver errors onto fixed,
 * generic messages before they are serialised, because a raw `pg` error can
 * contain the host, role and database name.
 *
 * Run from this directory:  npm start   (see package.json)
 */

// Loads test/.env into process.env before db.js reads any configuration.
// Values already present in the real environment take precedence, which is the
// conventional behaviour and what a container deployment would expect.
require("dotenv").config();

const path = require("path");
const express = require("express");
const cors = require("cors");
const csv = require("csv-parser");
const fs = require("fs");

const db = require("./db");
const properties = require("./properties");

const app = express();

const PORT = Number(process.env.PORT) || 3000;

// Resolved against this file rather than the working directory, so the server
// works whether it is started from test/ or from the repository root.
const DATA_DIR = path.join(__dirname, "data");
const PUBLIC_DIR = path.join(__dirname, "public");
const BUSINESSES_CSV = path.join(DATA_DIR, "businesses.csv");

app.use(cors());
app.use(express.json());
app.use(express.static(PUBLIC_DIR));

/* ==========================================================================
   CSV-backed routes — pre-existing, behaviour unchanged
   ========================================================================== */

let businesses = [];

function loadCSV() {
  businesses = [];

  fs.createReadStream(BUSINESSES_CSV)
    .pipe(csv())
    .on("data", (row) => {
      businesses.push(row);
    })
    .on("end", () => {
      console.log(`Loaded ${businesses.length} businesses`);
    })
    .on("error", (err) => {
      // Previously an unhandled stream error would crash the process. The
      // PostgreSQL endpoints do not depend on this file, so log and carry on.
      console.error(`Could not read ${BUSINESSES_CSV}: ${err.message}`);
    });
}

loadCSV();

app.get("/api/businesses", (req, res) => {
  res.json(businesses);
});

/**
 * CSV column names, which are not the ones this route originally looked for.
 *
 * The source file's header row is:
 *   Keyword,Title,Average Rating,Reviews,Address,…,Latitude,Longitude,…
 *
 * The original code read `b.rating || b.Rating`, neither of which exists, so
 * `parseFloat(undefined || undefined || 0)` was always `0` and the route
 * returned an empty array for every `minRating > 0`. `Reviews` did match, so
 * only the rating column was broken. Both names are now read from the header
 * that is actually present.
 *
 * Behaviour change, flagged deliberately: this route previously always
 * returned `[]` for a positive `minRating`. It now returns real matches.
 */
const CSV_RATING_COLUMNS = ["Average Rating", "rating", "Rating"];
const CSV_REVIEW_COLUMNS = ["Reviews", "review_count"];

/** Reads the first present, non-empty value from a row for the given keys. */
function firstValue(row, keys) {
  for (const key of keys) {
    if (row[key] !== undefined && row[key] !== "") return row[key];
  }
  return undefined;
}

app.get("/api/businesses/filter", (req, res) => {
  const minRating = Number(req.query.minRating || 0);
  const minReviews = Number(req.query.minReviews || 0);

  const result = businesses.filter((b) => {
    const rating = parseFloat(firstValue(b, CSV_RATING_COLUMNS) ?? 0) || 0;
    const reviews = parseInt(firstValue(b, CSV_REVIEW_COLUMNS) ?? 0, 10) || 0;
    return rating >= minRating && reviews >= minReviews;
  });

  res.json(result);
});

app.get("/api/businesses/nearby", (req, res) => {
  const lat = Number(req.query.lat);
  const lng = Number(req.query.lng);
  const radius = Number(req.query.radius || 1000);

  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return res.status(400).json({
      ok: false,
      error: {
        code: "INVALID_COORDINATES",
        message: "Query parameters 'lat' and 'lng' must be finite numbers.",
      },
    });
  }

  const nearby = [];

  businesses.forEach((b) => {
    const businessLat = parseFloat(b.latitude || b.Latitude);
    const businessLng = parseFloat(b.longitude || b.Longitude);

    if (isNaN(businessLat) || isNaN(businessLng)) {
      return;
    }

    const distance = haversine(lat, lng, businessLat, businessLng);

    if (distance <= radius) {
      nearby.push({ ...b, distance });
    }
  });

  res.json({ competitors: nearby.length, businesses: nearby });
});

function haversine(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLon = ((lon2 - lon1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos((lat1 * Math.PI) / 180) *
      Math.cos((lat2 * Math.PI) / 180) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

/* ==========================================================================
   PostgreSQL routes
   ========================================================================== */

/**
 * Wraps an async handler so a rejected promise reaches Express's error
 * middleware instead of becoming an unhandled rejection.
 */
function route(handler) {
  return (req, res, next) => Promise.resolve(handler(req, res, next)).catch(next);
}

/** Consistent success envelope. */
function ok(res, data, meta) {
  const body = { ok: true, data };
  if (meta !== undefined) body.meta = meta;
  return res.json(body);
}

/**
 * Liveness and connectivity probe.
 *
 * Deliberately reports no configuration: the database name and role are the
 * server's own answers about itself, which is what an operator needs to confirm
 * they reached the intended instance. Host, port and credentials are never
 * included.
 */
app.get(
  "/api/health/database",
  route(async (req, res) => {
    const health = await db.healthCheck();
    return ok(res, health);
  }),
);

/** Lists application schemas, tables and their columns. */
app.get(
  "/api/db/schema",
  route(async (req, res) => {
    const tables = await db.introspectSchema();
    return ok(res, tables, {
      tableCount: tables.length,
      columnCount: tables.reduce((n, t) => n + t.columns.length, 0),
    });
  }),
);

/**
 * The brief's field names mapped onto the columns that actually exist.
 *
 * Exposed as an endpoint so a client can discover that, for example,
 * `fnb_plausibility_class` is unavailable, instead of silently receiving a
 * record without it.
 */
app.get("/api/properties/fields", (req, res) => {
  const mapped = properties.FIELD_MAP.filter((f) => f.column !== null);
  const unmapped = properties.FIELD_MAP.filter((f) => f.column === null);
  return ok(
    res,
    properties.FIELD_MAP,
    {
      requestedCount: properties.FIELD_MAP.length,
      mappedCount: mapped.length,
      unavailableCount: unmapped.length,
      unavailable: unmapped.map((f) => f.requested),
    },
  );
});

/** Dataset summary — row counts, coverage and rental range. */
app.get(
  "/api/properties/stats",
  route(async (req, res) => {
    return ok(res, await properties.propertyStats());
  }),
);

/**
 * Filtered, paginated property retrieval.
 *
 * Supported query parameters (all optional):
 *   state, propertyType, minRent, maxRent, minSizeSqft, maxSizeSqft,
 *   fnbSuitableOnly, hasCoordinatesOnly, includeUnpublished, limit, offset
 *
 * Every value is passed to PostgreSQL as a bound parameter; none is
 * interpolated into the SQL text.
 */
app.get(
  "/api/properties",
  route(async (req, res) => {
    const result = await properties.listProperties(req.query);
    return ok(res, result.items, {
      total: result.total,
      limit: result.limit,
      offset: result.offset,
      returned: result.items.length,
    });
  }),
);

/**
 * A single property by id.
 *
 * Declared after `/fields` and `/stats` so those literal paths win — Express
 * matches in declaration order and `:id` would otherwise swallow them.
 */
app.get(
  "/api/properties/:id",
  route(async (req, res) => {
    const property = await properties.getPropertyById(req.params.id);
    if (property === null) {
      return res.status(404).json({
        ok: false,
        error: {
          code: "PROPERTY_NOT_FOUND",
          message: `No property with id "${req.params.id}".`,
        },
      });
    }
    return ok(res, property);
  }),
);

/* ==========================================================================
   Error handling
   ========================================================================== */

// 404 for unknown API paths. Registered after the routes above.
app.use("/api", (req, res) => {
  res.status(404).json({
    ok: false,
    error: { code: "NOT_FOUND", message: `No route for ${req.method} ${req.originalUrl}.` },
  });
});

// Central error handler. Express identifies this by its four-argument
// signature; it must stay last.
//
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  if (err instanceof db.DatabaseError) {
    // `err.reason` is already a fixed, non-sensitive string chosen in db.js.
    // The driver's own message is never forwarded.
    console.error(`[api] database error ${err.code}: ${err.reason}`);
    return res
      .status(err.status)
      .json({ ok: false, error: { code: err.code, message: err.reason } });
  }

  console.error(`[api] unhandled error: ${err && err.message}`);
  return res.status(500).json({
    ok: false,
    error: { code: "INTERNAL_ERROR", message: "An unexpected error occurred." },
  });
});

/* ==========================================================================
   Startup and shutdown
   ========================================================================== */

const server = app.listen(PORT, () => {
  console.log(`Server running at http://localhost:${PORT}`);
  console.log(
    `Database endpoints: /api/health/database, /api/properties, /api/db/schema`,
  );
});

/**
 * Releases the pool and stops accepting connections.
 *
 * Without this, a Ctrl+C leaves the pool's sockets open until the process is
 * force-killed, which is how stray `node` processes accumulate.
 */
function shutdown(signal) {
  console.log(`\nReceived ${signal}. Shutting down.`);
  server.close(() => {
    db.closePool()
      .then(() => process.exit(0))
      .catch(() => process.exit(1));
  });
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));

module.exports = app;
