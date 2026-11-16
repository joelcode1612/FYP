// Interaction probe for the redesigned Step 3 (BDJ findings & objectives):
// default radio state, checkbox select, expander, objective derivation,
// decision switching + follow-up, and save validation. Prints one line per
// assertion; exit 1 if any FAIL.
// Usage: node tool/probe_step3_bdj.js <url-base>
const fs = require('fs');
const { chromium } = require('playwright-core');
const { installHarnessSession, FIXTURE } = require('./session_harness');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

(async () => {
  const [, , baseArg] = process.argv;
  const base = baseArg || 'http://127.0.0.1:8091';

  const fixture = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
  const prop = fixture.rows[1 % fixture.rows.length];

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
    requirements_version: 3,
    stages: [
      { key: 'select_property', number: 1, title: 'Select property', status: 'complete', completed_at: '2026-11-12T09:00:00Z', unavailable_reason: null },
      { key: 'business_requirements', number: 2, title: 'Business preferences', status: 'complete', completed_at: '2026-11-13T10:00:00Z', unavailable_reason: null },
      { key: 'location_evidence', number: 3, title: 'Location evidence', status: 'current', completed_at: null, unavailable_reason: null },
      { key: 'ai_explanation', number: 4, title: 'AI explanation', status: 'incomplete', completed_at: null, unavailable_reason: null },
      { key: 'assessment_report', number: 5, title: 'Assessment report', status: 'incomplete', completed_at: null, unavailable_reason: null },
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
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
    bypassCSP: true,
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push('console: ' + m.text());
  });
  await installHarnessSession(page, { role: 'entrepreneur' });
  await page.route('**/api/v1/assessments/by-property/**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ assessment: record }),
    }),
  );
  await page.route('**/api/v1/catalog/properties/**', (route) => {
    const url = new URL(route.request().url());
    if (url.pathname.includes('/evidence')) {
      return route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          property_id: prop.id,
          available: true,
          analysis_status: 'complete',
          reference_coverage: '1 km walking catchment',
          feature_snapshot_at: '2026-10-30',
          data_completeness_pct: 94,
          groups: [
            {
              key: 'competitor_pressure',
              label: 'Competitor pressure',
              metrics: [
                { key: 'fnb_competitors_1000m', label: 'F&B competitors within 1 km', unit: 'count', value: 47, status: 'available', note: 'Median for shop offices in this district is 31.' },
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
      });
    }
    const id = decodeURIComponent(url.pathname.split('/').pop());
    const row = fixture.rows.find((r) => r.id === id);
    if (!row) return route.fulfill({ status: 404, body: '{}' });
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(row),
    });
  });
  await page.route('**/api/v1/saved-properties/me', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        saved: [{ property_ref: fixture.rows[1].id }],
        unresolved: [],
      }),
    }),
  );

  const results = [];
  const check = (name, ok) => results.push(`${ok ? 'PASS' : 'FAIL'}  ${name}`);

  const id = encodeURIComponent(prop.id);
  await page.goto(`${base}/entrepreneur/assessments?id=${id}&stage=location_evidence`, {
    waitUntil: 'networkidle',
    timeout: 30000,
  });
  await page.waitForSelector('.bdj-finding', { timeout: 15000 });
  await page.waitForTimeout(600);

  // 1. Confirm radio is checked by default.
  const confirmChecked = await page.$eval(
    'input[name="bdj-decision"][value="confirm"]',
    (el) => el.checked,
  );
  check('confirm radio checked by default', confirmChecked === true);

  // 2. Checkbox select marks the card and updates tabs + state chip.
  await page.click('.bdj-finding:first-child .bdj-find-check');
  await page.waitForTimeout(300);
  const cardSelected = await page.$eval('.bdj-finding:first-child', (el) =>
    el.classList.contains('is-selected'),
  );
  const tabsText = await page.$eval('.asw-findtools .tabs', (el) => el.textContent);
  check('checkbox marks card is-selected', cardSelected === true);
  check(
    'tabs recount (Selected (1) / Not selected (5))',
    tabsText.includes('Selected (1)') && tabsText.includes('Not selected (5)'),
  );

  // 3. Objective derives from the selected finding.
  const objective = await page.$eval('.bdj-objective p', (el) => el.textContent);
  check(
    'objective text includes selected finding',
    objective.includes('F&B competitors within 1 km'),
  );

  // 4. Expander reveals the meta grid with origin + status + note.
  await page.click('.bdj-finding:first-child .bdj-expand');
  await page.waitForTimeout(300);
  const metaText = await page.$eval('.bdj-detail', (el) => el.textContent);
  check(
    'expanded card shows origin + status + note',
    metaText.includes('Based on') &&
      metaText.includes('Competitor pressure') &&
      metaText.includes('Measured — 47') &&
      metaText.includes('Median for shop offices'),
  );

  // 5. Filter tab "Selected (1)" narrows the list.
  await page.click('.asw-findtools .tab:nth-child(2)');
  await page.waitForTimeout(300);
  const visibleCards = await page.$$eval('.bdj-finding', (els) => els.length);
  check('selected filter shows exactly 1 card', visibleCards === 1);
  await page.click('.asw-findtools .tab:nth-child(1)');

  // 6. Switching decision to refine reveals the follow-up with its label.
  await page.click('input[name="bdj-decision"][value="refine"]');
  await page.waitForTimeout(300);
  const followLabel = await page.$eval('.bdj-followup label', (el) => el.textContent);
  check('refine follow-up label', followLabel.includes('How would you change the objective?'));

  // 7. Save without details -> validation error.
  await page.click('.bdj-decision-foot button');
  await page.waitForTimeout(300);
  const errStatus = await page.$eval('.bdj-save-status', (el) => el.textContent);
  check('save without details errors', errStatus.includes('Please add a few details'));

  // 8. With details -> session note status.
  await page.fill('.bdj-followup textarea', 'Focus on office workers nearby.');
  await page.click('.bdj-decision-foot button');
  await page.waitForTimeout(300);
  const okStatus = await page.$eval('.bdj-save-status', (el) => el.textContent);
  check('save with details succeeds', okStatus.includes('Noted for this session'));

  // 9. Back to confirm and save -> stage-completion PATCH fires.
  let stageSaved = false;
  await page.route(`**/api/v1/assessments/${record.assessment_id}`, (route) => {
    if (route.request().method() === 'PATCH') {
      stageSaved = true;
      return route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(record),
      });
    }
    return route.fallback();
  });
  await page.click('input[name="bdj-decision"][value="confirm"]');
  await page.waitForTimeout(300);
  await page.click('.bdj-decision-foot button');
  await page.waitForTimeout(600);
  check('confirm save hits the stage endpoint', stageSaved);

  console.log(results.join('\n'));
  console.log(errors.length ? 'ERRORS:\n' + errors.join('\n') : 'no console/page errors');
  await browser.close();
  if (results.some((r) => r.startsWith('FAIL')) || errors.length) process.exit(1);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
