// Screenshot step 3's redesigned "Evidence unavailable" empty state: same
// workspace fixture as shot_assessment_workspace.js but the evidence read
// returns available:false, which exercises the new asw-ev3empty layout.
// Usage: node tool/shot_step3_empty.js <url-base> <outdir>
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const { installHarnessSession, FIXTURE } = require('./session_harness');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

(async () => {
  const [, , baseArg, outArg] = process.argv;
  const base = baseArg || 'http://127.0.0.1:8091';
  const outdir = outArg || 'tool/screenshots/step3_redesign';
  fs.mkdirSync(outdir, { recursive: true });

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
  const errors = [];
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
      // The honest empty payload the real backend returns with no row.
      return route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          property_id: prop.id,
          available: false,
          reason:
            'The analysis pipeline has no evidence row for this property yet.',
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
        saved: [
          { property_ref: fixture.rows[1].id },
          { property_ref: fixture.rows[2].id },
          { property_ref: fixture.rows[3].id },
        ],
        unresolved: [],
      }),
    }),
  );

  const id = encodeURIComponent(prop.id);
  await page.goto(
    `${base}/entrepreneur/assessments?id=${id}&stage=location_evidence`,
    { waitUntil: 'networkidle', timeout: 30000 },
  );
  await page.waitForSelector('.bdj-empty', { timeout: 15000 });
  await page.waitForTimeout(1400);
  await page.screenshot({
    path: path.join(outdir, 'workspace_step3_evidence_unavailable.png'),
    fullPage: true,
  });
  console.log('saved workspace_step3_evidence_unavailable.png in', outdir);
  console.log(errors.length ? errors.join('\n') : 'no console/page errors');
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
