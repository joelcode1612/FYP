// Screenshot the History tab (/entrepreneur/assessments/history — the
// M2ActivityPanel shell) with a controlled M2 activity fixture.
//
// The panel reads two authenticated endpoints:
//   GET /api/v1/m2/assessments            -> {contract_version, items:[{id, revision}]}
//   GET /api/v1/m2/assessments/{id}/activity -> m2-activity/1 payload
// The fixture mirrors those contracts; nothing ships — headless verification
// only. Usage: node tool/shot_history_tab.js [urlBase] [outdir]
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

const A1 = '3f6d2a58-9c41-4b8e-a1d2-7f5c0b9e1234';
const A2 = '8c21b7a4-52e9-4d3f-b6a8-1e4d7c2f5678';

const activity = {
  contract_version: 'm2-activity/1',
  assessment_id: A1,
  assessment_revision: 3,
  history_extension: 'workflow-history-metadata/1',
  authorization_decisions_included: false,
  bcb_history_available: true,
  bcb_statuses: [
    {
      confirmation_id: 'b2c4d6e8-1a3b-4c5d-9e7f-a0b1c2d3e4f5',
      assessment_revision: 3,
      status: 'PERSISTED',
      attempt_count: 1,
      updated_at: '2026-11-14T09:12:00Z',
      last_code: null,
      context_id: 'cc7e5f31-8d24-4a6b-b8c9-2d3e4f5a6b7c',
      source_is_current: true,
    },
  ],
  bcb_statuses_truncated: false,
  truncated: false,
  events: [
    {
      kind: 'Assessment created',
      event_id: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d',
      occurred_at: '2026-11-01T08:05:00Z',
      module: 'M2',
      status: 'Recorded',
      assessment_revision: 1,
    },
    {
      kind: 'Business understanding saved',
      event_id: 'b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e',
      occurred_at: '2026-11-03T10:41:00Z',
      module: 'M2',
      status: 'Recorded',
      assessment_revision: 1,
    },
    {
      kind: 'Answers saved',
      event_id: 'c3d4e5f6-a7b8-4c9d-0e1f-2a3b4c5d6e7f',
      occurred_at: '2026-11-06T14:22:00Z',
      module: 'M2',
      status: 'Recorded',
      assessment_revision: 2,
    },
    {
      kind: 'Candidate rules evaluated',
      event_id: 'd4e5f6a7-b8c9-4d0e-1f2a-3b4c5d6e7f8a',
      occurred_at: '2026-11-08T16:03:00Z',
      module: 'BDJ',
      status: 'Recorded — outcome not supplied',
      assessment_revision: 2,
    },
    {
      kind: 'Context understanding complete',
      event_id: 'e5f6a7b8-c9d0-4e1f-2a3b-4c5d6e7f8a9b',
      occurred_at: '2026-11-14T09:12:00Z',
      module: 'BCB',
      status: 'PERSISTED',
      assessment_revision: 3,
      source_is_current: true,
    },
  ],
};

(async () => {
  const [, , baseArg, outArg] = process.argv;
  const base = baseArg || 'http://127.0.0.1:8091';
  const outdir = outArg || 'tool/screenshots';
  fs.mkdirSync(outdir, { recursive: true });

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
  // Registered AFTER the harness catch-all so these handlers win. The generic
  // list route is registered BEFORE the specific activity routes — Playwright
  // lets the most recently registered matching handler answer. `?` in a glob
  // matches exactly ONE character, so the query string is caught with `*`.
  await page.route('**/api/v1/m2/assessments**', (route) => {
    const url = new URL(route.request().url());
    if (url.pathname.endsWith('/activity')) return route.fallback();
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        contract_version: 'm2-assessment-list/1',
        items: [
          { id: A1, revision: 3 },
          { id: A2, revision: 1 },
        ],
      }),
    });
  });
  for (const id of [A1, A2]) {
    await page.route(`**/api/v1/m2/assessments/${id}/activity**`, (route) =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(
          id === A1 ? activity : { ...activity, assessment_id: id, events: activity.events.slice(0, 2), bcb_statuses: [] },
        ),
      }),
    );
  }

  await page.goto(`${base}/entrepreneur/assessments/history`, {
    waitUntil: 'networkidle',
    timeout: 30000,
  });
  await page.waitForTimeout(800);
  await page.screenshot({
    path: path.join(outdir, 'history_tab.png'),
    fullPage: true,
  });

  // Headless verification of what actually rendered (the image tool dedupes
  // identical screenshots, so text assertions are the reliable evidence).
  const text = await page.evaluate(() => document.body.innerText);
  const pickerInfo = await page.evaluate(() => {
    const el = document.querySelector('[data-testid="saved-assessment-select"]');
    return el ? { tag: el.tagName, options: el.options.length, disabled: el.disabled } : null;
  });
  const checks = {
    'heading + breadcrumb': text.includes('Activity history') && text.includes('Review portal'),
    'heading actions removed': !text.includes('Open M2 questionnaire') &&
      !text.includes('Refresh saved activity') && !text.includes('Back to report'),
    'picker is native select': pickerInfo?.tag === 'SELECT' && pickerInfo.options >= 1,
    'picker has real options': pickerInfo ? pickerInfo.options === 3 : false,
    'no legacy unavailable card': !text.includes('Saved assessment activity unavailable'),
    'identity card': text.includes('CURRENT ASSESSMENT') && text.includes('Recorded activities'),
    'filter card': text.includes('Filter activities') && text.includes('Narrow the history'),
    'coverage card': text.includes('Workflow history coverage'),
    'timeline events': text.includes('Assessment created') && text.includes('Candidate rules evaluated'),
    'BCB snapshot line': text.includes('PERSISTED'),
    'detail card': text.includes('What happened') && text.includes('Processing details') && text.includes('Audit information'),
    'view json action': text.includes('View full log (JSON)'),
    'pagination': text.includes('Page 1 of 1'),
    'footnote': text.includes('All events must be backend-sourced'),
  };
  console.log('checks:', JSON.stringify(checks, null, 1));
  console.log('saved', path.join(outdir, 'history_tab.png'));
  console.log(errors.length ? errors.join('\n') : 'no console/page errors');
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
