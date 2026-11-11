// Generate the PUBLIC CARTO basemap key for the browser from backend/.env.
// This is not a Supabase secret. CARTO requires the key in browser tile URLs.
// Never emit Supabase server keys or database credentials here.
const fs = require('fs');
const path = require('path');

const envPath = process.env.SITEWISE_MAP_ENV
  ? path.resolve(process.env.SITEWISE_MAP_ENV)
  : path.resolve(__dirname, '..', '..', 'backend', '.env');
const outputPath = path.resolve(__dirname, '..', 'web', 'map-config.js');

if (!fs.existsSync(envPath)) {
  console.error('Missing backend env file:', envPath);
  process.exit(1);
}
function readEnv(key) {
  for (const line of fs.readFileSync(envPath, 'utf8').split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (!match || match[1] !== key) continue;
    let value = match[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
    return value;
  }
  return '';
}
const key = readEnv('CARTO_BASEMAPS_KEY');
if (!key) {
  console.error('CARTO_BASEMAPS_KEY is missing from:', envPath);
  process.exit(1);
}
if (!/^cb1_[A-Za-z0-9_-]+$/.test(key)) {
  console.error('CARTO_BASEMAPS_KEY does not look like a CARTO Basemaps key.');
  process.exit(1);
}
fs.writeFileSync(outputPath,
  '/* Generated public CARTO Basemaps configuration. Do not commit. */\n' +
  'window.SITEWISE_MAP_CONFIG = Object.freeze({cartoBasemapsKey:' +
  JSON.stringify(key) + '});\n', 'utf8');
console.log('Generated web/map-config.js (public browser key; value not printed).');
