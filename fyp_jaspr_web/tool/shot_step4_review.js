// Step 4 (research question review) — capture the default view plus the
// decided / reasoning / add-question states, so the reference parity can be
// checked without a human clicking through.
// Usage: node tool/shot_step4_review.js <url-base> <outdir>
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const { installHarnessSession, FIXTURE } = require('./session_harness');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

(async () => {
  const [, , baseArg, outArg] = process.argv;
  const base = baseArg || 'http://127.0.0.1:8095';
  const outdir = outArg || 'build/shots';
  fs.mkdirSync(outdir, { recursive: true });

  const fixture = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
  const prop = fixture.rows[1 % fixture.rows.length];

  const record = {
    assessment_id: 'as-ws-preview',
    property_id: prop.id,
    status: 'in_progress',
    current_stage: 4,
    current_stage_key: 'ai_explanation',
    completed_stages: 3,
    total_stages: 5,
    progress_percent: 60,
    report_available: false,
    requirements: {
      fnb_concept: 'cafe_coffee_shop',
      service_model: 'dine_in',
      target_customers: ['office_workers', 'students'],
      recommendation_priority: 'easy_customer_accessibility',
      space_size_preference: 'standard_business_space',
    },
    requirements_version: 3,
    stages: [
      { key: 'select_property', number: 1, title: 'Select property', status: 'complete', completed_at: '2026-11-12T09:00:00Z' },
      { key: 'business_requirements', number: 2, title: 'Business preferences', status: 'complete', completed_at: '2026-11-13T10:00:00Z' },
      { key: 'location_evidence', number: 3, title: 'Location evidence', status: 'complete', completed_at: '2026-11-14T16:20:00Z' },
      { key: 'ai_explanation', number: 4, title: 'AI explanation', status: 'current' },
      { key: 'assessment_report', number: 5, title: 'Assessment report', status: 'incomplete' },
    ],
    capabilities: {
      model: { available: true, model_version: 'pu-expanded64' },
      explanation: { available: true, model_version: 'pu-expanded64' },
      report: { available: true },
    },
    next_action: { kind: 'continue', stage_key: 'ai_explanation', label: 'Review the research questions' },
    property: prop,
    created_at: '2026-11-12T09:00:00Z',
    updated_at: '2026-11-14T16:20:00Z',
  };

  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-sandbox', '--no-proxy-server'],
  });
  const errors = [];

  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 1100 },
    deviceScaleFactor: 1,
    bypassCSP: true,
  });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push('console: ' + m.text());
  });
  await installHarnessSession(page, { role: 'entrepreneur' });
  await page.route('**/api/v1/assessments/by-property/**', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ assessment: record }) }),
  );
  await page.route('**/api/v1/catalog/properties/**', (route) => {
    const url = new URL(route.request().url());
    if (url.pathname.includes('/evidence')) return route.fallback();
    const id = decodeURIComponent(url.pathname.split('/').pop());
    const row = fixture.rows.find((r) => r.id === id);
    if (!row) return route.fulfill({ status: 404, body: '{}' });
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(row) });
  });
  await page.route('**/api/v1/catalog/properties/**/evidence**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        property_id: prop.id,
        available: true,
        analysis_status: 'complete',
        reference_coverage: '1 km walking catchment',
        data_completeness_pct: 94,
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

  const id = encodeURIComponent(prop.id);
  await page.goto(`${base}/entrepreneur/assessments?id=${id}&stage=ai_explanation`, {
    waitUntil: 'networkidle',
    timeout: 30000,
  });
  await page.waitForSelector('.asw-rqr', { timeout: 15000 });
  await page.waitForTimeout(1400);

  await page.screenshot({ path: path.join(outdir, 'step4_review.png'), fullPage: true });

  // Approve the first candidate, reject the second, open its reasoning.
  const approve = page.locator('.asw-rqr__decopt.is-approve');
  const reject = page.locator('.asw-rqr__decopt.is-reject');
  await approve.nth(0).click();
  await reject.nth(1).click();
  await page.locator('.asw-rqr__toggle').nth(1).click();
  await page.waitForTimeout(400);
  await page.screenshot({ path: path.join(outdir, 'step4_review_decided.png'), fullPage: true });

  // The "Decided" tab shows only the reviewed questions.
  await page.locator('.asw-rqr__tab').nth(1).click();
  await page.waitForTimeout(300);
  await page.screenshot({ path: path.join(outdir, 'step4_review_tab_decided.png'), fullPage: true });

  // The inline add-a-question form.
  await page.locator('.asw-rqr__tab').nth(0).click();
  await page.locator('.asw-rqr__add').click();
  await page.waitForTimeout(300);
  await page.screenshot({ path: path.join(outdir, 'step4_review_add.png'), fullPage: true });

  console.log('saved 4 step-4 screenshots in', outdir);
  console.log(errors.length ? errors.join('\n') : 'no console/page errors');
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
