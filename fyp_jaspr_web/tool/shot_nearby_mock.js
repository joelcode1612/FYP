/* Screenshot the redesigned property-detail page (map + insight tabs) with a
 * LIVE evidence payload captured from PostgreSQL (test/.data/evidence_live_shot.json).
 * Stand-in auth via session_harness; no backend process is contacted.
 * Usage: node tool/shot_nearby_mock.js <outdir>
 */
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = 'http://127.0.0.1:8090';
const PROPERTY_ID = 'EP-01051';
const URL = `${BASE}/entrepreneur/property-detail?id=${PROPERTY_ID}`;

const FIXTURE_DIR = path.join(__dirname, '..', '..', 'test', '.data');
const evidencePayload = JSON.parse(
  fs.readFileSync(path.join(FIXTURE_DIR, 'evidence_live_shot.json'), 'utf8'),
);
const catalogueRows = JSON.parse(
  fs.readFileSync(path.join(FIXTURE_DIR, 'jaspr_catalog_fixture.json'), 'utf8'),
).rows;
const propertyRow = catalogueRows.find((r) => r.id === PROPERTY_ID);
if (!propertyRow) throw new Error(`${PROPERTY_ID} missing from the catalog fixture`);

const outdir = process.argv[2] || path.join(FIXTURE_DIR, 'shots_nearby_mock');
fs.mkdirSync(outdir, { recursive: true });

(async () => {
  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-proxy-server', '--no-sandbox'],
  });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push('console: ' + m.text().slice(0, 200));
  });

  await installHarnessSession(page, { role: 'entrepreneur' });
  await page.route(`**/api/v1/catalog/properties/${PROPERTY_ID}`, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(propertyRow),
    }),
  );
  await page.route(`**/api/v1/catalog/properties/${PROPERTY_ID}/evidence`, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(evidencePayload),
    }),
  );

  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 45000 });
  await page.waitForSelector('.sw-pd__map', { timeout: 30000 });
  await page.waitForTimeout(2500);

  // Whole page, then the map section, then the nearby tab open.
  await page.screenshot({ path: path.join(outdir, 'page_full.png'), fullPage: true });

  await page.locator('.sw-pd__map').screenshot({ path: path.join(outdir, 'map_section.png') });

  await page.click('#sw-info-tab-nearby');
  await page.waitForSelector('.sw-viz__cards', { timeout: 20000 });
  await page.waitForTimeout(800);
  await page.locator('.sw-viz').screenshot({ path: path.join(outdir, 'nearby_tab.png') });
  await page.screenshot({ path: path.join(outdir, 'nearby_viewport.png') });

  if (errors.length) console.log('PAGE ERRORS:\n' + errors.slice(0, 10).join('\n'));
  console.log('saved to ' + outdir);
  await browser.close();
})().catch((e) => {
  console.error('FAILED: ' + e.message);
  process.exit(1);
});
