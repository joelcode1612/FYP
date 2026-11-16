// Screenshot the redesigned Assessment tab (/entrepreneur/assessments) with a
// controlled fixture, so the three visible surfaces render:
//   1. the listing table  — completed + in-progress + just-started rows
//   2. the create dialog  — saved-property picker, "0 of 3 selected"
//   3. the empty state    — no records at all
//
// Assessment payloads reuse the same shape the live /api/v1/assessments/me
// endpoint returns (and the same fixture properties the report-selector shots
// used). Usage: node tool/shot_assessments_listing.js <url-base> <outdir>
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const { installHarnessSession, FIXTURE } = require('./session_harness');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

function stage(key, number, title, status, completedAt) {
  return { key, number, title, status, completed_at: completedAt || null, unavailable_reason: null };
}

// Stage titles match the workspace's own five-stage vocabulary.
const STAGES_DONE = [
  stage('select_property', 1, 'Select property', 'complete', '2026-11-01T09:00:00Z'),
  stage('business_requirements', 2, 'Business preferences', 'complete', '2026-11-03T10:00:00Z'),
  stage('location_evidence', 3, 'Location evidence', 'complete', '2026-11-06T11:00:00Z'),
  stage('ai_explanation', 4, 'AI explanation', 'complete', '2026-11-09T12:00:00Z'),
  stage('assessment_report', 5, 'Assessment report', 'complete', '2026-11-12T13:00:00Z'),
];
const STAGES_MID = [
  stage('select_property', 1, 'Select property', 'complete', '2026-11-12T09:00:00Z'),
  stage('business_requirements', 2, 'Business preferences', 'complete', '2026-11-13T10:00:00Z'),
  stage('location_evidence', 3, 'Location evidence', 'current'),
  stage('ai_explanation', 4, 'AI explanation', 'incomplete'),
  stage('assessment_report', 5, 'Assessment report', 'incomplete'),
];
const STAGES_NEW = [
  stage('select_property', 1, 'Select property', 'current'),
  stage('business_requirements', 2, 'Business preferences', 'incomplete'),
  stage('location_evidence', 3, 'Location evidence', 'incomplete'),
  stage('ai_explanation', 4, 'AI explanation', 'incomplete'),
  stage('assessment_report', 5, 'Assessment report', 'incomplete'),
];

function record(fixture, i, overrides) {
  const prop = fixture.rows[i % fixture.rows.length];
  return {
    assessment_id: `as-fix-${i + 1}`,
    property_id: prop.id,
    status: 'in_progress',
    current_stage: 1,
    current_stage_key: 'select_property',
    completed_stages: 0,
    total_stages: 5,
    progress_percent: 0,
    report_available: false,
    requirements: null,
    requirements_version: 0,
    stages: STAGES_NEW,
    capabilities: {},
    next_action: {},
    property: prop,
    created_at: '2026-11-15T08:00:00Z',
    updated_at: '2026-11-15T08:00:00Z',
    ...overrides,
  };
}

