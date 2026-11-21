// Verify dynamic monthly-rental filtering on /entrepreneur/recommendations
// against FACET PAYLOADS CAPTURED FROM THE REAL DATABASE (see
// backend/scripts/capture_evidence_fixture.py pattern; this capture reads
// RecommendationSearchService.facets + search totals for concrete criteria).
//
// Checks:
//   - one Monthly rental dropdown, no hand typed min/max inputs
//   - option labels are full intervals with real counts, no hardcoded values
//   - state, property type and size changes refresh the options and counts
//   - selecting an option sends exactly its two bounds; Any clears both
//   - a rent range that becomes unavailable is preserved with recovery UI
//   - debounced text search, stale-response guard, retry, clear, and
//     returning from Property Details
//
// Run:
//   NODE_PATH=C:/Users/Lenovo/.workbuddy-ai/binaries/node/workspace/node_modules \
//   BASE=http://127.0.0.1:8090 node tool/probe_recommendation_contextual_facets.js
const path = require('node:path');
const fs = require('node:fs');
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness.js');

const BASE = process.env.BASE || 'http://127.0.0.1:8090';
const CAPTURED = JSON.parse(
  fs.readFileSync(
    path.join(__dirname, '..', '..', 'test', '.data', 'recommendation_facets_captured.json'),
    'utf8',
  ),
);
const CATALOGUE = JSON.parse(
  fs.readFileSync(
    path.join(__dirname, '..', '..', 'test', '.data', 'jaspr_catalog_fixture.json'),
    'utf8',
  ),
).rows;

function caseFor(query) {
  const state = query.get('preferred_state');
  const type = query.get('property_type');
  const min = Number(query.get('min_rental_rm'));
  const search = query.get('query');
  if (search) return 'query_cafe';
  if (state === 'Selangor' && min === 23000) return 'selangor_no_match';
  if (state === 'Selangor' && type === 'Shop lot') return 'selangor_shop_lot';
  if (state === 'Selangor' && (query.has('min_size_sqft') || query.has('max_size_sqft'))) {
    return 'selangor_size';
  }
  if (state === 'Selangor') return 'selangor';
  if (state === 'Johor') return 'johor';
  return 'all';
}

function searchPayload(body) {
  const noMatch = body.min_rental_rm === 23000;
  const data = noMatch ? [] : CATALOGUE.slice(0, 3);
  return {
    data,
    pagination: {
      next_cursor: null,
      has_more: false,
      total: noMatch ? 0 : data.length,
      page_size: 20,
    },
    model: {
      available: false,
      version: null,
      score_type: 'requirement_fit_ordering',
      reason: 'Fixture: requirement-fit ordering.',
      research_only: true,
    },
    meta: {
      source: 'fyp.catalogue_properties',
      property_source: 'catalog',
      criteria: body,
      cached: false,
    },
  };
}

