// Screenshot the assessment workspace view (/entrepreneur/assessments?id=…)
// as it currently renders, so the current state can be compared against the
// Accessible_Enhanced mockup before restyling:
//   1. default view (?id=…)         — journey + progress + stage cards + aside
//   2. questionnaire open (?stage=) — the current one-question-at-a-time panel
// Usage: node tool/shot_assessment_workspace.js <url-base> <outdir>
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const { installHarnessSession, FIXTURE } = require('./session_harness');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

function stage(key, number, title, status, completedAt) {
  return { key, number, title, status, completed_at: completedAt || null, unavailable_reason: null };
}

(async () => {
  const [, , baseArg, outArg] = process.argv;
  const base = baseArg || 'http://127.0.0.1:8091';
  const outdir = outArg || 'tool/screenshots';
  fs.mkdirSync(outdir, { recursive: true });

  const fixture = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
  const prop = fixture.rows[1 % fixture.rows.length];

  // An in-progress record at stage 3 with saved V3 requirements, so the
  // questionnaire seeds real answers and the workspace renders every section.
  const record = {
    assessment_id: 'as-ws-preview',
    property_id: prop.id,
    status: 'in_progress',
    current_stage: 3,
    current_stage_key: 'location_evidence',
    completed_stages: 2,
    total_stages: 5,
    progress_percent: 40,
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
      stage('select_property', 1, 'Select property', 'complete', '2026-11-12T09:00:00Z'),
      stage('business_requirements', 2, 'Business preferences', 'complete', '2026-11-13T10:00:00Z'),
      stage('location_evidence', 3, 'Location evidence', 'current'),
      stage('ai_explanation', 4, 'AI explanation', 'incomplete'),
      stage('assessment_report', 5, 'Assessment report', 'incomplete'),
    ],
    capabilities: {
      model: { available: true, model_version: 'pu-expanded64' },
      explanation: { available: true, model_version: 'pu-expanded64' },
      report: { available: true },
    },
    next_action: { kind: 'continue', stage_key: 'location_evidence', label: 'Review the location evidence' },
    property: prop,
    created_at: '2026-11-12T09:00:00Z',
    updated_at: '2026-11-14T16:20:00Z',
  };

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
    // AFTER the harness catch-all so this handler wins.
    await page.route('**/api/v1/assessments/by-property/**', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ assessment: record }),
      }),
    );
    // Catalogue detail reads return the BARE row (no {ok, data} wrapper), as
    // the real backend does — the saved-property resolver parses it directly.
    await page.route('**/api/v1/catalog/properties/**', (route) => {
      const url = new URL(route.request().url());
      if (url.pathname.includes('/evidence')) return route.fallback();
      const id = decodeURIComponent(url.pathname.split('/').pop());
      const row = fixture.rows.find((r) => r.id === id);
      if (!row) return route.fulfill({ status: 404, body: '{}' });
      return route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(row),
      });
    });
    // Step 1's saved-property list (the repository reads `saved[].property_ref`).
    await page.route('**/api/v1/saved-properties/me', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          saved: [
            { property_ref: fixture.rows[1].id },
            { property_ref: fixture.rows[2].id },
            { property_ref: fixture.rows[3].id },
          ],
          unresolved: [],
        }),
      }),
    );
    // Step 4's persisted explanation (`{explanation: {...}}` envelope).
    await page.route('**/api/v1/assessments/*/explanation', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          explanation: {
            property_id: prop.id,
            assessment_id: record.assessment_id,
            available: true,
            model: 'pu',
            model_version: 'expanded64',
            explainer: 'TreeSHAP',
            score_meaning:
              'Relative suitability index from the trained P-vs-U model.',
            research_only: true,
            base_value: 0.42,
            output: 0.61,
            reconstructed: 0.61,
            additivity_ok: true,
            strongest_positive: [
              { feature: 'pop_total_1km', contribution: 0.074 },
              { feature: 'fnb_competitors_1000m', contribution: 0.051 },
              { feature: 'nearest_transit_walk_m', contribution: 0.038 },
            ],
            strongest_negative: [
              { feature: 'avg_household_income_1km', contribution: -0.029 },
              { feature: 'parking_bays_500m', contribution: -0.017 },
            ],
          },
        }),
      }),
    );
    // Step 5 assembles from GET /assessments/{id}/report. The evidence and
    // explanation blocks are deliberately unavailable so this checkpoint
    // proves the honest-empty states, not just the happy path.
    await page.route('**/api/v1/assessments/*/report', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          assessment_id: record.assessment_id,
          property_id: prop.id,
          status: record.status,
          generated_at: '2026-11-16T05:46:00Z',
          requirements_version: 3,
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
          listing_media: {
            available: false,
            reason: 'No photos or listing sources are stored for this property.',
          },
          geospatial_features: {
            available: true,
            data: { competitor_count_500m: 47, population_1km: 31366 },
          },
          evidence_categories: {
            available: true,
            data: [
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
          },
          research_association: {
            available: true,
            data: {
              score: 61.4,
              base_value: 0.5,
              model_version: 'expanded64',
              feature_set: 'expanded64',
              score_meaning:
                'research_positive_label_association_NOT_business_success_probability',
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
            ],
            matched: 1,
            mismatched: 1,
            unknown: 0,
            note:
              'Constraint checks only. No personalized compatibility percentage is produced because no scoring methodology has been approved.',
          },
          missing_information: ['No verified SHAP explanation was produced.'],
          model_information: {
            model: 'pu_model',
            feature_set: 'expanded64',
            explainer: 'permutation_shap',
            research_only: true,
          },
          export: {
            pdf: false,
            reason:
              'No server-side PDF generator is configured. The report is complete and printable from the browser; a PDF is not produced.',
          },
          meta: { scores_are_research_indexes: true },
        }),
      }),
    );
    // Stage 3's evidence read — same shape the real endpoint returns
    // (top-level payload; `available: false` would be the honest empty state).
    await page.route('**/api/v1/catalog/properties/**/evidence**', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          property_id: prop.id,
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
    return page;
  }

  const id = encodeURIComponent(prop.id);

  // 1. ALL FIVE checkpoints, one screenshot each (?stage= seeds the same
  //    checkpoint the stepper's buttons open — five independent views).
  const CHECKPOINTS = [
    'select_property',
    'business_requirements',
    'location_evidence',
    'ai_explanation',
    'assessment_report',
  ];
  for (const key of CHECKPOINTS) {
    const page = await newPage();
    await page.goto(`${base}/entrepreneur/assessments?id=${id}&stage=${key}`, {
      waitUntil: 'networkidle',
      timeout: 30000,
    });
    await page.waitForSelector('.sw-assessment-journey', { timeout: 15000 });
    // Long enough for the page-head letter-reveal animation to settle.
    await page.waitForTimeout(1400);
    await page.screenshot({
      path: path.join(outdir, `workspace_checkpoint_${key}.png`),
      fullPage: true,
    });
    await page.context().close();
  }

  console.log(
    `saved ${CHECKPOINTS.length} checkpoint screenshots in`,
    outdir,
  );
  console.log(errors.length ? errors.join('\n') : 'no console/page errors');
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
