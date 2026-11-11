// Verify the entrepreneur Recommendations page:
//   - default search returns PU-eligible properties (fixture: all > 50),
//     cards show the PU score, the "PU score > 50" eligibility chip is shown
//   - applied filters render as chips; Apply sends exactly those criteria
//   - navigating to a property detail and back RETAINS chips, inputs and
//     results (session-scoped state; no re-seed from saved preferences)
//   - editing the draft and leaving WITHOUT applying does not change the
//     applied criteria
//   - removing one chip removes only that criterion
//   - Clear restores defaults
//   - fewer than three matches shows the honest "Only N properties..." note
//   - a slow earlier response cannot overwrite a newer one
//
// Run:
//   NODE_PATH=C:/Users/Lenovo/.workbuddy-ai/binaries/node/workspace/node_modules \
//   node tool/probe_recommendation_filters.js
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness.js');

const BASE = process.env.BASE || 'http://127.0.0.1:8141';

function item(index, overrides = {}) {
  const id = overrides.property_id || `EP-90${index}`;
  return {
    property_id: id,
    property_source: 'catalog',
    title: overrides.title || `Shoplot ${index}, Subang Jaya`,
    address: `${index} Jalan SS15/4`,
    city: 'Subang Jaya',
    state: 'Selangor',
    postcode: '47500',
    rental_rm: overrides.rental_rm ?? 7000,
    size_sqft: overrides.size_sqft ?? 1200,
    property_type: 'Shoplot',
    image_url: null,
    latitude: 3.07,
    longitude: 101.6,
    research: {
      catalog_suitability_score: overrides.pu ?? 78,
      suitability_available: true,
      pu_score: overrides.pu ?? 78,
      pu_available: true,
      pu_score_scale: '0-100',
    },
    recommendation: {
      available: false,
      rank: index,
      score: null,
      score_type: 'requirement_fit_ordering',
      model_version: null,
      reason: 'Requirement-fit ordering (fixture).',
      matched_requirements: [],
      unmatched_requirements: [],
      unverified_requirements: [],
      match_ratio: null,
      matched_count: 0,
      verifiable_count: 0,
    },
  };
}

const DEFAULT_ITEMS = [
  item(1, { pu: 78, rental_rm: 7000, size_sqft: 1200 }),
  item(2, { pu: 71, rental_rm: 7500, size_sqft: 1600 }),
  item(3, { pu: 62, rental_rm: 6800, size_sqft: 900 }),
];

function pagePayload(body, items) {
  return {
    data: items,
    pagination: {
      next_cursor: null,
      has_more: false,
      total: items.length,
      page_size: 20,
    },
    model: {
      available: false,
      version: null,
      score_type: 'requirement_fit_ordering',
      reason: 'Requirement-fit ordering (fixture).',
      research_only: true,
    },
    meta: {
      source: 'sitewise_app.properties',
      property_source: 'catalog',
      criteria: body,
      cached: false,
      pu_eligibility: {
        threshold: 50,
        scale: '0-100',
        comparison: 'strictly_greater_than',
        column: 'sitewise_app.properties.suitability_score',
      },
    },
  };
}

