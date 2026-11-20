// Headless verification of the entrepreneur Compare flow against the BUILT
// bundle. The compare API is answered by a fixture that mirrors the LIVE
// `POST /api/v1/compare` response shape (verified against the real service),
// so what the page renders here is what the backend sends — never an invented
// contract.
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness.js');

const BASE = 'http://127.0.0.1:8096';
const CHROME = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

let passed = 0, failed = 0;
function check(name, ok, extra = '') {
  if (ok) { passed++; console.log(`PASS  ${name}`); }
  else { failed++; console.log(`FAIL  ${name}${extra ? ' — ' + extra : ''}`); }
}

// Real response shape: three catalogue rows with measurements; one metric is
// deliberately unavailable; one unresolved id carries the backend reason.
const TWO_RESOLVED = {
  data: {
    selected_count: 2,
    resolved_count: 2,
    unresolved_ids: [],
    unresolved_details: [],
    properties: [
      {
        property_id: 'MD-00510',
        title: 'Impian Prisma Intermediate Shoplot',
        city: 'Shah Alam', state: 'Selangor', postcode: '40450',
        property_type: 'Shop', image_url: null,
        panorama: { available: false, status: null, url: null },
        availability: { confirmed: true, status: 'VERIFIED_AVAILABLE', research_status: 'VERIFIED_AVAILABLE', notice: null },
        verification: { verified_listing: true, provenance: 'operational_verified_listing' },
        research_index: { value: 27, available: true, meaning: 'Uncalibrated P-vs-U research association index (0–100), supporting context only — not used to rank this comparison.' },
        metrics: {
          monthly_rent_rm: { value: 5000, available: true, label: 'Monthly rental', unit: 'RM / month', radius_m: null, group: 'cost_space', source: 'catalogue', display: '5,000 RM / month' },
          size_sqft: { value: 1635, available: true, label: 'Floor area', unit: 'sq ft', radius_m: null, group: 'cost_space', source: 'catalogue', display: '1,635 sq ft' },
          rent_per_sqft: { value: 3.06, available: true, label: 'Rental per sq ft', unit: 'RM / sq ft', radius_m: null, group: 'cost_space', source: 'derived', display: '3.06 RM / sq ft' },
          has_parking: { value: null, available: false, label: 'On-site parking', unit: '', radius_m: null, group: 'cost_space', source: 'listing', display: 'Data not available' },
          population_500m: { value: 1071.6, available: true, label: 'Resident population', unit: 'people', radius_m: 500, group: 'location', source: 'raster', display: '1,072 people' },
          fnb_competitors_500m: { value: 1, available: true, label: 'Recorded F&B competitors', unit: 'outlets', radius_m: 500, group: 'competition', source: 'mapped', display: '1 outlets' },
        },
        data_gaps: [
          { metric: 'has_parking', label: 'On-site parking', reason: 'No verified measurement is recorded for this property.' },
        ],
      },
      {
        property_id: 'MD-04816',
        title: 'Alma Bukit Mertajam Corner Shoplot',
        city: 'Bukit Mertajam', state: 'Penang', postcode: '14000',
        property_type: 'Shop', image_url: null,
        panorama: { available: false, status: null, url: null },
        availability: { confirmed: false, status: 'Not confirmed', research_status: 'UNKNOWN_NOT_VERIFIED', notice: null },
        verification: { verified_listing: false, provenance: 'research_unverified' },
        research_index: { value: null, available: false, meaning: '' },
        metrics: {
          monthly_rent_rm: { value: 900, available: true, label: 'Monthly rental', unit: 'RM / month', radius_m: null, group: 'cost_space', source: 'catalogue', display: '900 RM / month' },
          size_sqft: { value: 2460, available: true, label: 'Floor area', unit: 'sq ft', radius_m: null, group: 'cost_space', source: 'catalogue', display: '2,460 sq ft' },
          rent_per_sqft: { value: 0.37, available: true, label: 'Rental per sq ft', unit: 'RM / sq ft', radius_m: null, group: 'cost_space', source: 'derived', display: '0.37 RM / sq ft' },
          has_parking: { value: null, available: true, label: 'On-site parking', unit: '', radius_m: null, group: 'cost_space', source: 'listing', display: 'Yes' },
          population_500m: { value: null, available: false, label: 'Resident population', unit: 'people', radius_m: 500, group: 'location', source: 'raster', display: 'Data not available' },
          fnb_competitors_500m: { value: 44, available: true, label: 'Recorded F&B competitors', unit: 'outlets', radius_m: 500, group: 'competition', source: 'mapped', display: '44 outlets' },
        },
        data_gaps: [
          { metric: 'population_500m', label: 'Resident population', reason: 'No verified measurement is recorded for this property.' },
        ],
      },
    ],
    differences: [
      {
        metric: 'monthly_rent_rm', from_id: 'MD-00510', to_id: 'MD-04816',
        from_title: 'Impian Prisma Intermediate Shoplot', to_title: 'Alma Bukit Mertajam Corner Shoplot',
        value: -4100, unit: 'RM / month', radius_m: null,
        sentence: 'Alma Bukit Mertajam Corner Shoplot costs RM 4,100 less per month than Impian Prisma Intermediate Shoplot.',
      },
    ],
    insights: [
      { property_id: 'MD-04816', title: 'Alma Bukit Mertajam Corner Shoplot', points: ['Lowest monthly rental'] },
    ],
    tradeoffs: [
      { property_ids: ['MD-00510', 'MD-04816'], text: 'Alma Bukit Mertajam Corner Shoplot offers 825 sq ft more space, but costs RM 4,100 more per month. Impian Prisma Intermediate Shoplot has the lower monthly commitment.' },
    ],
    notes: ['Fewer recorded competitors may reflect a quieter area or an established commercial district.'],
  },
};

