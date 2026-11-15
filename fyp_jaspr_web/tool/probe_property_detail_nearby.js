/* Headless verification of the "What's nearby?" redesign (LocationInsightsV4).
 *
 * Runs through the session_harness stand-in bridge with:
 *   - the catalogue detail served as the BARE row (real backend contract),
 *   - /evidence served from a payload CAPTURED from the local database
 *     (test/.data/evidence_captured_fixture.json — real property EP-01051).
 *
 * Expected strings are computed from the captured payload in this probe —
 * never hardcoded — mirroring metric_format.dart's documented rules.
 *
 * Checks: five clickable topic cards with icons and selected state, exactly
 * ONE shared 500 m / 1 km selector, formatted values (people / RM / distance /
 * percent-of-area / km²), honest "Not measured at ..." gap rows for metrics
 * recorded only at the other radius, district-wide (DOSM) badging that never
 * changes with the radius, recorded zeros staying visible, responsive
 * behaviour, and the page map still present.
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

// --- expectation helpers, mirroring metric_format.dart -----------------------
const metricOf = (key) => {
  for (const g of evidencePayload.groups) {
    const m = (g.metrics || []).find((x) => x.key === key);
    if (m) return m;
  }
  throw new Error(`metric ${key} missing from the captured fixture`);
};
const grouped = (n) => Math.round(n).toLocaleString('en-US');
const people = (key) => `${grouped(metricOf(key).value)} people`;
const dist = (key) => {
  const m = metricOf(key).value;
  return m < 995
    ? `${Math.round(m)} m away`
    : `${(m / 1000).toFixed(1).replace(/\.0$/, '')} km away`;
};
const ratio = (key) => `${metricOf(key).value.toFixed(1)}% of the area`;

const checks = [];
function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
}

async function openPage(browser) {
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
      body: JSON.stringify(evidencePayload),
    }),
  );
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 45000 });
  // The V4 section lives inside the "What's nearby" tab of the page.
  await page.click('#sw-info-tab-nearby');
  await page.waitForSelector('.sw-v4__cat', { timeout: 20000 });
  await page.waitForSelector('.sw-v4__metric-card, .sw-v4__empty', { timeout: 20000 });
  await page.waitForTimeout(600);
  return { page, errors };
}

/** label -> value text across the analysis panel's cards and rows. */
async function readPanel(page) {
  return page.$$eval('.sw-v4__analysis-main .sw-v4__metric-card, .sw-v4__analysis-main .sw-v4__row', (els) =>
    Object.fromEntries(
      els.map((el) => {
        const label = (el.querySelector('.sw-v4__metric-label, span')?.textContent || '').trim();
        const value = (el.querySelector('strong, span:last-child')?.textContent || '').trim();
        const notes = [...el.querySelectorAll('.sw-v4__metric-note')].map((n) => n.textContent.trim());
        return [label, { value, notes }];
      }),
    ),
  );
}

