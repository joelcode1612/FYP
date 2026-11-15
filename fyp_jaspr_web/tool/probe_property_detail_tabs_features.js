/* Headless verification of the Property Detail insight-tab panel borders and
 * the business-match feature-availability strip.
 *
 * Runs through the session_harness stand-in bridge + fixture catalogue, with
 * the insights and evidence endpoints stubbed so the page renders with real
 * payload shapes. The insights stub includes a `feature_coverage` block, so
 * the availability strip's counts are the backend's numbers (the probe then
 * swaps in a partial-coverage payload and reloads to prove the UI never
 * hardcodes a total).
 *
 * Checks:
 *   A. Tab panel: bordered white body attached under the tab bar, single outer
 *      border (bar + panel form one container), active-tab underline intact.
 *   B. Tab switching keeps the bordered panel and aria state consistent.
 *   C. Feature strip: real coverage text, category chips, expandable details,
 *      honest note; partial coverage renders the true smaller number plus the
 *      "not measured" list.
 *   D. Mobile: panel keeps its padding; rows collapse to one column.
 *   E. No fatal console errors.
 */
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1243/chrome-win64/chrome.exe';
const BASE = 'http://127.0.0.1:8090';
const PROPERTY_ID = 'EP-01051';
const URL = `${BASE}/entrepreneur/property-detail?id=${PROPERTY_ID}&businessType=cafe`;

const checks = [];
function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
}

// A realistic slice of the PU insights payload: 47/47 coverage while the SHAP
// factor list carries a representative subset across all six categories. The
// strip's "N of M" text must come from feature_coverage, not factor count.
function insightsPayload(available, total, missing) {
  const f = (technical, label, value, valueDisplay, unit, category, categoryLabel, contribution) => ({
    technical,
    label,
    contribution,
    direction: contribution > 0 ? 'increases' : 'decreases',
    value,
    value_display: valueDisplay,
    unit,
    is_distance: unit === 'm',
    category,
    category_label: categoryLabel,
  });
  const factors = [
    f('pop_500m', 'People living within 500 m', 13656, '13,656 people', 'people', 'population', 'Population', 0.021),
    f('pop_1000m', 'People living within 1 km', 23131, '23,131 people', 'people', 'population', 'Population', 0.014),
    f('pop_density_500m', 'Population density within 500 m', 8421.3, '8,421.3 people/km²', 'people/km²', 'population', 'Population', 0.006),
    f('office_count_1000m', 'Offices within 1 km', 34, '34 offices', 'offices', 'demand_generators', 'Demand generators', 0.009),
    f('school_count_1000m', 'Schools within 1 km', 7, '7 schools', 'schools', 'demand_generators', 'Demand generators', 0.004),
    f('transit_stops_500m', 'Public transport stops within 500 m', 5, '5 stops', 'stops', 'accessibility', 'Accessibility and transportation', 0.011),
    f('nearest_transit_walk_m', 'Walk to nearest public transport', 514, '514 m', 'm', 'accessibility', 'Accessibility and transportation', -0.003),
    f('road_intersection_500m', 'Road junctions within 500 m', 12, '12 junctions', 'junctions', 'accessibility', 'Accessibility and transportation', 0.002),
    f('parking_facilities_500m', 'Parking facilities within 500 m', 4, '4 facilities', 'facilities', 'parking', 'Parking', 0.005),
    f('parking_capacity_500m', 'Recorded parking bays within 500 m', 180, '180 bays', 'bays', 'parking', 'Parking', 0.003),
    f('cafe_count_500m', 'Cafés within 500 m', 9, '9 cafés', 'cafés', 'competitors', 'Competitors', -0.008),
    f('restaurant_count_500m', 'Restaurants within 500 m', 17, '17 restaurants', 'restaurants', 'competitors', 'Competitors', -0.004),
    f('competitor_count_500m', 'F&B businesses within 500 m', 31, '31 F&B businesses', 'F&B businesses', 'competitors', 'Competitors', -0.006),
    f('residential_buildings_500m', 'Residential buildings within 500 m', 10, '10 buildings', 'buildings', 'residential', 'Residential environment', 0.007),
    f('avg_household_500m', 'Average household size within 500 m', 3.4, '3.4 people', 'people', 'residential', 'Residential environment', 0.001),
  ];
  return {
    property_id: PROPERTY_ID,
    model: {
      name: 'pu_model',
      layer1_model: 'pu_model',
      version: 'baseline_47',
      notes: [],
    },
    score: {
      available: true,
      label: 'Location Fit',
      value: 62,
      scale: 100,
      raw: 0.6231,
      band: 'research association index',
      meaning: 'Research association, not a business-success probability.',
      kind_label: 'Location similarity to operating F&B sites',
      source: 'stored_catalogue_prediction',
      source_label: 'Stored score · verified by live inference',
    },
    explanation: {
      available: true,
      explainer: 'permutation SHAP',
      model_version: 'baseline_47',
      feature_count: total,
      base_value: 0.5,
      output: 0.6231,
      additivity_ok: true,
      background_size: 200,
      factors,
      strongest_supporting: factors.slice(0, 3),
      strongest_lowering: factors.slice(-2),
    },
    categories: [],
    feature_coverage: {
      available_features: available,
      feature_count: total,
      missing_features: missing,
    },
    map: { layers: [] },
    panorama: { available: false, status: 'unavailable' },
  };
}

