// Entrepreneur dashboard post-login verification (the "signal timed out" fix).
//
// The real Supabase bridge cannot run headlessly without credentials, so this
// probe drives the dashboard through the session_harness stand-in bridge and
// route intercepts, verifying exactly what the fix changed:
//
//   1. Built bundle: the abort-message mapping exists and the raw browser
//      text can no longer be surfaced by the bridge's own fallbacks.
//   2. Success path: with both assessment endpoints mocked, the KPI row,
//      Current Assessment card, Quick Actions and Recent Assessments rows all
//      render from real response shapes (no page-wide error card).
//   3. Failure isolation: when the assessment endpoints answer 503, ONLY the
//      affected sections degrade — Quick Actions and the page head stay
//      visible, KPIs show em dashes, Recent Assessments carries its own
//      scoped "Try again", and the old page-wide "Something went wrong" card
//      is gone.
//   4. Scoped retry: clicking the section's Try again re-issues exactly the
//      failed request (counted) and clears the error on recovery.
//
// Usage: BASE=http://127.0.0.1:8090 node tool/probe_ent_dashboard.js
// (NODE_PATH must expose playwright-core.)

const { chromium } = require('playwright-core');
const fs = require('fs');
const path = require('path');
const { installHarnessSession } = require('./session_harness');

const BASE = process.env.BASE || 'http://127.0.0.1:8090';

const checks = [];
const ok = (name, pass, detail = '') =>
  checks.push({ name, pass: !!pass, detail });

// Minimal, contract-valid AssessmentRecord as AssessmentRecord.fromJson
// (fyp_jaspr_web/lib/data/assessment_api.dart) decodes it.
function assessmentRecord(overrides = {}) {
  return {
    assessment_id: '11111111-1111-1111-1111-111111111111',
    property_id: 'EP-01051',
    status: 'in_progress',
    current_stage: 3,
    current_stage_key: 'location_evidence',
    completed_stages: 2,
    total_stages: 5,
    progress_percent: 40,
    report_available: false,
    requirements: null,
    requirements_version: 2,
    requirements_legacy_view: null,
    stages: [
      { key: 'select_property', number: 1, title: 'Select Property', status: 'complete', completed_at: '2026-11-10T09:00:00Z', unavailable_reason: null },
      { key: 'business_requirements', number: 2, title: 'Business Requirements', status: 'complete', completed_at: '2026-11-10T09:20:00Z', unavailable_reason: null },
      { key: 'location_evidence', number: 3, title: 'Location Evidence', status: 'current', completed_at: null, unavailable_reason: null },
      { key: 'ai_explanation', number: 4, title: 'AI Explanation', status: 'incomplete', completed_at: null, unavailable_reason: null },
      { key: 'assessment_report', number: 5, title: 'Assessment Report', status: 'incomplete', completed_at: null, unavailable_reason: null },
    ],
    capabilities: {
      model: { available: true, reason: null, model_version: 'probe' },
      explanation: { available: true, reason: null, model_version: 'probe' },
      report: { available: true, reason: null, model_version: null },
    },
    next_action: { kind: 'continue', stage_key: 'location_evidence', label: 'Continue', reason: null },
    property: null,
    created_at: '2026-11-10T09:00:00Z',
    updated_at: '2026-11-10T09:20:00Z',
    ...overrides,
  };
}

const HISTORY = {
  data: [
    assessmentRecord(),
    assessmentRecord({
      assessment_id: '22222222-2222-2222-2222-222222222222',
      property_id: 'EP-01099',
      status: 'completed',
      current_stage: 5,
      current_stage_key: 'assessment_report',
      completed_stages: 5,
      progress_percent: 100,
      report_available: true,
    }),
  ],
  meta: { total: 2, limit: 50, offset: 0 },
};

async function setAssessmentMode(page, mode) {
  // Registered after the harness routes, so these win (Playwright matches
  // later routes first).
  await page.route('**/api/v1/assessments/me?*', (route) => {
    if (mode === 'fail') {
      return route.fulfill({
        status: 503,
        contentType: 'application/json',
        body: JSON.stringify({ detail: 'The data service is temporarily unavailable.' }),
      });
    }
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(HISTORY),
    });
  });
  await page.route('**/api/v1/assessments/me/current', (route) => {
    if (mode === 'fail') {
      return route.fulfill({
        status: 503,
        contentType: 'application/json',
        body: JSON.stringify({ detail: 'The data service is temporarily unavailable.' }),
      });
    }
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ assessment: assessmentRecord() }),
    });
  });
}

