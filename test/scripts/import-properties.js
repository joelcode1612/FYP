"use strict";
const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');
require('dotenv').config({ path: path.join(__dirname, '../.env'), quiet: true });

async function main() {
  const rows = JSON.parse(fs.readFileSync(process.argv[2] || path.join(__dirname, '../.data/properties.json'), 'utf8'));
  if (!Array.isArray(rows) || !rows.length || new Set(rows.map(r => r.id)).size !== rows.length) throw new Error('Invalid import rows');
  const pool = new Pool({ connectionTimeoutMillis: 5000 });
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(fs.readFileSync(path.join(__dirname, '../app-schema.sql'), 'utf8'));
    for (let start = 0; start < rows.length; start += 100) {
      await client.query(`INSERT INTO sitewise_app.properties
        (id,title,address,city,state,postcode,rental_rm,size_sqft,latitude,longitude,property_type,
         image_url,source_url,suitability_score,dataset_validation,source_workbook,source_sheet,source_row,source_data)
        SELECT id,title,address,city,state,postcode,rental_rm,size_sqft,latitude,longitude,property_type,
          image_url,source_url,suitability_score,dataset_validation,source_workbook,source_sheet,source_row,source_data
        FROM jsonb_to_recordset($1::jsonb) AS x(id text,title text,address text,city text,state text,postcode text,
          rental_rm float8,size_sqft float8,latitude float8,longitude float8,property_type text,image_url text,
          source_url text,suitability_score float8,dataset_validation text,source_workbook text,source_sheet text,
          source_row int,source_data jsonb)
        ON CONFLICT (id) DO UPDATE SET title=EXCLUDED.title,address=EXCLUDED.address,state=EXCLUDED.state,
          rental_rm=EXCLUDED.rental_rm,size_sqft=EXCLUDED.size_sqft,latitude=EXCLUDED.latitude,longitude=EXCLUDED.longitude,
          property_type=EXCLUDED.property_type,image_url=EXCLUDED.image_url,source_url=EXCLUDED.source_url,
          suitability_score=EXCLUDED.suitability_score,dataset_validation=EXCLUDED.dataset_validation,
          source_workbook=EXCLUDED.source_workbook,source_sheet=EXCLUDED.source_sheet,source_row=EXCLUDED.source_row,
          source_data=EXCLUDED.source_data,imported_at=now()`, [JSON.stringify(rows.slice(start, start + 100))]);
    }
    const count = await client.query('SELECT count(*)::int AS properties, count(image_url)::int AS images FROM sitewise_app.properties');
    await client.query('COMMIT');
    console.log(JSON.stringify({ imported: rows.length, stored: count.rows[0] }));
  } catch (error) {
    await client.query('ROLLBACK');
    console.error('Property import rolled back:', error.code || error.message);
    process.exitCode = 1;
  } finally {
    client.release();
    await pool.end();
  }
}
main().catch(error => { console.error('Import failed:', error.code || error.message); process.exitCode = 1; });
