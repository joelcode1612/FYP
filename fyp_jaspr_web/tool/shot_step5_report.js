// Step 5 (assessment report) — capture the assembled report document.
//
// The report endpoint is mocked with a payload that has BOTH available and
// unavailable sections, so the screenshot proves the honest-empty states
// render instead of zeros, not just the happy path.
//
// Usage: node tool/shot_step5_report.js <url-base> <outdir>
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const { installHarnessSession, FIXTURE } = require('./session_harness');

const EXE =
  process.env.CHROME_PATH ||
  'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

const GROUPS = [
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
];

(async () => {
  const [, , baseArg, outArg] = process.argv;
  const base = baseArg || 'http://127.0.0.1:8096';
  const outdir = outArg || 'build/shots';
  fs.mkdirSync(outdir, { recursive: true });

  const fixture = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
  const prop = fixture.rows[1 % fixture.rows.length];

  const record = {
    assessment_id: 'as-ws-preview',
    property_id: prop.id,
    status: 'in_progress',
    current_stage: 5,
    current_stage_key: 'assessment_report',
    completed_stages: 4,
    total_stages: 5,
    progress_percent: 80,
    report_available: true,
    requirements: {
      fnb_concept: 'cafe_coffee_shop',
      service_model: 'dine_in',
      target_customers: ['office_workers', 'students'],
      recommendation_priority: 'easy_customer_accessibility',
      space_size_preference: 'standard_business_space',
    },
    requirements_version: 3,
    respondent_count: 0,
    response_count: 0,
    stages: [
      { key: 'select_property', number: 1, title: 'Select property', status: 'complete', completed_at: '2026-11-12T09:00:00Z' },
      { key: 'business_requirements', number: 2, title: 'Business preferences', status: 'complete', completed_at: '2026-11-13T10:00:00Z' },
      { key: 'location_evidence', number: 3, title: 'Location evidence', status: 'complete', completed_at: '2026-11-14T16:20:00Z' },
      { key: 'ai_explanation', number: 4, title: 'AI explanation', status: 'complete', completed_at: '2026-11-15T11:05:00Z' },
      { key: 'assessment_report', number: 5, title: 'Assessment report', status: 'current' },
    ],
    capabilities: {
      model: { available: true, model_version: 'pu-expanded64' },
      explanation: { available: true, model_version: 'pu-expanded64' },
      report: { available: true },
    },
    next_action: { kind: 'view_report', stage_key: 'assessment_report', label: 'Review the report' },
    property: prop,
    created_at: '2026-11-12T09:00:00Z',
    updated_at: '2026-11-15T11:05:00Z',
  };

  // What GET /api/v1/assessments/{id}/report actually returns: every section
  // carries its own availability flag, and the evidence/explanation blocks are
  // marked unavailable here on purpose so the page has to show a reason.
  const report = {
    assessment_id: record.assessment_id,
    property_id: record.property_id,
    status: record.status,
    generated_at: '2026-11-16T05:46:00Z',
    requirements_version: 3,
    questionnaire: { available: true, data: record.requirements },
    property: {
      available: true,
      data: {
        property_id: prop.id,
        name: prop.title || prop.name,
        property_type: prop.property_type,
        address: prop.address,
        city: prop.city,
        state: prop.state,
        rental_price: prop.rental_price,
        size_sqft: prop.size_sqft,
      },
    },
    listing_media: { available: true, data: { photos: [{ url: 'a.jpg' }], listing_sources: [{ name: 'iProperty' }] } },
    geospatial_features: { available: true, data: { competitor_count_500m: 47, population_1km: 31366 } },
    evidence_categories: { available: true, data: GROUPS },
    research_association: {
      available: true,
      data: {
        score: 61.4,
        base_value: 0.5,
        model_version: 'expanded64',
        feature_set: 'expanded64',
        score_meaning: 'research_positive_label_association_NOT_business_success_probability',
      },
    },
    explanation: {
      available: false,
      reason: 'No verified SHAP explanation is available for this property.',
    },
    requirement_matching: {
      checks: [
        {
          key: 'affordability',
          label: 'Affordability (monthly rent)',
          verdict: 'match',
          detail: 'Asking RM 4,800 vs ceiling RM 6,000.',
        },
        {
          key: 'floor_area',
          label: 'Floor area requirement',
          verdict: 'mismatch',
          detail: 'Listing 900 sq ft vs minimum 1,200 sq ft.',
        },
        {
          key: 'accessibility',
          label: 'Customer access mode',
          verdict: 'match',
          detail: 'public_transportation supported by measured nearest_transit_walk_m.',
        },
        {
          key: 'competition_context',
          label: 'Competitor context for the chosen concept',
          verdict: 'informational',
          detail: '47 F&B competitors are measured within 500 m; same-concept overlap is not separately measured.',
        },
      ],
      matched: 2,
      mismatched: 1,
      unknown: 0,
      note: 'Constraint checks only. No personalized compatibility percentage is produced because no scoring methodology has been approved.',
    },
    missing_information: [
      'No verified SHAP explanation was produced.',
      'Customer questionnaire responses are not attached to this assessment.',
    ],
    model_information: {
      model: 'pu_model',
      feature_set: 'expanded64',
      explainer: 'permutation_shap',
      research_only: true,
      score_meaning: 'research_positive_label_association_NOT_business_success_probability',
    },
    export: {
      pdf: false,
      reason: 'No server-side PDF generator is configured. The report is complete and printable from the browser; a PDF is not produced.',
    },
    meta: { scores_are_research_indexes: true },
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
  const failed = [];
  page.on('response', (res) => {
    if (res.status() >= 400) failed.push(`${res.status()} ${res.url()}`);
  });
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push('console: ' + m.text());
  });

  await installHarnessSession(page, { role: 'entrepreneur' });
  await page.route('**/api/v1/assessments/by-property/**', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ assessment: record }) }),
  );
  // The report is opened from the assessment card on the list page, so the list
  // has to contain this record. One row, one total, one report.
  await page.route('**/api/v1/assessments/me*', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ data: [record], meta: { total: 1, reports_total: 1 } }),
    }),
  );
  // The report checkpoint is only enterable when readiness says so, so the
  // harness has to answer for it — otherwise the workspace opens the stage-5
  // panel instead of the report and this tool times out. The values below are
  // the ones the server actually returns for this shape: stage 3/4 open once
  // stages 1 and 2 are complete, and stage 5 is always preview-enterable.
  await page.route('**/api/v1/assessments/*/workflow-readiness', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        contract_version: 'sitewise-assessment-workflow/3',
        assessment_id: record.assessment_id,
        stage_1: { complete: true },
        stage_2: { complete: true },
        stage_3: { enterable: true },
        stage_4: { enterable: true },
        stage_5: { preview_enterable: true },
      }),
    }),
  );
  await page.route('**/api/v1/assessments/*/report', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(report) }),
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
        groups: GROUPS,
      }),
    }),
  );

  // The report is not a `?stage=` checkpoint any more: stage 5 opens the
  // customer-questionnaire preview, and the assembled document is reached from
  // the assessment card's "View report" action. Going through that action keeps
  // the harness on the same path a reader takes.
  await page.goto(`${base}/entrepreneur/assessments`, {
    waitUntil: 'networkidle',
    timeout: 30000,
  });
  // A silent timeout here says nothing about *why* the document never appeared,
  // so on failure print what the page actually rendered and which API calls the
  // live server refused — the usual cause is an endpoint this harness does not
  // mock yet.
  try {
    await page.waitForSelector('.asw-ecard__link', { timeout: 15000 });
    await page.locator('.asw-ecard__link').first().click();
    await page.waitForSelector('.asw-rpt', { timeout: 15000 });
  } catch (e) {
    const body = await page.evaluate(() =>
      document.body.innerText.replace(/\n{2,}/g, '\n').slice(0, 700),
    );
    console.error('--- report did not render ---');
    console.error(body);
    console.error('--- refused API calls ---');
    console.error(failed.join('\n') || '(none)');
    throw e;
  }
  await page.waitForTimeout(1200);

  await page.screenshot({ path: path.join(outdir, 'step5_report.png'), fullPage: true });
  // The full-page shot is unreadable at this width, so keep the toolbar and the
  // jump bar on their own at full resolution.
  await page.locator('.asw-rpt__chrome').screenshot({
    path: path.join(outdir, 'step5_report_top.png'),
  });

  // Nine chips do not fit every window. A narrower viewport is captured too, so
  // a clipped or scrolling jump bar is visible in review rather than assumed.
  const narrowTop = async (width, file) => {
    await page.setViewportSize({ width, height: 1100 });
    await page.waitForTimeout(350);
    await page.locator('.asw-rpt__chrome').screenshot({
      path: path.join(outdir, file),
    });
  };
  await narrowTop(1080, 'step5_report_top_1080.png');
  await page.setViewportSize({ width: 1440, height: 1100 });
  await page.waitForTimeout(250);

  // The report is long: capture the mid-document sections separately so each
  // one can be reviewed at a readable size.
  const shotSection = async (sectionId, file) => {
    const el = page.locator(`#${sectionId}`);
    await el.scrollIntoViewIfNeeded();
    await page.waitForTimeout(350);
    await el.screenshot({ path: path.join(outdir, file) });
  };

  await shotSection('asw-rpt-overview', 'step5_report_overview.png');
  await shotSection('asw-rpt-decisions', 'step5_report_decisions.png');
  await shotSection('asw-rpt-evidence', 'step5_report_evidence.png');
  await shotSection('asw-rpt-coverage', 'step5_report_coverage.png');
  await shotSection('asw-rpt-sources', 'step5_report_sources.png');

  // Prove the jump bar actually moves the document.
  await page.locator('.asw-rpt__navlink').nth(6).click();
  await page.waitForTimeout(900);
  await page.screenshot({ path: path.join(outdir, 'step5_report_jump.png') });

  // The Step-4 → report decision flow used to be exercised here, by walking the
  // workspace stepper back to question review and forward again. That path no
  // longer lands on this document: stage 5 now opens the questionnaire preview
  // and the report is a destination of its own, so replaying it here would test
  // a route the report is not reached by.

  const counts = await page.evaluate(() => ({
    sections: document.querySelectorAll('.asw-rpt__section').length,
    navlinks: document.querySelectorAll('.asw-rpt__navlink').length,
    kpis: document.querySelectorAll('.asw-rpt__kpi').length,
    checks: document.querySelectorAll('.asw-rpt__table tbody tr').length,
    empties: document.querySelectorAll('.asw-rpt__empty').length,
    missing: document.querySelectorAll('.asw-rpt__list--warn li').length,
  }));

  console.log('saved step-5 report screenshots in', outdir);
  console.log('dom:', JSON.stringify(counts));
  if (failed.length) console.log('refused:', failed.join(', '));
  console.log(errors.length ? errors.join('\n') : 'no console/page errors');
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
