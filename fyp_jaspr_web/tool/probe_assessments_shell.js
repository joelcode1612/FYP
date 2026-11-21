// Verify the redesigned /entrepreneur/assessments workspace shell:
//   - the page renders WITHOUT the app shell chrome: no .app-shell wrapper,
//     no pill nav, no sidebar drawer
//   - the content starts with the breadcrumb
//     "Home › Assessments › Customer questionnaire"
//   - the page head carries the "Assessment workspace" eyebrow, the
//     "Location Assessment" title and the Assessment History action
//   - the five-stage journey stepper renders (restored component) with the
//     backend-recorded stage states (1 complete, 2 current)
//   - the stage-1 (no ?id) view renders its own content inside the same shell
//
// Run:
//   NODE_PATH=C:/Users/Lenovo/.workbuddy-ai/binaries/node/workspace/node_modules \
//   BASE=http://127.0.0.1:8090 node tool/probe_assessments_shell.js
const path = require('node:path');
const fs = require('node:fs');
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness.js');

const BASE = process.env.BASE || 'http://127.0.0.1:8090';

// The catalogue fixture rows (same file session_harness serves). The
// assessment record embeds one as its `property` payload.
const catalogueRows = JSON.parse(
  fs.readFileSync(
    path.join(__dirname, '..', '..', 'test', '.data', 'jaspr_catalog_fixture.json'),
    'utf8',
  ),
).rows;

// A minimal but valid AssessmentRecord the workspace can render. Stage states
// come from the backend, so the fixture decides what the stepper shows.
function assessmentRecord(propertyRow) {
  const iso = '2026-11-15T09:00:00Z';
  const stage = (key, number, title, status) => ({
    key,
    number,
    title,
    status,
    completed_at: status === 'complete' ? iso : null,
    unavailable_reason: null,
  });
  return {
    assessment_id: 'AS-FIXTURE-1',
    property_id: propertyRow.id,
    status: 'in_progress',
    current_stage: 2,
    current_stage_key: 'business_requirements',
    completed_stages: 1,
    total_stages: 5,
    progress_percent: 20,
    report_available: false,
    requirements: null,
    requirements_version: 3,
    stages: [
      stage('select_property', 1, 'Select property', 'complete'),
      stage('business_requirements', 2, 'Business preferences', 'current'),
      stage('location_evidence', 3, 'Location evidence', 'incomplete'),
      stage('ai_explanation', 4, 'AI explanation', 'incomplete'),
      stage('assessment_report', 5, 'Assessment report', 'incomplete'),
    ],
    capabilities: {},
    next_action: {
      kind: 'continue',
      stage_key: 'business_requirements',
      label: 'Answer the business preferences',
      reason: null,
    },
    property: propertyRow,
    created_at: iso,
    updated_at: iso,
  };
}