(async () => {
  const [, , baseArg, outArg] = process.argv;
  const base = baseArg || 'http://127.0.0.1:8091';
  const outdir = outArg || 'tool/screenshots';
  fs.mkdirSync(outdir, { recursive: true });

  const fixture = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
  const records = [
    record(fixture, 0, {
      assessment_id: 'as-1f84c2-completed',
      status: 'completed',
      current_stage: 5,
      current_stage_key: 'assessment_report',
      completed_stages: 5,
      progress_percent: 100,
      report_available: true,
      requirements: { business_type: 'Cafe' },
      requirements_version: 3,
      stages: STAGES_DONE,
      updated_at: '2026-11-12T13:00:00Z',
    }),
    record(fixture, 1, {
      assessment_id: 'as-2d57ba-in-progress',
      current_stage: 3,
      current_stage_key: 'location_evidence',
      completed_stages: 2,
      progress_percent: 40,
      stages: STAGES_MID,
      updated_at: '2026-11-14T16:20:00Z',
    }),
    record(fixture, 2, {
      assessment_id: 'as-3ac91d-just-started',
      updated_at: '2026-11-15T08:00:00Z',
    }),
  ];

  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-sandbox', '--no-proxy-server'],
  });
  const errors = [];

  async function newPage() {
    const ctx = await browser.newContext({
      viewport: { width: 1440, height: 1000 },
      deviceScaleFactor: 1,
      bypassCSP: true,
    });
    const page = await ctx.newPage();
    page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
    page.on('console', (m) => {
      if (m.type() === 'error') errors.push('console: ' + m.text());
    });
    await installHarnessSession(page, { role: 'entrepreneur' });
    // Registered AFTER the harness's catch-all /api/** route, so this handler
    // wins for the assessments endpoint (Playwright: last route wins).
    return page;
  }

  // --- 1. the listing table ------------------------------------------------
  const page = await newPage();
  await page.route('**/api/v1/assessments/me**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ data: records, meta: { total: records.length } }),
    }),
  );
  await page.goto(`${base}/entrepreneur/assessments`, {
    waitUntil: 'networkidle',
    timeout: 30000,
  });
  await page.waitForSelector('.asw-entry', { timeout: 15000 });
  await page.waitForSelector('.asw-ecard', { timeout: 15000 });
  await page.waitForTimeout(600);
  await page.screenshot({
    path: path.join(outdir, 'assessments_listing.png'),
    fullPage: true,
  });

  // --- 2. the create dialog --------------------------------------------------
  await page
    .locator('.page-head__actions button', { hasText: 'Create assessment' })
    .click();
  await page.waitForSelector('.overlay .dialog', { timeout: 15000 });
  await page.waitForTimeout(600);
  await page.screenshot({
    path: path.join(outdir, 'assessments_create_dialog.png'),
    fullPage: false,
  });
  await page.context().close();

  // --- 3. the delete confirmation dialog ------------------------------------
  const page3 = await newPage();
  await page3.route('**/api/v1/assessments/me**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ data: records, meta: { total: records.length } }),
    }),
  );
  await page3.goto(`${base}/entrepreneur/assessments`, {
    waitUntil: 'networkidle',
    timeout: 30000,
  });
  await page3.waitForSelector('.asw-ecard', { timeout: 15000 });
  await page3.locator('.asw-ecard__remove').first().click();
  await page3.waitForSelector('.overlay .dialog', { timeout: 15000 });
  await page3.waitForTimeout(600);
  await page3.screenshot({
    path: path.join(outdir, 'assessments_delete_dialog.png'),
    fullPage: false,
  });
  await page3.context().close();

  // --- 3. the empty state ------------------------------------------------------
  const page2 = await newPage();
  await page2.route('**/api/v1/assessments/me**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ data: [], meta: { total: 0 } }),
    }),
  );
  await page2.goto(`${base}/entrepreneur/assessments`, {
    waitUntil: 'networkidle',
    timeout: 30000,
  });
  await page2.waitForSelector('.asw-entry', { timeout: 15000 });
  await page2.waitForSelector('.empty', { timeout: 15000 });
  await page2.waitForTimeout(600);
  await page2.screenshot({
    path: path.join(outdir, 'assessments_empty.png'),
    fullPage: true,
  });
  await page2.context().close();

  // --- 4. the IN-PLACE workspace swap (user request: row clicks change the
  // page's content instead of navigating) ------------------------------------
  // Clicking "Continue questionnaire" on the in-progress row must render the
  // workspace checkpoint INSIDE /entrepreneur/assessments — the URL must NOT
  // change — and "Back to assessments" must restore the listing.
  const page4 = await newPage();
  await page4.route('**/api/v1/assessments/me**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ data: records, meta: { total: records.length } }),
    }),
  );
  const wsRecord = {
    ...records[1],
    requirements_version: 3,
    requirements: {
      fnb_concept: 'cafe_coffee_shop',
      service_model: 'dine_in',
      target_customers: ['office_workers', 'students'],
      recommendation_priority: 'easy_customer_accessibility',
      space_size_preference: 'standard_business_space',
    },
    next_action: {
      kind: 'continue',
      stage_key: 'location_evidence',
      label: 'Review the location evidence',
    },
  };
  await page4.route('**/api/v1/assessments/by-property/**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ assessment: wsRecord }),
    }),
  );
  // Stage 3's evidence read — top-level payload, same shape as the endpoint.
  await page4.route('**/api/v1/catalog/properties/**/evidence**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        property_id: records[1].property_id,
        available: true,
        analysis_status: 'complete',
        reference_coverage: '1 km walking catchment',
        feature_snapshot_at: '2026-10-30',
        inventory_snapshot_at: '2026-10-30',
        data_completeness_pct: 94,
        self_exclusion_status: 'applied',
        district: 'Hulu Langat',
        state_dosm: 'Selangor',
        coordinate_quality: 'rooftop',
        join_status: {
          property: 'matched',
          demand: 'matched',
          accessibility: 'matched',
          district_income: 'matched',
        },
        groups: [
          {
            key: 'competitor_pressure',
            label: 'Competitor pressure',
            metrics: [
              { key: 'fnb_competitors_1000m', label: 'F&B competitors within 1 km', unit: 'count', value: 47, status: 'available' },
              { key: 'fnb_density_index', label: 'Competitor density index', unit: 'ratio', value: 35.4, status: 'available' },
            ],
          },
          {
            key: 'catchment_demand',
            label: 'Catchment demand',
            metrics: [
              { key: 'pop_total_1km', label: 'People living within 1 km', unit: 'people', value: 31366, status: 'available' },
              { key: 'avg_income_1km', label: 'Average household income within 1 km', unit: 'RM/month', value: 8837, status: 'available' },
            ],
          },
          {
            key: 'accessibility',
            label: 'Accessibility',
            metrics: [
              { key: 'nearest_transit_walk_m', label: 'Nearest public transport (walk)', unit: 'm', value: 1100, status: 'available' },
              { key: 'parking_bays_500m', label: 'Parking bays within 500 m', unit: 'count', value: null, status: 'unavailable' },
            ],
          },
        ],
      }),
    }),
  );
  await page4.goto(`${base}/entrepreneur/assessments`, {
    waitUntil: 'networkidle',
    timeout: 30000,
  });
  await page4.waitForSelector('.asw-ecard', { timeout: 15000 });
  const urlBefore = page4.url();
  // Select the in-progress card, then take the detail panel's primary action.
  await page4.locator('.asw-ecard', { hasText: 'In progress' }).first().click();
  await page4.locator('.asw-entry__detailactions .btn').first().click();
  // The workspace swaps in at the record's OWN progress step (the fixture
  // record is at step 3, so the Location evidence checkpoint opens) — and
  // the URL is unchanged (no navigation).
  await page4.waitForSelector('.sw-assessment-journey', { timeout: 15000 });
  await page4.waitForTimeout(600);
  if (page4.url() !== urlBefore) {
    throw new Error(`URL changed after in-place open: ${page4.url()}`);
  }
  await page4.screenshot({
    path: path.join(outdir, 'assessments_inplace_open.png'),
    fullPage: true,
  });

  // The stepper switches checkpoints in place: step 2 opens the questionnaire
  // without any navigation.
  await page4
    .locator('button[aria-label^="Step 2:"]')
    .click();
  await page4.waitForSelector('.asw-qlayout', { timeout: 15000 });
  await page4.waitForTimeout(600);
  await page4.screenshot({
    path: path.join(outdir, 'assessments_inplace_questionnaire.png'),
    fullPage: true,
  });

  // Back to assessments restores the listing in the same page.
  await page4
    .locator('.asw-inline-detail__actions button', {
      hasText: 'Back to assessments',
    })
    .click();
  await page4.waitForSelector('.asw-entry', { timeout: 15000 });
  await page4.waitForSelector('.asw-ecard', { timeout: 15000 });
  await page4.waitForTimeout(600);
  await page4.screenshot({
    path: path.join(outdir, 'assessments_inplace_back_to_list.png'),
    fullPage: true,
  });
  await page4.context().close();

  console.log('saved screenshots in', outdir);
  console.log(errors.length ? errors.join('\n') : 'no console/page errors');
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