(async () => {
  const browser = await chromium.launch({ args: ['--no-proxy-server'] });
  const checks = [];
  const ok = (name, pass, extra = '') => {
    checks.push({ name, pass: !!pass });
    if (!pass) console.log(`  FAIL ${name} ${extra}`);
  };

  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const page = await context.newPage();
  await installHarnessSession(page, { role: 'entrepreneur' });

  const posted = [];
  await page.route('**/api/v1/recommendations/facets', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        data: {
          states: [
            { value: 'Selangor', total: 600 },
            { value: 'Johor', total: 200 },
          ],
          property_types: [
            { value: 'Shoplot', total: 500 },
            { value: 'Retail space', total: 300 },
          ],
          ranges: {
            min_rental_rm: 500,
            max_rental_rm: 25000,
            min_size_sqft: 200,
            max_size_sqft: 8000,
            total: 955,
          },
        },
      }),
    }),
  );
  await page.route('**/api/v1/recommendations/search', async (route) => {
    const body = route.request().postDataJSON() || {};
    posted.push(body);

    let items = DEFAULT_ITEMS;
    let delay = 0;
    const fullFilterSet =
      body.max_rental_rm === 8000 &&
      body.min_size_sqft === 800 &&
      body.max_size_sqft === 1800 &&
      body.preferred_state === 'Selangor' &&
      body.property_type === 'Shoplot';
    if (fullFilterSet) {
      items = [item(1, { pu: 78 }), item(2, { pu: 71 })];
    }
    // Race simulation: a request that keeps state but drops the rent ceiling
    // responds SLOWLY; one that drops the state but keeps rent responds fast.
    if (body.preferred_state === 'Selangor' && body.max_rental_rm === undefined) {
      delay = 800;
    } else if (body.preferred_state === undefined && body.max_rental_rm === 8000) {
      delay = 50;
      items = DEFAULT_ITEMS;
    }
    await new Promise((resolve) => setTimeout(resolve, delay));
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(pagePayload(body, items)),
    });
  });

  await page.goto(`${BASE}/entrepreneur/recommendations`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1500);

  const initial = await page.evaluate(() => {
    const txt = (s) => (document.querySelector(s)?.textContent || '').trim();
    return {
      cards: document.querySelectorAll('.rec2-card').length,
      count: txt('.rec2__count'),
      eligibility: txt('.rec2__eligibility'),
      chipRow: !!document.querySelector('.rec2__applied'),
      puFacts: Array.from(document.querySelectorAll('.rec2-fact')).filter((f) =>
        /PU score/.test(f.textContent || ''),
      ).length,
    };
  });
  ok('default: 3 cards', initial.cards === 3, String(initial.cards));
  ok('default: eligibility chip', /PU score > 50/.test(initial.eligibility));
  ok('default: no applied chips', !initial.chipRow);
  ok('default: cards show PU score', initial.puFacts >= 3, String(initial.puFacts));

  // --- Apply the example filter set -----------------------------------------
  await page.fill('input[aria-label="Monthly budget (RM)"]', '8000');
  await page.fill('input[aria-label="Minimum size (sq ft)"]', '800');
  await page.fill('input[aria-label="Maximum size (sq ft)"]', '1800');
  await page.click('.checkpill:has-text("Selangor") input');
  await page.click('.checkpill:has-text("Shoplot") input');
  await page.click('button:has-text("Find properties")');
  await page.waitForTimeout(1200);

  const applied = await page.evaluate(() => {
    const chips = Array.from(document.querySelectorAll('.rec2__chip')).map((c) =>
      (c.textContent || '').replace('×', '').trim(),
    );
    return {
      chips,
      count: (document.querySelector('.rec2__count')?.textContent || '').trim(),
      insufficient: (
        document.querySelector('.rec2__insufficient')?.textContent || ''
      ).trim(),
      cards: document.querySelectorAll('.rec2-card').length,
      budgetValue: document.querySelector('input[aria-label="Monthly budget (RM)"]')?.value,
    };
  });
  const lastPost = posted[posted.length - 1];
  ok('apply: budget sent', lastPost.max_rental_rm === 8000, JSON.stringify(lastPost));
  ok('apply: size range sent', lastPost.min_size_sqft === 800 && lastPost.max_size_sqft === 1800);
  ok('apply: state sent', lastPost.preferred_state === 'Selangor');
  ok('apply: type sent', lastPost.property_type === 'Shoplot');
  ok('apply: chips rendered', applied.chips.includes('Selangor') &&
    applied.chips.includes('Shoplot') &&
    applied.chips.includes('RM 8000 max') &&
    applied.chips.includes('800–1800 sq ft'), applied.chips.join('|'));
  ok('apply: 2 results shown', applied.cards === 2, String(applied.cards));
  ok('apply: insufficient note', /Only 2 properties match your current criteria and have PU scores above 50/.test(applied.insufficient), applied.insufficient);

  // --- Navigate to a property detail and return -----------------------------
  // In-app navigation (Jaspr Link = client-side pushState), NOT a full page
  // reload: a browser reload legitimately starts a new session.
  const postsBeforeNav = posted.length;
  await page.click('a[href="/entrepreneur/property-detail?id=EP-901"]');
  await page.waitForTimeout(1200);
  await page.goBack();
  await page.waitForTimeout(1500);

  const afterReturn = await page.evaluate(() => {
    const chips = Array.from(document.querySelectorAll('.rec2__chip')).map((c) =>
      (c.textContent || '').replace('×', '').trim(),
    );
    return {
      chips,
      budgetValue: document.querySelector('input[aria-label="Monthly budget (RM)"]')?.value,
      stateOn: !!document.querySelector('.checkpill.is-on'),
      cards: document.querySelectorAll('.rec2-card').length,
      insufficient: /Only 2 properties/.test(document.body.innerText),
    };
  });
  ok('return: chips retained', afterReturn.chips.includes('RM 8000 max') && afterReturn.chips.includes('Selangor'), afterReturn.chips.join('|'));
  ok('return: budget input retained', afterReturn.budgetValue === '8000', afterReturn.budgetValue);
  ok('return: state chip still selected', afterReturn.stateOn);
  ok('return: filtered results retained', afterReturn.cards === 2, String(afterReturn.cards));
  ok('return: no re-seed search fired', posted.length === postsBeforeNav, `${posted.length} vs ${postsBeforeNav}`);
  ok('return: insufficient note retained', afterReturn.insufficient);

  // --- Draft edit without applying must not change applied state ------------
  await page.fill('input[aria-label="Monthly budget (RM)"]', '9999');
  await page.click('a[href="/entrepreneur/property-detail?id=EP-901"]');
  await page.waitForTimeout(1000);
  await page.goBack();
  await page.waitForTimeout(1200);
  const afterCancel = await page.evaluate(() => ({
    budgetValue: document.querySelector('input[aria-label="Monthly budget (RM)"]')?.value,
    chips: Array.from(document.querySelectorAll('.rec2__chip')).map((c) =>
      (c.textContent || '').replace('×', '').trim(),
    ),
  }));
  ok('cancel: draft discarded, applied retained', afterCancel.budgetValue === '8000', afterCancel.budgetValue);
  ok('cancel: chips unchanged', afterCancel.chips.includes('RM 8000 max'));

  // --- Remove one chip only ---------------------------------------------------
  await page.click('.rec2__chip:has-text("RM 8000 max") .rec2__chip-remove');
  await page.waitForTimeout(900);
  const afterRemove = await page.evaluate(() => ({
    chips: Array.from(document.querySelectorAll('.rec2__chip')).map((c) =>
      (c.textContent || '').replace('×', '').trim(),
    ),
    budgetValue: document.querySelector('input[aria-label="Monthly budget (RM)"]')?.value,
  }));
  const removePost = posted[posted.length - 1];
  ok('remove: rent ceiling cleared in request', removePost.max_rental_rm === undefined, JSON.stringify(removePost));
  ok('remove: only that chip removed', !afterRemove.chips.includes('RM 8000 max') &&
    afterRemove.chips.includes('Selangor') &&
    afterRemove.chips.includes('Shoplot') &&
    afterRemove.chips.includes('800–1800 sq ft'), afterRemove.chips.join('|'));
  ok('remove: budget input cleared', afterRemove.budgetValue === '', afterRemove.budgetValue);

  // --- Rapid changes: the slower earlier response must not win ---------------
  await page.fill('input[aria-label="Monthly budget (RM)"]', '8000');
  await page.click('button:has-text("Find properties")');
  await page.waitForTimeout(1200);
  // Now two chip removals: rent (slow 800ms) then state (fast 50ms).
  await page.click('.rec2__chip:has-text("RM 8000 max") .rec2__chip-remove');
  await page.waitForTimeout(80);
  await page.click('.rec2__chip:has-text("Selangor") .rec2__chip-remove');
  await page.waitForTimeout(1400);
  const afterRace = await page.evaluate(() => ({
    chips: Array.from(document.querySelectorAll('.rec2__chip')).map((c) =>
      (c.textContent || '').replace('×', '').trim(),
    ),
    cards: document.querySelectorAll('.rec2-card').length,
  }));
  ok('race: latest applied state wins', !afterRace.chips.includes('Selangor') &&
    !afterRace.chips.includes('RM 8000 max'), afterRace.chips.join('|'));
  ok('race: results match latest request', afterRace.cards === 3, String(afterRace.cards));

  // --- Clear ------------------------------------------------------------------
  await page.click('button:has-text("Clear")');
  await page.waitForTimeout(900);
  const afterClear = await page.evaluate(() => ({
    chips: document.querySelectorAll('.rec2__chip').length,
    budgetValue: document.querySelector('input[aria-label="Monthly budget (RM)"]')?.value,
    cards: document.querySelectorAll('.rec2-card').length,
  }));
  ok('clear: no chips', afterClear.chips === 0, String(afterClear.chips));
  ok('clear: inputs empty', afterClear.budgetValue === '');
  ok('clear: defaults returned', afterClear.cards === 3, String(afterClear.cards));

  // --- Narrow viewport overflow ----------------------------------------------
  await page.setViewportSize({ width: 390, height: 900 });
  await page.waitForTimeout(600);
  const overflow = await page.evaluate(
    () => document.scrollingElement.scrollWidth <= window.innerWidth + 1,
  );
  ok('no horizontal overflow at 390px', overflow);

  await context.close();
  await browser.close();

  const passed = checks.filter((c) => c.pass).length;
  console.log(`\nprobe_recommendation_filters: ${passed}/${checks.length} checks passed`);
  const failed = checks.filter((c) => !c.pass);
  if (failed.length) {
    console.log('FAILED:', failed.map((f) => f.name).join(' | '));
    process.exitCode = 1;
  }
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