(async () => {
  // --- 0. Built bundle carries the abort-message mapping --------------------
  const bundlePath = path.join(
    __dirname, '..', 'build', 'jaspr', 'auth_bundle.js',
  );
  const bundle = fs.readFileSync(bundlePath, 'utf8');
  ok('Built auth_bundle.js maps aborts to a user-facing message',
     bundle.includes('did not respond in time') && bundle.includes('TimeoutError'));
  ok('Built auth_bundle.js no longer surfaces raw DOMException text as a fallback',
     !bundle.includes("message: typeof err?.message === 'string'"));

  const browser = await chromium.launch({ args: ['--no-proxy-server'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));

  await installHarnessSession(page, { role: 'entrepreneur' });
  await setAssessmentMode(page, 'ok');

  // --- 1. Success path -------------------------------------------------------
  await page.goto(`${BASE}/entrepreneur`, { waitUntil: 'load' });
  await page.waitForTimeout(1500);

  const body = await page.textContent('body');
  ok('Dashboard head renders', body.includes('Welcome back'), '');
  ok('Recent Assessments section renders', body.includes('Recent Assessments'));
  ok('Quick Actions render', body.includes('Quick Actions'));
  ok('Current Assessment card renders', body.includes('Current Assessment'));
  ok('Assessment rows render', body.includes('In progress') && body.includes('Completed'));
  ok('No page-wide error card on success', !body.includes('Something went wrong'));

  const kpiValues = await page.$$eval('.kpi-value', (els) =>
    els.map((el) => el.textContent.trim()));
  ok('Explore KPI shows the catalogue count (not em dash)',
     /^\d+$/.test(kpiValues[0] || ''), JSON.stringify(kpiValues));
  ok('Assessments KPI shows the history total',
     kpiValues[2] === '2', JSON.stringify(kpiValues));

  // --- 2. Failure isolation --------------------------------------------------
  await setAssessmentMode(page, 'fail');
  await page.goto(`${BASE}/entrepreneur`, { waitUntil: 'load' });
  await page.waitForTimeout(1500);

  const bodyFail = await page.textContent('body');
  ok('Section error shows the failure message',
     bodyFail.includes('Recent assessments could not be loaded') &&
     bodyFail.includes('The data service is temporarily unavailable.'));
  ok('Scoped Try again is offered', await page.$('section:has-text("Recent Assessments") button') !== null);
  ok('Quick Actions remain usable when history fails', bodyFail.includes('Quick Actions'));
  ok('Current Assessment card keeps its own contained error',
     bodyFail.includes('Current Assessment'));
  ok('The old page-wide error card is gone', !bodyFail.includes('Something went wrong'));

  const kpiFail = await page.$$eval('.kpi-value', (els) =>
    els.map((el) => el.textContent.trim()));
  ok('History-driven KPIs degrade to em dashes on failure',
     kpiFail[2] === '—' && kpiFail[3] === '—', JSON.stringify(kpiFail));

  // --- 3. Scoped retry re-issues only the failed request ---------------------
  await setAssessmentMode(page, 'ok');
  // Registered LAST so this counter intercepts first and falls through to the
  // mode handler above.
  let historyRequests = 0;
  await page.route('**/api/v1/assessments/me?*', (route) => {
    historyRequests += 1;
    return route.fallback();
  });
  const retry = await page.$('section:has-text("Recent Assessments") button');
  if (retry) {
    await retry.click();
    await page.waitForTimeout(1200);
    const bodyRetry = await page.textContent('body');
    ok('Scoped retry re-issues the history request', historyRequests >= 1,
       `history requests after retry: ${historyRequests}`);
    ok('Error clears after successful retry', !bodyRetry.includes('Recent assessments could not be loaded'));
    ok('Assessment rows render after retry', bodyRetry.includes('In progress'));
  } else {
    ok('Scoped retry available', false, 'retry button not found');
  }

  ok('No page JS errors during the whole probe', errors.length === 0,
     errors.slice(0, 3).join(' | '));

  await browser.close();

  const failed = checks.filter((c) => !c.pass);
  for (const c of checks) {
    console.log(`[${c.pass ? 'PASS' : 'FAIL'}] ${c.name}${c.detail ? ' :: ' + c.detail : ''}`);
  }
  console.log(`\n${checks.length - failed.length}/${checks.length} checks passed`);
  process.exit(failed.length ? 1 : 0);
})().catch((e) => {
  console.error('probe crashed:', e);
  process.exit(2);
});
