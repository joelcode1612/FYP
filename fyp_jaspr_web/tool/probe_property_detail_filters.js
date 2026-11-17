/* Headless verification of the "Your preferences vs this property" FILTER
 * comparison (Property Detail, tab 1).
 *
 * When the entrepreneur opens a property from a Recommendations search, the
 * page carries the APPLIED filters as `?filters=<json>`. The comparison panel
 * must then render those filters against the listing's own details — clearly
 * labelled as the search filters, never as a model score or a saved
 * recommendation. Without filter context the honest invite still renders.
 *
 * Expected strings are computed from the captured payloads in
 * test/.data (real property EP-01051), never hardcoded.
 *
 * Run:
 *   NODE_PATH=C:/Users/Lenovo/.workbuddy-ai/binaries/node/workspace/node_modules \
 *   node tool/probe_property_detail_filters.js
 */
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1243/chrome-win64/chrome.exe';
const BASE = process.env.BASE || 'http://127.0.0.1:8090';
const PROPERTY_ID = 'EP-01051';

const FIXTURE_DIR = path.join(__dirname, '..', '..', 'test', '.data');
const evidencePayload = JSON.parse(
  fs.readFileSync(path.join(FIXTURE_DIR, 'evidence_captured_fixture.json'), 'utf8'),
);
const catalogueRows = JSON.parse(
  fs.readFileSync(path.join(FIXTURE_DIR, 'jaspr_catalog_fixture.json'), 'utf8'),
).rows;
const propertyRow = catalogueRows.find((r) => r.id === PROPERTY_ID);
if (!propertyRow) throw new Error(`${PROPERTY_ID} missing from the catalog fixture`);

const rentalMax = propertyRow.rental_max_rm ?? propertyRow.rental_rm;

// The applied filter set mirrors what the Recommendations page sends after a
// filtered search (snake_case `toJson` keys), anchored to this listing's real
// values so every computed status is deterministic:
//   business type  -> always "Needs review" (it orders results, never filters)
//   preferred state / property type -> exact match with the row -> "Matched"
//   rental / size  -> a range straddling the listing's own values -> "Matched"
//   target market  -> the catalogue has no customer-mix field -> "Not enough data"
const filters = {
  business_type: 'Bakery',
  preferred_state: propertyRow.state,
  property_type: propertyRow.property_type,
  min_rental_rm: propertyRow.rental_rm - 100,
  max_rental_rm: rentalMax + 100,
  min_size_sqft: propertyRow.size_sqft - 50,
  max_size_sqft: propertyRow.size_sqft + 50,
  layout_preferences: ['Students'],
};
const filtersQuery = encodeURIComponent(JSON.stringify(filters));

const CHECKED_ROWS = 5; // every row except the unanswerable target market
const EXPECTED_MATCHES = 4; // state, type, rental, size

const checks = [];
function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
}

async function loadPage(browser, url) {
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
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 });
  await page.waitForSelector('.sw-info__tabs', { timeout: 20000 });
  await page.waitForTimeout(1500);
  return { page, errors };
}

function readCompare(page) {
  return page.evaluate(() => {
    const txt = (s) => (document.querySelector(s)?.textContent || '').trim();
    const rows = Array.from(document.querySelectorAll('.sw-compare__row')).map((r) => ({
      name: (r.querySelector('.sw-compare__name')?.textContent || '').trim(),
      yours: (r.querySelector('.sw-compare__cell')?.textContent || '').trim(),
      property: (r.querySelectorAll('.sw-compare__cell')[1]?.textContent || '').trim(),
      status: (() => {
        const spans = r.querySelectorAll('.sw-compare__status span');
        return spans.length ? (spans[spans.length - 1].textContent || '').trim() : '';
      })(),
      note: (r.querySelector('.sw-compare__note')?.textContent || '').trim(),
    }));
    return {
      invite: document.querySelector('.sw-compare__invite') !== null,
      head: Array.from(document.querySelectorAll('.sw-compare__head span')).map((s) =>
        (s.textContent || '').trim(),
      ),
      rows,
      summary: txt('.sw-compare__summary p'),
      source: txt('.sw-matchdetail__source p'),
      intro: txt('.sw-matchdetail .sw-info__intro p'),
    };
  });
}