const UNRESOLVED = JSON.parse(JSON.stringify(TWO_RESOLVED));
UNRESOLVED.data = {
  selected_count: 2, resolved_count: 1,
  unresolved_ids: ['ZZ-404'],
  unresolved_details: [{ id: 'ZZ-404', reason: 'No published, administrator-approved commercial listing exists with this id.' }],
  properties: TWO_RESOLVED.data.properties.slice(0, 1),
  differences: [], insights: [], tradeoffs: [], notes: [],
};

async function newPage(browser, { cookie }) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  if (cookie) {
    await context.addCookies([{
      name: 'sitewise_ui',
      value: encodeURIComponent(JSON.stringify(cookie)),
      domain: '127.0.0.1', path: '/',
    }]);
  }
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await installHarnessSession(page);
  // The compare API: 404 unless the scenario installs its own handler, which
  // is exactly how the "backend unavailable" state is produced.
  await page.route('**/api/v1/compare', (route) =>
    route.fulfill({ status: 404, contentType: 'application/json', body: '{"detail":"nope"}' }));
  return { context, page, errors };
}

async function gotoCompare(page) {
  await page.goto(`${BASE}/entrepreneur/compare`, { waitUntil: 'load' });
  await page.waitForSelector('.cmp', { timeout: 20000 });
  await page.waitForTimeout(700);
}

async function scenario_twoResolved(browser) {
  const { context, page, errors } = await newPage(browser, {
    cookie: { s: [], c: ['MD-00510', 'MD-04816'], u: '' },
  });
  await page.route('**/api/v1/compare', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(TWO_RESOLVED) }));
  await gotoCompare(page);
  const body = await page.textContent('.cmp');
  check('2 selected: count badge', body.includes('2 of 3 selected'));
  check('2 selected: both property titles render', body.includes('Impian Prisma Intermediate Shoplot') && body.includes('Alma Bukit Mertajam Corner Shoplot'));
  check('2 selected: difference sentence renders', body.includes('costs RM 4,100 less per month'));
  check('2 selected: missing metric shows Data not available', body.includes('Data not available'));
  check('2 selected: trade-off renders', body.includes('825 sq ft more space'));
  check('2 selected: no unresolved notice', !body.includes('could not be resolved'));
  check('2 selected: no page errors', errors.length === 0, errors.join(' | ').slice(0, 200));
  await context.close();
}

