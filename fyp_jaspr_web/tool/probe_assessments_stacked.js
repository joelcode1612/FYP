// Verify the Assessments tab's in-place detail: clicking a row keeps the list
// mounted and shows the workspace detail BELOW it (like the report tab's
// master-detail), with no route change and no duplicate page head.
// Usage: NODE_PATH=... node tool/probe_assessments_stacked.js [base] [outdir]
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');
const { installHarnessSession, FIXTURE } = require('./session_harness');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const fixture = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));

const stage = (key, number, title, status, at) => ({
  key, number, title, status,
  completed_at: status === 'complete' ? at || '2026-11-10T09:00:00Z' : null,
  unavailable_reason: null,
});
const stages = (done) => [
  stage('select_property', 1, 'Select property', 'complete'),
  stage('business_requirements', 2, 'Business preferences', 'complete'),
  stage('location_evidence', 3, 'Location evidence', done ? 'complete' : 'current'),
  stage('ai_explanation', 4, 'AI explanation', 'incomplete'),
  stage('assessment_report', 5, 'Assessment report', 'incomplete'),
];
function record(i) {
  const prop = fixture.rows[i % fixture.rows.length];
  return {
    assessment_id: `as-stacked-${i + 1}`,
    property_id: prop.id,
    status: 'in_progress',
    current_stage: 3,
    current_stage_key: 'location_evidence',
    completed_stages: 2,
    total_stages: 5,
    progress_percent: 40,
    report_available: false,
    requirements: { business_type: 'Cafe' },
    requirements_version: 3,
    stages: stages(false),
    capabilities: {},
    next_action: { kind: 'continue', stage_key: 'location_evidence', label: 'Review the location evidence' },
    property: prop,
    created_at: '2026-11-12T08:00:00Z',
    updated_at: '2026-11-14T16:20:00Z',
  };
}
const records = [record(0), record(1)];

(async () => {
  const [, , baseArg, outArg] = process.argv;
  const base = baseArg || 'http://127.0.0.1:8091';
  const outdir = outArg || 'tool/screenshots';
  fs.mkdirSync(outdir, { recursive: true });

  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox', '--no-proxy-server'] });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1000 }, bypassCSP: true });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  await installHarnessSession(page, { role: 'entrepreneur' });
  await page.route('**/api/v1/assessments/me**', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify({ data: records, meta: { total: records.length } }) }),
  );
  await page.route('**/api/v1/assessments/by-property/**', (route) => {
    const url = new URL(route.request().url());
    // The property id is a PATH segment: /api/v1/assessments/by-property/{id}.
    const id = decodeURIComponent(
      url.pathname.split('/by-property/')[1]?.split('?')[0] || '',
    );
    const match = records.find((r) => r.property_id === id) || records[0];
    // by-property returns an {assessment: record} envelope (same as the
    // existing listing probe) — the page needs the saved record to render
    // its real stage/stepper, not the not-started fallback.
    return route.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify({ assessment: match }) });
  });

  await page.goto(`${base}/entrepreneur/assessments`, { waitUntil: 'networkidle', timeout: 30000 });
  await page.waitForSelector('.audit-table tbody tr', { timeout: 15000 });
  const urlBefore = page.url();
  const checks = {};

  const clickRow = async (index) => {
    await page.locator('.audit-table tbody tr').nth(index)
      .locator('button.asw-row-btn:not(.asw-row-btn--danger)').click();
    await page.waitForSelector('.asw-inline-detail', { timeout: 15000 });
    await page.waitForTimeout(500);
  };

  await clickRow(0);
  checks['url unchanged'] = page.url() === urlBefore;
  checks['list still mounted'] = await page.locator('.audit-table tbody tr').count() === 2;
  checks['detail below list'] = await page.evaluate(() => {
    const list = document.querySelector('.audit-table').getBoundingClientRect();
    const detail = document.querySelector('.asw-inline-detail').getBoundingClientRect();
    return detail.top >= list.bottom - 2;
  });
  checks['single page head'] = await page.locator('.page-head').count() === 1;
  checks['journey visible'] = await page.locator('.asw-inline-detail .sw-assessment-journey').count() === 1;
  await page.screenshot({ path: path.join(outdir, 'assessments_stacked_open.png'), fullPage: true });

  // Second row swaps the detail content only; list stays.
  const firstTitle = await page.locator('.asw-inline-detail').innerText();
  await clickRow(1);
  const secondTitle = await page.locator('.asw-inline-detail').innerText();
  console.log('debug detail heads:', JSON.stringify([firstTitle.slice(0, 160), secondTitle.slice(0, 160)]));
  checks['detail swapped in place'] =
    secondTitle !== firstTitle &&
    page.url() === urlBefore;
  checks['list survives swap'] = await page.locator('.audit-table tbody tr').count() === 2;

  await page.locator('.page-head__actions button', { hasText: 'Back to assessments' }).click();
  await page.waitForTimeout(400);
  checks['back removes detail'] = await page.locator('.asw-inline-detail').count() === 0;
  checks['back keeps list'] = await page.locator('.audit-table tbody tr').count() === 2;
  await page.screenshot({ path: path.join(outdir, 'assessments_stacked_back.png'), fullPage: true });

  console.log('checks:', JSON.stringify(checks, null, 1));
  console.log(errors.length ? errors.join('\n') : 'no console/page errors');
  await browser.close();
})().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