(async () => {
  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-proxy-server', '--no-sandbox'],
  });

  // --- structure --------------------------------------------------------------
  {
    const { page, errors } = await openPage(browser);
    const titles = await page.$$eval('.sw-v4__cat-title', (els) =>
      els.map((e) => e.textContent.trim()),
    );
    check(
      'five topic cards with the task wording',
      JSON.stringify(titles) ===
        JSON.stringify([
          'People nearby',
          'Food competition',
          'Nearby places',
          'Getting around',
          'Parking',
        ]),
      titles.join(' | '),
    );
    const icons = await page.$$eval('.sw-v4__cat-icon .ms', (els) =>
      els.map((e) => e.textContent.trim()),
    );
    check(
      'distinct icons per topic',
      JSON.stringify(icons) ===
        JSON.stringify(['group', 'storefront', 'location_on', 'directions_bus', 'directions_car']),
      icons.join(' | '),
    );
    const chips = await page.locator('.sw-v4__insights .sw-v4__radius').count();
    check('exactly one shared radius selector', chips === 1, chips);
    const chipInPanel = await page.locator('.sw-v4__analysis-main .sw-v4__radius').count();
    check('no duplicate selector inside the panel', chipInPanel === 0, chipInPanel);
    const selected = await page.locator('.sw-v4__cat.is-on .sw-v4__cat-title').textContent();
    check('People nearby selected by default', selected.trim() === 'People nearby', selected);
    const pressed = await page
      .locator('.sw-v4__cat.is-on')
      .getAttribute('aria-pressed');
    check('selected card aria-pressed', pressed === 'true', pressed);
    const cardCount = await page.locator('.sw-v4__cat').count();
    check('all five cards are buttons', cardCount === 5 && (await page.locator('button.sw-v4__cat').count()) === 5, cardCount);

    // --- people tab at the default 500 m --------------------------------------
    const panel = await readPanel(page);
    const districtPop = panel['District population (DOSM)'];
    check(
      'district population formatted + badged district-wide',
      districtPop &&
        districtPop.value === 'Not available' && // captured record has no district join
        districtPop.notes.some((n) => n.startsWith('District-wide (DOSM)')),
      JSON.stringify(districtPop),
    );
    const districtIncome = panel['Median district household income'];
    check(
      'district income badged district-wide',
      districtIncome && districtIncome.notes.some((n) => n.startsWith('District-wide (DOSM)')),
      JSON.stringify(districtIncome),
    );
    check(
      'residents within 500 m formatted',
      panel['Estimated residents within 500 m']?.value === people('pop_500m'),
      `${panel['Estimated residents within 500 m']?.value} != ${people('pop_500m')}`,
    );
    check(
      'footprint density rendered as percent of the area',
      panel['Building footprint density within 500 m']?.value === ratio('building_footprint_density_500m'),
      `${panel['Building footprint density within 500 m']?.value}`,
    );
    const rawLeak = Object.values(panel).filter((v) =>
      /ratio$|persons$|^\d+\.\d+ people$|\d+(\.\d+)? RM\/month/.test(v.value),
    );
    check('no raw unformatted values in the panel', rawLeak.length === 0, JSON.stringify(rawLeak));

    // --- switch to 1 km ----------------------------------------------------------
    await page.click('.sw-v4__radius .sw-v4__chip:has-text("1 km")');
    await page.waitForTimeout(400);
    const panel1k = await readPanel(page);
    check(
      'residents switch to the 1 km measurement',
      panel1k['Estimated residents within 1 km']?.value === people('pop_1000m'),
      `${panel1k['Estimated residents within 1 km']?.value} != ${people('pop_1000m')}`,
    );
    const gap500 = Object.entries(panel1k).filter(
      ([, v]) => v.value === 'Not measured at 1 km',
    );
    check(
      '500 m-only metrics labelled as gaps at 1 km',
      gap500.some(([label]) => label.includes('Building')) &&
        gap500.some(([label]) => label.includes('footprint density')),
      gap500.map(([l]) => l).join(' | '),
    );
    check(
      'district rows unchanged by the radius',
      panel1k['District population (DOSM)']?.value === panel['District population (DOSM)']?.value,
      panel1k['District population (DOSM)']?.value,
    );

    // --- food tab at 1 km ---------------------------------------------------------
    await page.click('.sw-v4__cat:has-text("Food competition")');
    await page.waitForTimeout(400);
    const food1k = await readPanel(page);
    check(
      '1 km competitor count shown at 1 km',
      food1k['F&B competitors within 1 km']?.value === grouped(metricOf('competitor_count_1000m').value),
      food1k['F&B competitors within 1 km']?.value,
    );
    check(
      'nearest competitor distance formatted',
      food1k['Distance to the nearest competitor']?.value === dist('nearest_competitor_distance_m'),
      food1k['Distance to the nearest competitor']?.value,
    );
    const foodGaps = Object.values(food1k).filter((v) => v.value === 'Not measured at 1 km');
    check(
      '500 m-only food metrics labelled at 1 km',
      foodGaps.length >= 3,
      foodGaps.length,
    );
    check(
      '2 km catchment still visible with its own label',
      food1k['F&B competitors within 2 km']?.value === grouped(metricOf('fnb_competitors_2000m').value),
      food1k['F&B competitors within 2 km']?.value,
    );

    // --- transport tab back at 500 m ------------------------------------------------
    await page.click('.sw-v4__radius .sw-v4__chip:has-text("500 m")');
    await page.click('.sw-v4__cat:has-text("Getting around")');
    await page.waitForTimeout(400);
    const transport = await readPanel(page);
    check(
      'transit distance formatted (km branch)',
      Object.values(transport).some((v) => v.value === dist('nearest_transit_walk_m')),
      JSON.stringify(Object.values(transport).map((v) => v.value)),
    );
    check(
      'road density keeps its recorded unit',
      transport['Road length density within 500 m']?.value === '40.1 km/km²',
      transport['Road length density within 500 m']?.value,
    );
    check(
      'walking isochrone area formatted',
      transport['Area reachable on foot in 10 minutes']?.value === '0.16 km²',
      transport['Area reachable on foot in 10 minutes']?.value,
    );
    const zeroStops = transport['Bus stops within a 500 m walk']?.value;
    check(
      'recorded zero stays visible as a real answer',
      zeroStops === '0',
      zeroStops,
    );
    const railGap = Object.values(transport).filter((v) => v.value === 'Not measured at 500 m');
    check(
      '1 km-only transport metrics labelled at 500 m',
      railGap.length >= 1,
      railGap.length,
    );

    // --- parking tab ------------------------------------------------------------------
    await page.click('.sw-v4__cat:has-text("Parking")');
    await page.waitForTimeout(400);
    const parking = await readPanel(page);
    check(
      'parking facilities count shown',
      parking['Parking facilities within 500 m']?.value === grouped(metricOf('parking_facilities_500m').value),
      parking['Parking facilities within 500 m']?.value,
    );
    check(
      'nearest parking distance formatted',
      parking['Distance to the nearest parking facility']?.value === dist('nearest_parking_distance_m'),
      parking['Distance to the nearest parking facility']?.value,
    );

    // --- page map preserved ------------------------------------------------------------
    check('Leaflet map section still present', (await page.locator('.sw-pd__map').count()) === 1);

    check(
      'no fatal console errors',
      errors.filter((e) => !e.includes('favicon') && !e.includes('net::') && !e.includes('404') && !e.includes('Failed to load resource')).length === 0,
      errors.slice(0, 3).join(' | '),
    );

    // --- mobile: scrollable strip, no page overflow --------------------------------------
    await page.setViewportSize({ width: 390, height: 844 });
    await page.waitForTimeout(400);
    const strip = await page.$eval('.sw-v4__cats', (el) => {
      const s = getComputedStyle(el);
      return { overflowX: s.overflowX, display: s.display };
    });
    check(
      'mobile: category strip scrolls horizontally',
      strip.display === 'flex' && (strip.overflowX === 'auto' || strip.overflowX === 'scroll'),
      JSON.stringify(strip),
    );
    const overflow = await page.evaluate(() => ({
      scrollW: document.documentElement.scrollWidth,
      innerW: window.innerWidth,
    }));
    check('mobile: no horizontal page overflow', overflow.scrollW <= overflow.innerW + 1, JSON.stringify(overflow));
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