(async () => {
  const checks = [];
  const ok = (name, pass, extra = '') => {
    checks.push({ name, pass: !!pass });
    if (!pass) console.log(`  FAIL ${name} ${extra}`);
  };
  const facetQueries = [];
  const posted = [];
  const delays = {};
  let failFacets = false;

  const browser = await chromium.launch({ args: ['--no-proxy-server'] });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const page = await context.newPage();
  await installHarnessSession(page, { role: 'entrepreneur' });

  await page.route('**/api/v1/recommendations/facets*', async (route) => {
    const query = new URL(route.request().url()).searchParams;
    const name = caseFor(query);
    facetQueries.push({ name, query });
    if (delays[name]) await new Promise((r) => setTimeout(r, delays[name]));
    if (failFacets) {
      failFacets = false;
      return route.fulfill({ status: 503, contentType: 'application/json', body: '{"detail":"facet failure"}' });
    }
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ data: CAPTURED[name].facets }),
    });
  });
  await page.route('**/api/v1/recommendations/search', (route) => {
    const body = route.request().postDataJSON() || {};
    posted.push(body);
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(searchPayload(body)) });
  });

  const rentOptions = () =>
    page.evaluate(() =>
      Array.from(
        document.querySelectorAll('select[aria-label="Monthly rental (RM)"] option'),
      ).map((o) => ({ value: o.value, text: o.textContent.trim() })),
    );
  const status = () =>
    page.evaluate(() => (document.querySelector('.rec2__facet-status')?.textContent || '').trim());
  const waitForFacet = async (name, timeout = 6000) => {
    const until = Date.now() + timeout;
    while (Date.now() < until) {
      if (facetQueries.some((entry) => entry.name === name)) return true;
      await page.waitForTimeout(40);
    }
    return false;
  };

  await page.goto(`${BASE}/entrepreneur/recommendations`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(700);

  // --- 1. The single dropdown and its real options -------------------------
  const initial = await page.evaluate(() => ({
    selects: document.querySelectorAll('select[aria-label="Monthly rental (RM)"]').length,
    oldInputs: document.querySelectorAll(
      'input[aria-label="Min monthly rent (RM)"], input[aria-label="Max monthly rent (RM)"]',
    ).length,
  }));
  const allOptions = await rentOptions();
  ok('one Monthly rental dropdown', initial.selects === 1, String(initial.selects));
  ok('no separate min/max rent inputs', initial.oldInputs === 0, String(initial.oldInputs));
  ok('Any monthly rental is first', allOptions[0]?.text === 'Any monthly rental', allOptions[0]?.text);
  ok(
    'all real rental intervals are offered, with counts',
    allOptions.length === CAPTURED.all.facets.rental_ranges.options.length + 1 &&
      allOptions.slice(1).every((o) => /RM .*–|RM \d/.test(o.text) && /\d+ propert/.test(o.text)),
    JSON.stringify(allOptions),
  );
  ok(
    'draft count equals the captured backend matching_total',
    (await status()).startsWith(String(CAPTURED.all.facets.matching_total)),
    await status(),
  );

  // --- 2. Selangor contextual options -------------------------------------
  await page.locator('.rec2__filters .checkpill:has-text("Selangor") input').click();
  ok('Selangor facets requested', await waitForFacet('selangor'));
  await page.waitForTimeout(200);
  const selangorOptions = await rentOptions();
  ok(
    'rental options change for Selangor',
    selangorOptions.length === CAPTURED.selangor.facets.rental_ranges.options.length + 1,
    JSON.stringify(selangorOptions),
  );
  ok('Selangor matching count shown', (await status()).startsWith(String(CAPTURED.selangor.facets.matching_total)), await status());

  // --- 3. Property type narrows the intervals again ------------------------
  await page.locator('.rec2__filters .checkpill:has-text("Shop lot") input').click();
  ok('state+type facets requested', await waitForFacet('selangor_shop_lot'));
  await page.waitForTimeout(200);
  const shopOptions = await rentOptions();
  ok(
    'rental options change for Selangor shop lots',
    shopOptions.length === CAPTURED.selangor_shop_lot.facets.rental_ranges.options.length + 1,
    JSON.stringify(shopOptions),
  );

  // --- 4. Property size narrows the intervals again ------------------------
  // Drop the property type so criteria match the captured state+size case.
  await page
    .locator('.field:has(> .field__label:text-is("Property type")) .checkpill')
    .first()
    .locator('input')
    .click();
  await waitForFacet('selangor');
  await page.fill('input[aria-label="Minimum size (sq ft)"]', '800');
  await page.fill('input[aria-label="Maximum size (sq ft)"]', '1800');
  ok('size facets requested after debounce', await waitForFacet('selangor_size'));
  await page.waitForTimeout(200);
  const sizeOptions = await rentOptions();
  ok(
    'rental options change for the selected size range',
    sizeOptions.length === CAPTURED.selangor_size.facets.rental_ranges.options.length + 1,
    JSON.stringify(sizeOptions),
  );
  ok(
    'size-filtered count matches the backend',
    (await status()).startsWith(String(CAPTURED.selangor_size.facets.matching_total)),
    await status(),
  );

  // --- 5. Selecting a range sends exactly its bounds ----------------------
  const picked = sizeOptions.find((o) => o.value !== '');
  await page.selectOption('select[aria-label="Monthly rental (RM)"]', picked.value);
  await page.waitForTimeout(200);
  await page.click('button:has-text("Find properties")');
  await page.waitForTimeout(500);
  const last = posted[posted.length - 1];
  const [minValue, maxValue] = picked.value.split('|').map(Number);
  ok('selected interval minimum sent to FastAPI', last.min_rental_rm === minValue, JSON.stringify(last));
  ok('selected interval maximum sent to FastAPI', last.max_rental_rm === maxValue, JSON.stringify(last));
  ok('rent boundaries are ordered', last.min_rental_rm <= last.max_rental_rm);

  // --- 6. Any monthly rental clears both boundaries -----------------------
  await page.selectOption('select[aria-label="Monthly rental (RM)"]', '');
  await page.click('button:has-text("Find properties")');
  await page.waitForTimeout(400);
  const cleared = posted[posted.length - 1];
  ok('Any clears both rent limits', cleared.min_rental_rm === undefined && cleared.max_rental_rm === undefined, JSON.stringify(cleared));

  // --- 7. A range that no longer matches is preserved, with recovery ------
  // The highest real interval exists in the full eligible set but not in
  // Selangor: choose it, then change state. Nothing may silently reprice it.
  await page.click('button:has-text("Clear")');
  await page.waitForTimeout(400);
  const highOption = (await rentOptions()).find((o) => o.value.includes('23000'));
  if (highOption) {
    await page.selectOption('select[aria-label="Monthly rental (RM)"]', highOption.value);
    await page.click('.rec2__filters .checkpill:has-text("Selangor") input');
    ok('no-match facets requested', await waitForFacet('selangor_no_match'));
    await page.waitForTimeout(200);
    const kept = await page.evaluate(() => ({
      value: document.querySelector('select[aria-label="Monthly rental (RM)"]')?.value,
      note: document.querySelector('.rec2__rent-note')?.textContent || '',
      status: document.querySelector('.rec2__facet-status')?.textContent || '',
    }));
    ok('unavailable rent selection is preserved', kept.value === highOption.value, kept.value);
    ok('zero-match message shown', /No properties match all your current filters\./.test(kept.status), kept.status);
    ok('clear + recovery actions shown', /Clear rental filter/.test(kept.status + kept.note), kept.status + kept.note);
    await page.click('.rec2__facet-status button:has-text("Clear rental filter")');
    await page.waitForTimeout(250);
    ok(
      'clear rental recovers the selection',
      (await page.evaluate(() => document.querySelector('select[aria-label="Monthly rental (RM)"]')?.value)) === '',
    );
  } else {
    ok('highest real interval present for recovery test', false, JSON.stringify(allOptions));
  }

  // --- 8. Debounced search ------------------------------------------------
  await page.click('button:has-text("Clear")');
  await page.waitForTimeout(350);
  const beforeQuery = facetQueries.filter((e) => e.name === 'query_cafe').length;
  for (const text of ['c', 'ca', 'caf', 'cafe']) {
    await page.fill('input[aria-label="Search"]', text);
    await page.waitForTimeout(60);
  }
  await page.waitForTimeout(500);
  const queryRequests = facetQueries.filter((e) => e.name === 'query_cafe').length - beforeQuery;
  ok('search facets debounced to one request', queryRequests === 1, String(queryRequests));
  ok('search count from real DB shown', (await status()).startsWith(String(CAPTURED.query_cafe.facets.matching_total)), await status());

  // --- 9. Clear restores the defaults ------------------------------------
  await page.click('button:has-text("Clear")');
  await page.waitForTimeout(450);
  const clearedOptions = await rentOptions();
  ok('Clear restores all intervals', clearedOptions.length === allOptions.length, String(clearedOptions.length));
  ok('Clear restores the full eligible count', (await status()).startsWith(String(CAPTURED.all.facets.matching_total)), await status());
  ok('Clear clears the dropdown', (await page.evaluate(() => document.querySelector('select[aria-label="Monthly rental (RM)"]')?.value)) === '');

  // --- 10. Return from Property Details keeps the applied filters ---------
  await page.selectOption('select[aria-label="Monthly rental (RM)"]', allOptions[1].value);
  await page.click('.rec2__filters .checkpill:has-text("Selangor") input');
  await page.click('button:has-text("Find properties")');
  await page.waitForTimeout(450);
  const firstCardHref = await page.evaluate(
    () => document.querySelector('.rec2-card a[href*="property-detail"]')?.getAttribute('href'),
  );
  if (firstCardHref) {
    await page.click('.rec2-card a[href*="property-detail"]');
    await page.waitForTimeout(400);
    await page.goBack();
    await page.waitForTimeout(500);
    const restored = await page.evaluate(() => ({
      value: document.querySelector('select[aria-label="Monthly rental (RM)"]')?.value,
      stateSelected: Array.from(document.querySelectorAll('.rec2__filters .checkpill')).some(
        (pill) => pill.textContent.includes('Selangor') && pill.querySelector('input')?.checked,
      ),
    }));
    ok('return keeps the rental interval', restored.value === allOptions[1].value, restored.value);
    ok('return keeps the state chip', restored.stateSelected);
  } else {
    ok('a ranked card links to Property Details', false, 'no card link');
  }

  // --- 11. Rapid changes: the older response must not win ----------------
  await page.click('button:has-text("Clear")');
  await page.waitForTimeout(350);
  delays.selangor = 650;
  delays.johor = 20;
  await page.click('.rec2__filters .checkpill:has-text("Selangor") input');
  await page.waitForTimeout(60);
  await page
    .locator('.field:has(> .field__label:text-is("Preferred state")) .checkpill:has-text("Johor") input')
    .click();
  await page.waitForTimeout(1100);
  ok('stale Selangor response cannot overwrite Johor', (await status()).startsWith(String(CAPTURED.johor.facets.matching_total)), await status());
  delays.selangor = 0;
  delays.johor = 0;

  // --- 12. Failed facet request: retry keeps the controls usable ----------
  failFacets = true;
  await page
    .locator('.field:has(> .field__label:text-is("Preferred state")) .checkpill')
    .first()
    .locator('input')
    .click();
  await page.waitForTimeout(250);
  const errorStatus = await status();
  ok('facet failure surfaces a retry', /could not be updated/i.test(errorStatus) && /Retry/.test(errorStatus), errorStatus);
  ok('previous options remain visible after failure', (await rentOptions()).length > 1);
  await page.click('.rec2__facet-status button:has-text("Retry")');
  await page.waitForTimeout(350);
  ok('retry restores live counts', (await status()).startsWith(String(CAPTURED.all.facets.matching_total)), await status());

  await page.screenshot({ path: path.join(__dirname, 'screenshots', 'recommendations_rental_dropdown.png'), fullPage: true });
  await browser.close();

  const failed = checks.filter((c) => !c.pass);
  console.log(`${checks.length - failed.length}/${checks.length} checks passed`);
  process.exit(failed.length ? 1 : 0);
})().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