(async () => {
  const checks = [];
  const ok = (name, pass, extra = '') => {
    checks.push({ name, pass: !!pass });
    if (!pass) console.log(`  FAIL ${name} ${extra}`);
  };

  const browser = await chromium.launch({ args: ['--no-proxy-server'] });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
  });
  const page = await context.newPage();
  await installHarnessSession(page, { role: 'entrepreneur' });

  const propertyRow =
    catalogueRows.find((r) => r.id === 'EP-01051') || catalogueRows[0];

  // Overriding route (registered after the harness, so it wins): the
  // assessment record for the workspace view.
  await page.route('**/api/v1/assessments/by-property/EP-01051', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ ok: true, assessment: assessmentRecord(propertyRow) }),
    }),
  );

  // --- View 1: the stage-1 entry (no ?id=) ---------------------------------
  await page.goto(`${BASE}/entrepreneur/assessments`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(600);

  const stage1 = await page.evaluate(() => {
    const txt = (s) => (document.querySelector(s)?.textContent || '').trim();
    const crumbs = Array.from(document.querySelectorAll('.crumbs__item')).map(
      (n) => n.textContent.trim(),
    );
    return {
      hasShell: !!document.querySelector('.app-shell'),
      hasPill: !!document.querySelector('.app-pill'),
      hasSidebar: !!document.querySelector('.sidebar'),
      hasPage: !!document.querySelector('.asw-page'),
      crumbs,
      crumbCurrent: txt('.crumbs__item--current'),
      eyebrow: txt('.page-head .eyebrow'),
      title: txt('.page-head__title'),
      actions: Array.from(
        document.querySelectorAll('.page-head .action, .page-head a'),
      ).map((n) => n.getAttribute('href') || n.textContent.trim()),
      firstHeading: txt('h1'),
    };
  });

  ok('stage1: no .app-shell chrome', !stage1.hasShell);
  ok('stage1: no pill nav', !stage1.hasPill);
  ok('stage1: no sidebar', !stage1.hasSidebar);
  ok('stage1: .asw-page content container', stage1.hasPage);
  ok(
    'stage1: crumb trail is Home › Assessments › Customer questionnaire',
    stage1.crumbs[0] === 'Home' &&
      stage1.crumbs[1] === 'Assessments' &&
      stage1.crumbCurrent === 'Customer questionnaire',
    JSON.stringify(stage1.crumbs),
  );
  ok('stage1: eyebrow is "Assessment workspace"', stage1.eyebrow === 'Assessment workspace', stage1.eyebrow);
  ok('stage1: h1 is "Location Assessment"', stage1.title === 'Location Assessment', stage1.title);
  ok(
    'stage1: Assessment History action present',
    stage1.actions.some((h) => typeof h === 'string' && h.includes('/entrepreneur/assessments/history')),
    JSON.stringify(stage1.actions),
  );

  // --- View 2: the workspace for a started assessment (?id=) ---------------
  await page.goto(`${BASE}/entrepreneur/assessments?id=EP-01051`, {
    waitUntil: 'networkidle',
  });
  await page.waitForTimeout(600);

  const ws = await page.evaluate(() => {
    const txt = (s) => (document.querySelector(s)?.textContent || '').trim();
    const journey = document.querySelector('.sw-assessment-journey');
    const steps = Array.from(
      document.querySelectorAll('.sw-assessment-journey__step'),
    ).map((n) => n.className);
    return {
      hasSidebar: !!document.querySelector('.sidebar'),
      hasJourney: !!journey,
      journeyCount: txt('.sw-assessment-journey__count'),
      journeyTitle: txt('.sw-assessment-journey__title'),
      steps,
      stepCircles: Array.from(
        document.querySelectorAll('.sw-assessment-journey__circle'),
      ).map((n) => n.textContent.trim()),
      progressFill: document.querySelector(
        '.sw-assessment-journey__progress-fill',
      )?.getAttribute('style'),
      stageCards: document.querySelectorAll('.asw-grid .panel').length,
      crumbCurrent: txt('.crumbs__item--current'),
      subtitle: txt('.page-head__desc'),
    };
  });

  ok('workspace: no sidebar', !ws.hasSidebar);
  ok('workspace: journey stepper renders', ws.hasJourney);
  ok(
    'workspace: journey title is the five-stage heading',
    /five stages/i.test(ws.journeyTitle),
    ws.journeyTitle,
  );
  ok(
    'workspace: count reads 1 / 5 completed',
    /1\s*\/\s*5/.test(ws.journeyCount),
    ws.journeyCount,
  );
  ok('workspace: five steps rendered', ws.steps.length === 5, String(ws.steps.length));
  ok(
    'workspace: step 1 complete, step 2 current',
    /--complete/.test(ws.steps[0] || '') && /--current/.test(ws.steps[1] || ''),
  );
  ok(
    'workspace: step 1 circle shows the check mark',
    ws.stepCircles[0] === '✓',
    JSON.stringify(ws.stepCircles),
  );
  ok(
    'workspace: progress fill reflects 20%',
    /20%/.test(ws.progressFill || ''),
    ws.progressFill || '',
  );
  ok(
    'workspace: crumb still reads Customer questionnaire',
    ws.crumbCurrent === 'Customer questionnaire',
    ws.crumbCurrent,
  );
  ok(
    'workspace: subtitle carries the property context',
    /Uptown Damansara/.test(ws.subtitle || ''),
    ws.subtitle || '',
  );
  ok('workspace: stage grid rendered', ws.stageCards > 0, String(ws.stageCards));

  await page.screenshot({
    path: path.join(__dirname, 'screenshots', 'assessments_workspace.png'),
    fullPage: true,
  });

  await browser.close();

  const failed = checks.filter((c) => !c.pass);
  console.log(`${checks.length - failed.length}/${checks.length} checks passed`);
  process.exit(failed.length ? 1 : 0);
})().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
