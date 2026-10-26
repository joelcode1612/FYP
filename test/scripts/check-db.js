"use strict";

/**
 * Standalone database verification.
 *
 * Exercises the same modules the HTTP routes use, without starting a server.
 * Useful as a smoke test after a config change, and as the check to run when
 * the API reports a database problem but the cause is unclear.
 *
 * Read-only: every statement it issues is a SELECT. It never writes, migrates
 * or deletes.
 *
 * Usage:  npm run check-db        (from test/)
 *         node scripts/check-db.js
 *
 * Exit code 0 means every check passed; 1 means at least one failed.
 */

require("dotenv").config({ path: require("path").join(__dirname, "..", ".env") });

const db = require("../db");
const properties = require("../properties");

let failures = 0;

function pass(label, detail) {
  console.log(`  PASS  ${label}${detail ? ` — ${detail}` : ""}`);
}

function fail(label, detail) {
  failures += 1;
  console.log(`  FAIL  ${label}${detail ? ` — ${detail}` : ""}`);
}

function section(title) {
  console.log(`\n${title}`);
}

async function main() {
  console.log("Sitewise database verification (read-only)");

  /* --- 1. Connectivity ------------------------------------------------ */
  section("1. Connectivity");

  let health;
  try {
    health = await db.healthCheck();
    pass("SELECT 1 round-trip", `${health.latencyMs} ms`);
    pass("database", health.database);
    pass("role", health.role);
    pass("server version", health.serverVersion);
    pass(
      "PostGIS",
      health.postgisInstalled ? "installed" : "NOT installed",
    );
  } catch (err) {
    fail("connect", err.message);
    console.log(
      "\nStopping: without a connection the remaining checks cannot run.",
    );
    process.exitCode = 1;
    return;
  }

  /* --- 2. Schema discovery -------------------------------------------- */
  section("2. Schema discovery");

  try {
    const tables = await db.introspectSchema();
    const schemas = [...new Set(tables.map((t) => t.schema))].sort();
    pass("introspection returned", `${tables.length} tables`);
    pass("schemas visible", schemas.join(", "));

    const byName = new Map(tables.map((t) => [`${t.schema}.${t.table}`, t]));
    for (const key of [
      "fyp.rental_properties",
      "fyp.property_features",
      "fyp.property_geospatial_features",
    ]) {
      const t = byName.get(key);
      if (t) pass(`${key} present`, `${t.columns.length} columns`);
      else fail(`${key} present`, "not found");
    }
  } catch (err) {
    fail("introspect schema", err.message);
  }

  /* --- 3. Property retrieval ------------------------------------------ */
  section("3. Property retrieval");

  try {
    const stats = await properties.propertyStats();
    pass("row count", `${stats.total}`);
    pass(
      "coverage",
      `rental ${stats.with_rental_price}/${stats.total}, ` +
        `built-up ${stats.with_built_up_area}/${stats.total}, ` +
        `coords ${stats.with_coordinates}/${stats.total}, ` +
        `geom ${stats.with_geometry}/${stats.total}`,
    );
    pass(
      "rental range (MYR)",
      `${stats.min_rental_price} – ${stats.max_rental_price} (avg ${stats.avg_rental_price})`,
    );
    pass("F&B-suitable rows", `${stats.fnb_suitable}`);

    if (stats.total === 0) {
      fail("dataset populated", "table exists but is empty");
    }
  } catch (err) {
    fail("property stats", err.message);
  }

  try {
    const page = await properties.listProperties({ limit: 3 });
    pass("listProperties", `${page.items.length} of ${page.total} returned`);
    if (page.items.length > 0) {
      const p = page.items[0];
      pass("first row shape", `id=${p.id} type="${p.property_type}"`);
      pass(
        "first row values",
        `rent=${p.rental_price} built=${p.built_up_sqft} ` +
          `state="${p.state}" coords=${p.latitude},${p.longitude}`,
      );
    }
  } catch (err) {
    fail("listProperties", err.message);
  }

  // Filtered retrieval — the path the recommendation module will use.
  try {
    const filtered = await properties.listProperties({
      state: "Selangor",
      maxRent: 8000,
      hasCoordinatesOnly: true,
      limit: 5,
    });
    pass(
      "filtered query (Selangor, <=RM8000, has coords)",
      `${filtered.total} match, ${filtered.items.length} returned`,
    );
  } catch (err) {
    fail("filtered query", err.message);
  }

  // Parameterisation: a quote in a value must be treated as data, not SQL.
  try {
    const injected = await properties.listProperties({
      state: "'; DROP TABLE fyp.rental_properties; --",
      limit: 1,
    });
    const stillThere = await properties.propertyStats();
    pass("parameterised input", `injection attempt matched ${injected.total} rows`);
    pass("table intact after injection attempt", `${stillThere.total} rows`);
  } catch (err) {
    fail("parameterisation check", err.message);
  }

  // Single-row fetch.
  try {
    const first = await properties.listProperties({ limit: 1 });
    if (first.items.length > 0) {
      const one = await properties.getPropertyById(first.items[0].id);
      pass("getPropertyById", one ? `id=${one.id}` : "returned null");
    }
    const missing = await properties.getPropertyById(99999999);
    pass("missing id returns null", missing === null ? "null" : "unexpected row");
  } catch (err) {
    fail("getPropertyById", err.message);
  }

  /* --- 4. Field mapping ------------------------------------------------ */
  section("4. Field mapping (brief → actual columns)");

  const mapped = properties.FIELD_MAP.filter((f) => f.column !== null);
  const unmapped = properties.FIELD_MAP.filter((f) => f.column === null);
  pass("mapped", `${mapped.length} of ${properties.FIELD_MAP.length}`);
  for (const f of mapped) {
    console.log(`          ${f.requested}  ->  ${f.column}`);
  }
  if (unmapped.length > 0) {
    console.log(`  NOTE  ${unmapped.length} requested field(s) do not exist:`);
    for (const f of unmapped) {
      console.log(`          ${f.requested}  ->  (absent)`);
    }
  }

  /* --- Result ---------------------------------------------------------- */
  console.log(
    `\n${failures === 0 ? "ALL CHECKS PASSED" : `${failures} CHECK(S) FAILED`}`,
  );
  process.exitCode = failures === 0 ? 0 : 1;
}

main()
  .catch((err) => {
    console.error(`\nUnexpected failure: ${err.message}`);
    process.exitCode = 1;
  })
  .finally(() => {
    // Always release the pool, or the process hangs on open sockets.
    db.closePool().catch(() => {});
  });