(async () => {
  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-proxy-server', '--no-sandbox'],
  });

  // --- pass 1: filters carried from the Recommendations search --------------
  {
    const url =
      `${BASE}/entrepreneur/property-detail?id=${PROPERTY_ID}` +
      `&businessType=Bakery&filters=${filtersQuery}`;
    const { page, errors } = await loadPage(browser, url);
    const c = await readCompare(page);

    check('no invite when filters are applied', !c.invite);
    check('header reads Filter / Your selection / This property / Status',
      c.head.join('|') === 'Filter|Your selection|This property|Status', c.head.join('|'));
    check('intro names the applied filters',
      /compares the filters you applied on Recommendations/.test(c.intro), c.intro);

    const byName = Object.fromEntries(c.rows.map((r) => [r.name, r]));
    for (const name of [
      'Business type',
      'Preferred state',
      'Property type',
      'Monthly rental',
      'Property size',
      'Target market',
    ]) {
      check(`row "${name}" rendered`, !!byName[name], c.rows.map((r) => r.name).join(' | '));
    }
    check('six filter rows', c.rows.length === 6, String(c.rows.length));

    check('business type row is honest (Needs review)',
      byName['Business type']?.status === 'Needs review',
      byName['Business type'] ? byName['Business type'].status : 'missing');
    check('business type explains ordering role',
      /orders the results/.test(byName['Business type']?.note || ''),
      byName['Business type']?.note);
    check('state row matched the listing',
      byName['Preferred state']?.status === 'Matched',
      byName['Preferred state'] ? byName['Preferred state'].status : 'missing');
    check('property type row matched the listing',
      byName['Property type']?.status === 'Matched',
      byName['Property type'] ? byName['Property type'].status : 'missing');
    check('rental row matched the straddling range',
      byName['Monthly rental']?.status === 'Matched',
      byName['Monthly rental'] ? byName['Monthly rental'].status : 'missing');
    check('size row matched the straddling range',
      byName['Property size']?.status === 'Matched',
      byName['Property size'] ? byName['Property size'].status : 'missing');
    check('target market says Not enough data',
      byName['Target market']?.status === 'Not enough data',
      byName['Target market'] ? byName['Target market'].status : 'missing');
    check('target market note explains the gap',
      /no customer-mix information/.test(byName['Target market']?.note || ''),
      byName['Target market']?.note);
    check('state "your selection" echoes the filter',
      byName['Preferred state']?.yours === propertyRow.state,
      byName['Preferred state']?.yours);
    check('rental "this property" formats the listing rent',
      (byName['Monthly rental']?.property || '').includes(
        `RM ${Math.round(propertyRow.rental_rm).toLocaleString('en-US')}`,
      ),
      byName['Monthly rental']?.property);

    check('summary counts checkable filters',
      c.summary ===
        `${EXPECTED_MATCHES} of ${CHECKED_ROWS} checkable filters match this listing.`,
      c.summary);
    check('source note says these are applied filters, not a score',
      /filters you applied/.test(c.source) && /not a model score/.test(c.source),
      c.source);

    const allText = c.rows.map((r) => Object.values(r).join(' ')).join(' ') +
      ` ${c.summary} ${c.source}`;
    check('no NaN/null/undefined in the comparison',
      !/NaN|\bnull\b|undefined/.test(allText), allText.slice(0, 300));

    check('no fatal console errors',
      errors.filter((e) =>
        !e.includes('favicon') && !e.includes('net::') &&
        !e.includes('404') && !e.includes('Failed to load resource'),
      ).length === 0,
      errors.slice(0, 3).join(' | '));

    // Mobile: the comparison table must not overflow a 390px viewport.
    await page.setViewportSize({ width: 390, height: 844 });
    await page.waitForTimeout(400);
    const overflow = await page.evaluate(() => ({
      scrollW: document.documentElement.scrollWidth,
      innerW: window.innerWidth,
    }));
    check('mobile: no horizontal overflow', overflow.scrollW <= overflow.innerW + 1,
      JSON.stringify(overflow));
    await page.close();
  }

  // --- pass 2: no filter context -> the honest invite stays -----------------
  {
    const url = `${BASE}/entrepreneur/property-detail?id=${PROPERTY_ID}`;
    const { page } = await loadPage(browser, url);
    const c = await readCompare(page);
    check('invite shown without filters', c.invite);
    check('no comparison rows without filters', c.rows.length === 0, String(c.rows.length));
    const inviteText = await page.evaluate(() =>
      (document.querySelector('.sw-compare__invite')?.textContent || ''),
    );
    check('invite names the missing link',
      /not linked to a saved recommendation yet/.test(inviteText), inviteText.trim());
    check('invite links to Recommendations',
      (await page.$eval('.sw-compare__invite a', (a) => a.getAttribute('href'))) ===
        '/entrepreneur/recommendations');
    await page.close();
  }

  // --- pass 3: a malformed filters value must not fabricate anything --------
  {
    const url =
      `${BASE}/entrepreneur/property-detail?id=${PROPERTY_ID}` +
      `&filters=${encodeURIComponent('not-json-at-all')}`;
    const { page } = await loadPage(browser, url);
    const c = await readCompare(page);
    check('malformed filters degrade to the invite', c.invite);
    check('malformed filters render no rows', c.rows.length === 0, String(c.rows.length));
    await page.close();
  }

  // --- pass 4: a browse-only request (no criteria) also stays honest --------
  {
    const browse = encodeURIComponent(JSON.stringify({ sort: 'best_match' }));
    const url =
      `${BASE}/entrepreneur/property-detail?id=${PROPERTY_ID}&filters=${browse}`;
    const { page } = await loadPage(browser, url);
    const c = await readCompare(page);
    check('browse-only request shows the invite', c.invite);
    check('browse-only request renders no rows', c.rows.length === 0, String(c.rows.length));
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
