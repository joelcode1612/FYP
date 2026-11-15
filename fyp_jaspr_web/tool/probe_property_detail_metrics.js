/* Headless verification of the REAL AREA INFORMATION quick facts formatting
 * (Property Detail page, "What matters for your business" tiles).
 *
 * Runs through the session_harness stand-in bridge with:
 *   - the catalogue detail served as the BARE row (real backend contract),
 *   - /evidence served from a payload CAPTURED from the local database
 *     (test/.data/evidence_captured_fixture.json — real property EP-01051).
 * Expected strings are computed from those payloads in this probe, never
 * hardcoded, so the check is "the UI formats the backend's real numbers the
 * way metric_format.dart documents".
 *
 * Second pass: a sparse evidence payload (every tile metric unavailable)
 * must render "Not available" — never 0, NaN or null.
 */
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1243/chrome-win64/chrome.exe';
const BASE = 'http://127.0.0.1:8090';
const PROPERTY_ID = 'EP-01051';
const URL = `${BASE}/entrepreneur/property-detail?id=${PROPERTY_ID}`;

const FIXTURE_DIR = path.join(__dirname, '..', '..', 'test', '.data');
const evidencePayload = JSON.parse(
  fs.readFileSync(path.join(FIXTURE_DIR, 'evidence_captured_fixture.json'), 'utf8'),
);
const catalogueRows = JSON.parse(
  fs.readFileSync(path.join(FIXTURE_DIR, 'jaspr_catalog_fixture.json'), 'utf8'),
).rows;
const propertyRow = catalogueRows.find((r) => r.id === PROPERTY_ID);
if (!propertyRow) throw new Error(`${PROPERTY_ID} missing from the catalog fixture`);

// --- expected strings, computed from the real payloads (mirrors metric_format.dart)
const grouped = (n) => Math.round(n).toLocaleString('en-US');
const metricOf = (key) => {
  for (const g of evidencePayload.groups) {
    const m = (g.metrics || []).find((x) => x.key === key);
    if (m) return m;
  }
  return null;
};
const expected = {
  residents: `${grouped(metricOf('pop_1000m').value)} residents`,
  transit: (() => {
    const m = metricOf('nearest_transit_walk_m').value;
    return m < 995
      ? `${Math.round(m)} m away`
      : `${(m / 1000).toFixed(1).replace(/\.0$/, '')} km away`;
  })(),
  competitors: `${grouped(metricOf('competitor_count_500m').value)} businesses`,
  shops: `${grouped(metricOf('retail_pois_1000m').value)} shops`,
  parking: `${grouped(metricOf('parking_facilities_500m').value)} facilities`,
  rental: `RM ${grouped(propertyRow.rental_rm)}/month`,
};

const checks = [];
function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
}

async function loadPage(browser, evidenceOverride) {
  const page = await browser.newPage({ viewport: { width: 1440, height: 950 } });
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
      body: JSON.stringify(evidenceOverride ?? evidencePayload),
    }),
  );
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 45000 });
  await page.waitForSelector('.sw-match__fact', { timeout: 20000 });
  await page.waitForTimeout(1200);
  return { page, errors };
}

function readTiles(page) {
  return page.$$eval('.sw-match__fact', (tiles) =>
    tiles.map((t) => ({
      label: (t.querySelector('small')?.textContent || '').trim(),
      value: (t.querySelector('strong')?.textContent || '').trim(),
    })),
  );
}

