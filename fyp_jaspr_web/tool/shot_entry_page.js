// The Assessments entry page (two-column list + details), plus the paths that
// leave it: View report (in place), Continue assessment (workspace), and the
// Remove confirmation. Also captures the restored step-5 checkpoint, to prove
// the report document is NOT step 5 any more.
//
// Usage: node tool/shot_entry_page.js <url-base> <outdir>
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const { installHarnessSession, FIXTURE } = require('./session_harness');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

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
];

function reportPayload(record, prop) {
  return {
    assessment_id: record.assessment_id,
    property_id: record.property_id,
    status: record.status,
    generated_at: '2026-11-16T06:14:00Z',
    requirements_version: record.requirements_version,
    questionnaire: { available: true, data: record.requirements },
    property: {
      available: true,
      data: {
        name: prop.title,
        property_type: prop.property_type,
        address: prop.address,
        city: prop.city,
        rental_price: prop.rental_price,
        size_sqft: prop.size_sqft,
      },
    },
    listing_media: { available: true, data: { photos: [{ url: 'a.jpg' }], listing_sources: [{ name: 'iProperty' }] } },
    geospatial_features: { available: true, data: { competitor_count_500m: 47 } },
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
        { key: 'affordability', label: 'Affordability (monthly rent)', verdict: 'match', detail: 'Asking RM 4,800 vs ceiling RM 6,000.' },
        { key: 'floor_area', label: 'Floor area requirement', verdict: 'mismatch', detail: 'Listing 900 sq ft vs minimum 1,200 sq ft.' },
      ],
      matched: 1,
      mismatched: 1,
      unknown: 0,
      note: 'Constraint checks only. No personalized compatibility percentage is produced because no scoring methodology has been approved.',
    },
    missing_information: ['No verified SHAP explanation was produced.'],
    model_information: { model: 'pu_model', feature_set: 'expanded64', research_only: true },
    export: { pdf: false, reason: 'No server-side PDF generator is configured.' },
    meta: { scores_are_research_indexes: true },
  };
}

