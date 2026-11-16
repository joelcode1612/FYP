// Test-harness fixture export (see session_harness.js).
//
// The Jaspr app reads its catalog through the authenticated API, so headless
// page verification needs the rows without a Supabase session. This writes the
// same columns the API selects to git-ignored `test/.data/`, using one read-only
// SELECT. Nothing here changes what a real browser session can reach.
const fs = require('node:fs');
const path = require('node:path');
require('dotenv').config({ path: path.join(__dirname, '..', '..', 'test', '.env'), quiet: true });
const db = require('../../test/db.js');

// Mirrors `columns` in test/app-api.js — keep in step if that list changes.
// rental_rm / size_sqft are `numeric` in fyp.rental_properties: node-pg would
// return them as strings, while the FastAPI backend serialises them as JSON
// numbers — cast so the fixture matches the real payload shape.
const COLUMNS =
  'id,title,address,city,state,postcode,rental_rm::double precision AS rental_rm,' +
  'size_sqft::double precision AS size_sqft,latitude,longitude,' +
  'property_type,image_url,source_url,suitability_score,dataset_validation';

(async () => {
  // `sitewise_app.properties` was removed; the catalogue now lives in the
  // `fyp.catalogue_properties` view over `fyp.rental_properties` (the 955
  // research rows; owner-submitted listings are excluded by the view).
  const rows = await db.query(`SELECT ${COLUMNS} FROM fyp.catalogue_properties ORDER BY id`);
  const out = path.join(__dirname, '..', '..', 'test', '.data', 'jaspr_catalog_fixture.json');
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, JSON.stringify({ rows: rows.rows }));
  console.log(`wrote ${rows.rows.length} rows to ${out}`);
  await db.closePool();
})().catch(async (error) => {
  console.error(error.message || error);
  await db.closePool().catch(() => {});
  process.exit(1);
});