(async () => {
  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-proxy-server', '--no-sandbox'],
  });

  // --- pass 1: the captured real payload ------------------------------------
  {
    const { page, errors } = await loadPage(browser);
    const section = await page.$$eval(
      '.sw-match__insightshead .sw-match__micro, .sw-match__insightshead h3',
      (els) => els.map((e) => e.textContent.trim()),
    );
    check('section eyebrow present', section.includes('REAL AREA INFORMATION'), section.join(' | '));
    check('section heading present', section.includes('What matters for your business'));
    check('Local evidence badge present', (await page.locator('.sw-match__badge').count()) === 1);

    const tiles = await readTiles(page);
    check('six tiles rendered', tiles.length === 6, tiles.length);
    const byLabel = Object.fromEntries(tiles.map((t) => [t.label, t.value]));

    check(
      'residents label',
      'People living within 1 km' in byLabel,
      Object.keys(byLabel).join(' | '),
    );
    check('residents value', byLabel['People living within 1 km'] === expected.residents,
      `${byLabel['People living within 1 km']} != ${expected.residents}`);
    check('transit label', 'Nearest public transport' in byLabel);
    check('transit value', byLabel['Nearest public transport'] === expected.transit,
      `${byLabel['Nearest public transport']} != ${expected.transit}`);
    check('competitor label', byLabel['Food businesses within 500 m'] !== undefined);
    check('competitor value', byLabel['Food businesses within 500 m'] === expected.competitors,
      `${byLabel['Food businesses within 500 m']} != ${expected.competitors}`);
    check('shops label', 'Shops within 1 km' in byLabel);
    check('shops value', byLabel['Shops within 1 km'] === expected.shops,
      `${byLabel['Shops within 1 km']} != ${expected.shops}`);
    check('parking label', 'Parking facilities within 500 m' in byLabel);
    check('parking value', byLabel['Parking facilities within 500 m'] === expected.parking,
      `${byLabel['Parking facilities within 500 m']} != ${expected.parking}`);
    check('rental label', 'Monthly rental' in byLabel);
    check('rental value', byLabel['Monthly rental'] === expected.rental,
      `${byLabel['Monthly rental']} != ${expected.rental}`);

    const sectionText = tiles.map((t) => `${t.label} ${t.value}`).join(' ');
    check(
      'no NaN/null/undefined in the tiles',
      !/NaN|\bnull\b|undefined/.test(sectionText),
      sectionText,
    );

    // Desktop layout sanity: tiles grid two columns (matches the reference).
    const cols = await page.$eval('.sw-match__quickfacts', (el) =>
      getComputedStyle(el).gridTemplateColumns.split(' ').length,
    );
    check('desktop grid two columns', cols === 2, cols);

    check(
      'no fatal console errors',
      errors.filter((e) => !e.includes('favicon') && !e.includes('net::') && !e.includes('404') && !e.includes('Failed to load resource')).length === 0,
      errors.slice(0, 3).join(' | '),
    );

    // Mobile: no horizontal overflow with the longer formatted values.
    await page.setViewportSize({ width: 390, height: 844 });
    await page.waitForTimeout(400);
    const overflow = await page.evaluate(() => ({
      scrollW: document.documentElement.scrollWidth,
      innerW: window.innerWidth,
    }));
    check('mobile: no horizontal overflow', overflow.scrollW <= overflow.innerW + 1, JSON.stringify(overflow));
    const mobCols = await page.$eval('.sw-match__quickfacts', (el) =>
      getComputedStyle(el).gridTemplateColumns.split(' ').length,
    );
    check('mobile: tiles still fit the grid', mobCols >= 1, mobCols);
    await page.close();
  }

  // --- pass 2: sparse evidence — honest "Not available" ----------------------
  {
    const sparse = JSON.parse(JSON.stringify(evidencePayload));
    for (const g of sparse.groups) {
      for (const m of g.metrics) {
        if (
          ['pop_1000m', 'nearest_transit_walk_m', 'retail_pois_1000m', 'parking_facilities_500m'].includes(m.key) ||
          m.key.endsWith('_count_500m')
        ) {
          m.value = null;
          m.status = 'unavailable';
        }
      }
    }
    const { page } = await loadPage(browser, sparse);
    const tiles = await readTiles(page);
    const values = tiles.map((t) => t.value);
    const notAvailable = values.filter((v) => v === 'Not available').length;
    check('five unavailable tiles say Not available', notAvailable === 5, values.join(' | '));
    check(
      'rental still formatted when evidence is sparse',
      tiles[5]?.value === expected.rental,
      tiles[5]?.value,
    );
    check(
      'sparse pass shows no zero/NaN placeholders',
      !values.some((v) => v === '0' || v.includes('NaN') || v.includes('null')),
      values.join(' | '),
    );
    await page.close();
  }

  await browser.close();
  const failed = checks.filter((c) => !c.ok);
  console.log(JSON.stringify({ passed: checks.length - failed.length, total: checks.length, failed }, null, 2));
  process.exit(failed.length ? 1 : 0);
})().catch((e) => {
  console.error('PROBE_FAILED', e);
  process.exit(1);
});