(async () => {
  const [, , baseArg, outArg] = process.argv;
  const base = baseArg || 'http://127.0.0.1:8097';
  const outdir = outArg || 'build/shots';
  fs.mkdirSync(outdir, { recursive: true });

  const fixture = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
  const prop = fixture.rows[1 % fixture.rows.length];
  const prop2 = fixture.rows[2 % fixture.rows.length];

  const inProgress = {
    assessment_id: 'a3e9391f-d980-422c-ad70-72b012c33e6f',
    property_id: prop.id,
    status: 'in_progress',
    current_stage: 2,
    current_stage_key: 'business_requirements',
    completed_stages: 1,
    total_stages: 5,
    progress_percent: 20,
    report_available: false,
    requirements: {
      fnb_concept: 'cafe_coffee_shop',
      service_model: 'dine_in',
      target_customers: ['office_workers', 'students'],
      recommendation_priority: 'easy_customer_accessibility',
      space_size_preference: 'standard_business_space',
    },
    requirements_version: 3,
    respondent_count: null,
    response_count: null,
    external_source_count: null,
    stages: [
      { key: 'select_property', number: 1, title: 'Select property', status: 'complete', completed_at: '2026-11-12T09:00:00Z' },
      { key: 'business_requirements', number: 2, title: 'Business preferences', status: 'current' },
      { key: 'location_evidence', number: 3, title: 'Location evidence', status: 'incomplete' },
      { key: 'ai_explanation', number: 4, title: 'AI explanation', status: 'incomplete' },
      { key: 'assessment_report', number: 5, title: 'Assessment report', status: 'incomplete' },
    ],
    capabilities: {
      model: { available: true, model_version: 'pu-expanded64' },
      explanation: { available: true, model_version: 'pu-expanded64' },
      report: { available: true },
    },
    next_action: { kind: 'continue', stage_key: 'business_requirements', label: 'Continue the questionnaire' },
    property: prop,
    created_at: '2026-11-12T09:00:00Z',
    updated_at: '2026-11-12T09:00:00Z',
  };

  const completed = {
    ...inProgress,
    assessment_id: '78e0d059-c050-46d8-8569-a528bd415fdc',
    property_id: prop2.id,
    status: 'completed',
    current_stage: 5,
    current_stage_key: 'assessment_report',
    completed_stages: 5,
    total_stages: 5,
    progress_percent: 100,
    report_available: true,
    respondent_count: 12,
    response_count: 9,
    external_source_count: 3,
    stages: [
      { key: 'select_property', number: 1, title: 'Select property', status: 'complete', completed_at: '2026-11-10T09:00:00Z' },
      { key: 'business_requirements', number: 2, title: 'Business preferences', status: 'complete', completed_at: '2026-11-10T10:00:00Z' },
      { key: 'location_evidence', number: 3, title: 'Location evidence', status: 'complete', completed_at: '2026-11-10T11:00:00Z' },
      { key: 'ai_explanation', number: 4, title: 'AI explanation', status: 'complete', completed_at: '2026-11-11T09:00:00Z' },
      { key: 'assessment_report', number: 5, title: 'Assessment report', status: 'complete', completed_at: '2026-11-11T10:00:00Z' },
    ],
    next_action: { kind: 'view_report', stage_key: 'assessment_report', label: 'Review the report' },
    property: prop2,
    created_at: '2026-11-10T09:00:00Z',
    updated_at: '2026-11-11T10:00:00Z',
  };

  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-sandbox', '--no-proxy-server'],
  });
  const errors = [];

  async function newPage(viewport = { width: 1440, height: 1000 }) {
    const ctx = await browser.newContext({ viewport, deviceScaleFactor: 1, bypassCSP: true });
    const page = await ctx.newPage();
    page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
    page.on('console', (m) => {
      if (m.type() === 'error') errors.push('console: ' + m.text());
    });
    await installHarnessSession(page, { role: 'entrepreneur' });
    // AFTER the harness catch-all so these handlers win.
    await page.route('**/api/v1/assessments/me**', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          data: [inProgress, completed],
          meta: { total: 2 },
        }),
      }),
    );
    await page.route('**/api/v1/assessments/by-property/**', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ assessment: inProgress }),
      }),
    );
    await page.route('**/api/v1/assessments/*/report', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(reportPayload(inProgress, prop)),
      }),
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
    return page;
  }

  // 1. Entry page, first card selected on load.
  const page = await newPage();
  await page.goto(`${base}/entrepreneur/assessments`, { waitUntil: 'networkidle', timeout: 30000 });
  await page.waitForSelector('.asw-entry', { timeout: 15000 });
  await page.waitForTimeout(900);
  await page.screenshot({ path: path.join(outdir, 'entry_page.png'), fullPage: true });

  const entryDom = await page.evaluate(() => ({
    cards: document.querySelectorAll('.asw-ecard').length,
    selected: document.querySelectorAll('.asw-ecard.is-selected').length,
    kpis: document.querySelectorAll('.asw-ekpi').length,
    metaCells: document.querySelectorAll('.asw-emeta__cell').length,
    selects: document.querySelectorAll('.asw-entry__select').length,
    removes: document.querySelectorAll('.asw-ecard__remove').length,
    detailTitle: document.querySelector('.asw-ehero__copy strong')?.textContent?.trim() || null,
  }));

  // 2. Selecting the second card swaps the right column in place (no reload).
  const urlBefore = page.url();
  await page.locator('.asw-ecard').nth(1).click();
  await page.waitForTimeout(500);
  await page.screenshot({ path: path.join(outdir, 'entry_page_selected.png'), fullPage: true });
  const selectedAfter = await page.evaluate(() => ({
    selectedTitle: document.querySelector('.asw-ecard.is-selected .asw-ecard__title')?.textContent?.trim() || null,
    detailTitle: document.querySelector('.asw-ehero__copy strong')?.textContent?.trim() || null,
    respondents: [...document.querySelectorAll('.asw-ekpi')].map((el) => el.textContent.trim()),
  }));
  const urlAfter = page.url();

  // 3. Remove → the existing confirm dialog, naming the record.
  await page.locator('.asw-ecard').nth(0).locator('.asw-ecard__remove').click();
  await page.waitForSelector('.overlay .dialog', { timeout: 15000 });
  await page.waitForTimeout(400);
  await page.screenshot({ path: path.join(outdir, 'entry_page_remove.png'), fullPage: true });
  const dialogText = (await page.locator('.overlay .dialog').innerText()).replace(/\s+/g, ' ').slice(0, 160);
  await page.getByRole('button', { name: 'Cancel' }).click();
  await page.waitForTimeout(300);

  // 4. View report from the detail panel — the document, in place.
  await page.locator('.asw-entry__detailactions .btn').nth(1).click();
  await page.waitForSelector('.asw-rpt', { timeout: 15000 });
  await page.waitForTimeout(900);
  await page.screenshot({ path: path.join(outdir, 'entry_page_report.png'), fullPage: true });
  const reportUrl = page.url();
  const reportHead = await page.evaluate(
    () => document.querySelector('.asw-rpt__sectitle')?.textContent?.trim() || null,
  );

  // 5. Back returns to the entry page, selection intact.
  await page.locator('.asw-rpt__actions .btn').first().click();
  await page.waitForSelector('.asw-entry', { timeout: 15000 });
  await page.waitForTimeout(400);
  const backSelected = await page.evaluate(
    () => document.querySelector('.asw-ecard.is-selected .asw-ecard__title')?.textContent?.trim() || null,
  );

  // 6. Continue assessment → the workspace, in place.
  await page.locator('.asw-entry__detailactions .btn').nth(0).click();
  await page.waitForSelector('.sw-assessment-journey', { timeout: 15000 });
  await page.waitForTimeout(900);
  await page.screenshot({ path: path.join(outdir, 'entry_page_continue.png'), fullPage: true });
  const workspaceUrl = page.url();
  await page.context().close();

  // 7. Step 5 is the CHECKPOINT again, not the report document.
  const page5 = await newPage();
  await page5.route('**/api/v1/assessments/by-property/**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ assessment: completed }),
    }),
  );
  await page5.goto(
    `${base}/entrepreneur/assessments?id=${encodeURIComponent(completed.property_id)}&stage=assessment_report`,
    { waitUntil: 'networkidle', timeout: 30000 },
  );
  await page5.waitForSelector('.asw-reporttable', { timeout: 15000 });
  await page5.waitForTimeout(1400);
  await page5.screenshot({ path: path.join(outdir, 'step5_checkpoint.png'), fullPage: true });
  const step5 = await page5.evaluate(() => ({
    hasReportDocument: !!document.querySelector('.asw-rpt'),
    hasContentsTable: !!document.querySelector('.asw-reporttable'),
    viewReport: [...document.querySelectorAll('button')].some(
      (b) => b.textContent.trim() === 'View report',
    ),
  }));

  // 8. View report from step 5 opens the document over the checkpoint.
  await page5.getByRole('button', { name: 'View report' }).click();
  await page5.waitForSelector('.asw-rpt', { timeout: 15000 });
  await page5.waitForTimeout(900);
  await page5.screenshot({ path: path.join(outdir, 'step5_view_report.png'), fullPage: true });
  await page5.context().close();

  console.log('saved entry-page screenshots in', outdir);
  console.log('entry dom:', JSON.stringify(entryDom));
  console.log('selection:', JSON.stringify(selectedAfter));
  console.log('url stable on select:', urlBefore === urlAfter);
  console.log('dialog:', dialogText);
  console.log('report url stable:', reportUrl === urlAfter, '| first section:', reportHead);
  console.log('back keeps selection:', backSelected);
  console.log('workspace url stable:', workspaceUrl === urlAfter);
  console.log('step 5:', JSON.stringify(step5));
  console.log(errors.length ? errors.join('\n') : 'no console/page errors');
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
