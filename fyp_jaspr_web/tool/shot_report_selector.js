// Screenshot the redesigned Report-tab selector gate (/entrepreneur/cafe-report)
// with a controlled assessment fixture, so all three report-access states render:
//   row 1: completed + report_available  -> "Report ready"  (CTA: View Report)
//   row 2: in progress, stage 3 of 5     -> "Preview only"  (CTA: Preview Report)
//   row 3: just started, nothing saved   -> "No report yet" (CTA disabled)
//
// The property payloads come from the real catalogue fixture (same shape the
// live API returns), so nothing here invents a contract the server does not
// send. Usage: node tool/shot_report_selector.js <url-base> <outdir>
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

  const rows = JSON.parse(fs.readFileSync(FIXTURE, 'utf8')).rows;
  const prop = (i) => rows[i % rows.length];

  const records = [
    {
      assessment_id: 'as-1f84c2-report-ready',
      property_id: prop(0).id,
      status: 'completed',
      current_stage: 5,
      current_stage_key: 'report',
      completed_stages: 5,
      total_stages: 5,
      progress_percent: 100,
      report_available: true,
      // SAMPLE participation counts for the mockup only — the live backend
      // does not send these fields yet. They mirror the shape the UI expects
      // (respondent_count / response_count / external_source_count).
      respondent_count: 24,
      response_count: 18,
      external_source_count: 3,
      requirements: { business_type: 'Cafe' },
      requirements_version: 2,
      stages: [
        stage('location', 1, 'Location selection', 'complete', '2026-11-01T09:00:00Z'),
        stage('requirements', 2, 'Business requirements', 'complete', '2026-11-02T10:00:00Z'),
        stage('questionnaire', 3, 'Customer questionnaire', 'complete', '2026-11-05T11:00:00Z'),
        stage('analysis', 4, 'Analysis', 'complete', '2026-11-08T12:00:00Z'),
        stage('report', 5, 'Report', 'complete', '2026-11-10T13:00:00Z'),
      ],
      capabilities: {},
      next_action: {},
      property: prop(0),
      created_at: '2026-11-01T09:00:00Z',
      updated_at: '2026-11-10T13:00:00Z',
    },
    {
      assessment_id: 'as-2d57ba-preview-only',
      property_id: prop(1).id,
      status: 'in_progress',
      current_stage: 3,
      current_stage_key: 'questionnaire',
      completed_stages: 2,
      total_stages: 5,
      progress_percent: 40,
      report_available: false,
      respondent_count: 12,
      response_count: 7,
      external_source_count: null,
      requirements: { business_type: 'Cafe' },
      requirements_version: 2,
      stages: [
        stage('location', 1, 'Location selection', 'complete', '2026-11-12T09:00:00Z'),
        stage('requirements', 2, 'Business requirements', 'complete', '2026-11-13T10:00:00Z'),
        stage('questionnaire', 3, 'Customer questionnaire', 'current'),
        stage('analysis', 4, 'Analysis', 'pending'),
        stage('report', 5, 'Report', 'pending'),
      ],
      capabilities: {},
      next_action: {},
      property: prop(1),
      created_at: '2026-11-12T09:00:00Z',
      updated_at: '2026-11-14T16:20:00Z',
    },
    {
      assessment_id: 'as-3ac91d-no-report-yet',
      property_id: prop(2).id,
      status: 'in_progress',
      current_stage: 1,
      current_stage_key: 'location',
      completed_stages: 0,
      total_stages: 5,
      progress_percent: 0,
      report_available: false,
      requirements: null,
      requirements_version: 0,
      stages: [
        stage('location', 1, 'Location selection', 'current'),
        stage('requirements', 2, 'Business requirements', 'pending'),
        stage('questionnaire', 3, 'Customer questionnaire', 'pending'),
        stage('analysis', 4, 'Analysis', 'pending'),
        stage('report', 5, 'Report', 'pending'),
      ],
      capabilities: {},
      next_action: {},
      property: prop(2),
      created_at: '2026-11-15T08:00:00Z',
      updated_at: '2026-11-15T08:00:00Z',
    },
  ];

  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-sandbox', '--no-proxy-server'],
  });
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
    deviceScaleFactor: 1,
    bypassCSP: true,
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push('console: ' + m.text());
  });

  await installHarnessSession(page, { role: 'entrepreneur' });
  // Registered AFTER the harness's catch-all /api/** route, so this handler
  // wins for the assessments endpoint (Playwright: last route wins).
  await page.route('**/api/v1/assessments/me**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ data: records, meta: { total: records.length } }),
    }),
  );

  await page.goto(`${base}/entrepreneur/cafe-report`, {
    waitUntil: 'networkidle',
    timeout: 30000,
  });
  await page.waitForSelector('.sra-workspace', { timeout: 15000 });
  await page.waitForTimeout(600);
  await page.screenshot({
    path: path.join(outdir, 'report_selector_v2.png'),
    fullPage: true,
  });

  console.log('saved', path.join(outdir, 'report_selector_v2.png'));
  console.log(errors.length ? errors.join('\n') : 'no console/page errors');
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