function evidencePayload() {
  const metric = (key, label, unit, value) => ({
    key, label, unit, value, status: value == null ? 'unavailable' : 'available',
  });
  return {
    property_id: PROPERTY_ID,
    available: true,
    analysis_status: 'complete',
    reference_coverage: 'full',
    feature_snapshot_at: '2026-11-01T00:00:00Z',
    data_completeness_pct: 100,
    groups: [
      { key: 'population', label: 'Population', metrics: [
        metric('pop_500m', 'People within 500 m', 'people', 13656),
        metric('pop_1000m', 'People within 1 km', 'people', 23131),
      ] },
      { key: 'accessibility', label: 'Accessibility', metrics: [
        metric('nearest_transit_walk_m', 'Walk to nearest public transport', 'm', 514),
      ] },
      { key: 'commerce', label: 'Commerce', metrics: [
        metric('retail_pois_1000m', 'Shops within 1 km', 'shops', 26),
        metric('cafe_count_500m', 'Cafés within 500 m', 'cafés', 9),
      ] },
      { key: 'parking', label: 'Parking', metrics: [
        metric('parking_facilities_500m', 'Parking facilities within 500 m', 'facilities', 4),
      ] },
    ],
    district_statistics: { available: false },
  };
}

(async () => {
  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-proxy-server', '--no-sandbox'],
  });
  const page = await browser.newPage({ viewport: { width: 1440, height: 950 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push('console: ' + m.text().slice(0, 200));
  });

  await installHarnessSession(page, { role: 'entrepreneur' });

  const fixtureRows = JSON.parse(require('fs').readFileSync(
    require('path').join(__dirname, '..', '..', 'test', '.data', 'jaspr_catalog_fixture.json'),
    'utf8',
  )).rows;
  const propertyRow = fixtureRows.find((r) => r.id === PROPERTY_ID);
  if (!propertyRow) throw new Error(`${PROPERTY_ID} missing from the catalog fixture`);
  await page.route(`**/api/v1/catalog/properties/${PROPERTY_ID}`, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(propertyRow),
    }),
  );
  let currentCoverage = { available: 47, total: 47, missing: [] };
  const insightsRegex = new RegExp(`/api/v1/catalog/properties/${PROPERTY_ID}/insights`);
  await page.route(insightsRegex, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(insightsPayload(currentCoverage.available, currentCoverage.total, currentCoverage.missing)),
    }),
  );
  const evidenceRegex = new RegExp(`/api/v1/catalog/properties/${PROPERTY_ID}/evidence`);
  await page.route(evidenceRegex, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(evidencePayload()),
    }),
  );

  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 45000 });
  await page.waitForSelector('.sw-info__panel', { timeout: 20000 });
  await page.waitForSelector('.sw-matchfeat', { timeout: 20000 });
  await page.waitForTimeout(1200);

  // --- A. tab panel borders -------------------------------------------------
  const panelStyle = await page.locator('.sw-info__panel').first().evaluate((el) => {
    const s = getComputedStyle(el);
    return {
      bg: s.backgroundColor,
      borderTop: s.borderTopWidth,
      borderLeft: s.borderLeftWidth,
      borderLeftColor: s.borderLeftColor,
      radiusBL: s.borderBottomLeftRadius,
      radiusBR: s.borderBottomRightRadius,
      shadow: s.boxShadow,
      padding: s.padding,
    };
  });
  check('panel background white', panelStyle.bg === 'rgb(255, 255, 255)', panelStyle.bg);
  check('panel top border removed (connects to tab bar)', panelStyle.borderTop === '0px', panelStyle.borderTop);
  check('panel side border 1px', panelStyle.borderLeft === '1px', panelStyle.borderLeft);
  check(
    'panel border colour #dbe5f2',
    panelStyle.borderLeftColor === 'rgb(219, 229, 242)',
    panelStyle.borderLeftColor,
  );
  check('panel bottom radius 17px', panelStyle.radiusBL === '17px' && panelStyle.radiusBR === '17px', `${panelStyle.radiusBL}/${panelStyle.radiusBR}`);
  check('panel has restrained shadow', panelStyle.shadow !== 'none' && panelStyle.shadow.includes('rgba(20, 43, 72'), panelStyle.shadow);

  const tabsStyle = await page.locator('.sw-info__tabs').evaluate((el) => {
    const s = getComputedStyle(el);
    return { borderLeft: s.borderLeftWidth, radiusTL: s.borderTopLeftRadius, bg: s.backgroundColor };
  });
  check('tab bar side border completes the container', tabsStyle.borderLeft === '1px', tabsStyle.borderLeft);
  check('tab bar top radius aligned (17px)', tabsStyle.radiusTL === '17px', tabsStyle.radiusTL);

  const flush = await page.evaluate(() => {
    const tabs = document.querySelector('.sw-info__tabs');
    const panel = document.querySelector('.sw-info__panel');
    if (!tabs || !panel) return null;
    return Math.abs(tabs.getBoundingClientRect().bottom - panel.getBoundingClientRect().top);
  });
  check('panel attaches flush under the tab bar', flush !== null && flush <= 1, flush);

  const sectionBorder = await page.locator('.sw-info').first().evaluate((el) => {
    const s = getComputedStyle(el);
    return `${s.borderTopWidth}/${s.borderLeftWidth}`;
  });
  check('no duplicate outer border on the section', sectionBorder === '0px/0px', sectionBorder);

  const activeTab = await page.locator('.sw-info__tab.is-active').evaluate((el) => {
    const s = getComputedStyle(el);
    return { underline: s.borderBottomColor, text: s.color };
  });
  check('active tab underline retained (blue)', activeTab.underline === 'rgb(29, 78, 216)', activeTab.underline);
  check('active tab text colour retained', activeTab.text === 'rgb(29, 78, 216)', activeTab.text);
  check('active tab count', (await page.locator('.sw-info__tab.is-active').count()) === 1);
  const iconCount = await page.locator('.sw-info__glyph').count();
  check('distinct tab icons preserved', iconCount === 3, iconCount);

  // --- B. tab switching -------------------------------------------------------
  await page.locator('#sw-info-tab-score').click();
  await page.waitForTimeout(600);
  check(
    'score tab selected',
    (await page.locator('#sw-info-tab-score').getAttribute('aria-selected')) === 'true',
  );
  const scorePanelStyle = await page.locator('#sw-info-panel-score').evaluate((el) => {
    const s = getComputedStyle(el);
    return { borderLeft: s.borderLeftWidth, borderLeftColor: s.borderLeftColor, bg: s.backgroundColor, radiusBL: s.borderBottomLeftRadius };
  });
  check(
    'score panel keeps the bordered body',
    scorePanelStyle.borderLeft === '1px' && scorePanelStyle.borderLeftColor === 'rgb(219, 229, 242)' && scorePanelStyle.bg === 'rgb(255, 255, 255)',
    JSON.stringify(scorePanelStyle),
  );
  await page.locator('#sw-info-tab-business').click();
  await page.waitForTimeout(500);
  check(
    'business tab reselects',
    (await page.locator('#sw-info-tab-business').getAttribute('aria-selected')) === 'true',
  );

  // --- C. feature availability strip ------------------------------------------
  const strip = page.locator('.sw-matchfeat');
  check('feature strip rendered exactly once', (await strip.count()) === 1, await strip.count());
  const countText = (await page.locator('.sw-matchfeat__count').textContent()).trim();
  check(
    'coverage text is the backend count',
    countText === '47 of 47 location features available',
    countText,
  );
  check(
    'complete badge tone',
    (await page.locator('.sw-matchfeat__count.is-complete').count()) === 1,
  );
  const chips = await page.locator('.sw-matchfeat__group').allTextContents();
  check('category chips rendered', chips.length >= 5, chips.join(' | '));
  check(
    'chip wording uses measured counts',
    chips.every((c) => c.includes('measured')),
    chips.join(' | '),
  );

  const toggle = page.locator('.sw-matchfeat__toggle');
  check('details toggle exists', (await toggle.count()) === 1);
  check('details collapsed by default', (await toggle.getAttribute('aria-expanded')) === 'false');
  const detailsDisplay0 = await page.locator('#sw-matchfeat-details').evaluate((el) => getComputedStyle(el).display);
  check('details hidden while collapsed', detailsDisplay0 === 'none', detailsDisplay0);

  await toggle.click();
  await page.waitForTimeout(450);
  check('click expands details', (await toggle.getAttribute('aria-expanded')) === 'true');
  check('toggle label flips', (await toggle.textContent()).includes('Hide location details'));
  const detailsDisplay1 = await page.locator('#sw-matchfeat-details').evaluate((el) => getComputedStyle(el).display);
  check('details visible when open', detailsDisplay1 !== 'none', detailsDisplay1);
  const rows = await page.locator('.sw-matchfeat__row').count();
  check('feature rows rendered from factors', rows >= 10, rows);
  const rowLabels = await page.locator('.sw-matchfeat__rowlabel').allTextContents();
  check(
    'row labels are entrepreneur-facing',
    rowLabels.length > 0 && rowLabels.every((l) => l && !l.includes('_')),
    rowLabels.slice(0, 4).join(' | '),
  );
  const groups = await page.locator('.sw-matchfeat__detailgroup').count();
  check('details grouped by category', groups >= 5, groups);
  const noteText = (await page.locator('.sw-matchfeat__note').textContent()).trim();
  check(
    'availability is not a suitability claim',
    noteText.includes('not a measure of how well this location matches'),
    noteText.slice(0, 80),
  );
  check('no "not measured" block when coverage complete', (await page.locator('.sw-matchfeat__missing').count()) === 0);

  await toggle.click();
  await page.waitForTimeout(400);
  check('click collapses details again', (await toggle.getAttribute('aria-expanded')) === 'false');

  // --- C2. partial coverage: reload with a reduced payload ---------------------
  currentCoverage = {
    available: 41,
    total: 47,
    missing: ['frontage_m', 'depth_m', 'land_area_sqm', 'toilets_count', 'corner_lot_flag', 'floor_level_num'],
  };
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.sw-matchfeat', { timeout: 20000 });
  await page.waitForTimeout(1000);
  const partialText = (await page.locator('.sw-matchfeat__count').textContent()).trim();
  check(
    'partial coverage shows the true smaller number',
    partialText === '41 of 47 location features available',
    partialText,
  );
  check('partial badge tone', (await page.locator('.sw-matchfeat__count.is-partial').count()) === 1);
  await page.locator('.sw-matchfeat__toggle').click();
  await page.waitForTimeout(450);
  const missingBlock = page.locator('.sw-matchfeat__missing');
  check('missing-features block renders when incomplete', (await missingBlock.count()) === 1);
  const missingText = (await missingBlock.textContent()) || '';
  check('missing list is entrepreneur-friendly', missingText.includes('frontage m') && missingText.includes('depth m'), missingText.slice(0, 120));

  // --- D. mobile ---------------------------------------------------------------
  await page.setViewportSize({ width: 390, height: 844 });
  await page.waitForTimeout(500);
  const mobPanel = await page.locator('.sw-info__panel').first().evaluate((el) => {
    const s = getComputedStyle(el);
    return { padLeft: s.paddingLeft, borderLeft: s.borderLeftWidth, radiusBL: s.borderBottomLeftRadius };
  });
  check(
    'mobile: panel keeps padding, border and radius',
    mobPanel.padLeft === '14px' && mobPanel.borderLeft === '1px' && mobPanel.radiusBL === '17px',
    JSON.stringify(mobPanel),
  );
  const mobStripPad = await page.locator('.sw-matchfeat').evaluate((el) => getComputedStyle(el).paddingLeft);
  check('mobile: strip padding applied', mobStripPad === '16px', mobStripPad);
  const mobCols = await page
    .locator('.sw-matchfeat__rows')
    .first()
    .evaluate((el) => getComputedStyle(el).gridTemplateColumns.split(' ').length);
  check('mobile: detail rows single column', mobCols === 1, mobCols);
  const mobOverflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  check('mobile: no horizontal overflow', mobOverflow <= 1, mobOverflow);

  // --- E. console ---------------------------------------------------------------
  check(
    'no fatal console errors',
    errors.filter((e) => !e.includes('favicon') && !e.includes('net::') && !e.includes('404') && !e.includes('Failed to load resource')).length === 0,
    errors.slice(0, 3).join(' | '),
  );

  const failed = checks.filter((c) => !c.ok);
  console.log(JSON.stringify({ passed: checks.length - failed.length, total: checks.length, failed }, null, 2));
  await browser.close();
  process.exit(failed.length ? 1 : 0);
})().catch((e) => {
  console.error('PROBE_FAILED', e);
  process.exit(1);
});