async function scenario_threeSelected(browser) {
  const payload = JSON.parse(JSON.stringify(TWO_RESOLVED));
  payload.data.selected_count = 3;
  payload.data.resolved_count = 3;
  payload.data.properties.push({
    ...payload.data.properties[0],
    property_id: '316', title: 'Operational Listing 316',
    verification: { verified_listing: true, provenance: 'operational_verified_listing' },
  });
  const { context, page, errors } = await newPage(browser, {
    cookie: { s: [], c: ['MD-00510', 'MD-04816', '316'], u: '' },
  });
  await page.route('**/api/v1/compare', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(payload) }));
  await gotoCompare(page);
  const body = await page.textContent('.cmp');
  check('3 selected: count badge', body.includes('3 of 3 selected'));
  check('3 selected: operational numeric id renders', body.includes('Operational Listing 316'));
  check('3 selected: no page errors', errors.length === 0, errors.join(' | ').slice(0, 200));
  await context.close();
}

async function scenario_oneSelected(browser) {
  const { context, page } = await newPage(browser, {
    cookie: { s: [], c: ['MD-00510'], u: '' },
  });
  await gotoCompare(page);
  const body = await page.textContent('.cmp');
  check('1 selected: honest add-another notice', body.includes('One property selected'));
  await context.close();
}

async function scenario_empty(browser) {
  const { context, page } = await newPage(browser, { cookie: { s: [], c: [], u: '' } });
  await gotoCompare(page);
  const body = await page.textContent('.cmp');
  check('0 selected: empty state', body.includes('Nothing to compare yet'));
  await context.close();
}

async function scenario_unresolved(browser) {
  const { context, page, errors } = await newPage(browser, {
    cookie: { s: [], c: ['MD-00510', 'ZZ-404'], u: '' },
  });
  await page.route('**/api/v1/compare', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(UNRESOLVED) }));
  await gotoCompare(page);
  const body = await page.textContent('.cmp');
  check('unresolved: backend reason rendered verbatim', body.includes('No published, administrator-approved commercial listing exists with this id.'));
  check('unresolved: resolved property still shown', body.includes('Impian Prisma Intermediate Shoplot'));
  check('unresolved: no page errors', errors.length === 0, errors.join(' | ').slice(0, 200));
  await context.close();
}

async function scenario_apiFailure(browser) {
  const { context, page } = await newPage(browser, {
    cookie: { s: [], c: ['MD-00510', 'MD-04816'], u: '' },
  });
  // No compare route override: the harness answers 404 like a dead backend.
  await gotoCompare(page);
  const body = await page.textContent('.cmp');
  check('API failure: error notice, not an eternal spinner', body.includes('The comparison could not be loaded'));
  const retry = await page.$('button:has-text("Retry")');
  check('API failure: Retry action exists', retry !== null);
  await context.close();
}

async function scenario_accountScope(browser) {
  // The cookie's compare set belongs to a DIFFERENT account tag than the
  // live session (harness-entrepreneur) — boot must drop it, so the page
  // shows the empty state instead of another account's shortlist.
  const { context, page } = await newPage(browser, {
    cookie: { s: [], c: ['MD-00510', 'MD-04816'], u: 'someone-else' },
  });
  await page.route('**/api/v1/compare', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(TWO_RESOLVED) }));
  await gotoCompare(page);
  const body = await page.textContent('.cmp');
  check('account scope: foreign cookie shortlist is dropped', body.includes('Nothing to compare yet'));
  await context.close();
}

(async () => {
  const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-proxy-server'] });
  try {
    await scenario_twoResolved(browser);
    await scenario_threeSelected(browser);
    await scenario_oneSelected(browser);
    await scenario_empty(browser);
    await scenario_unresolved(browser);
    await scenario_apiFailure(browser);
    await scenario_accountScope(browser);
  } finally {
    await browser.close();
  }
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})();
