// Verify the Assessments tab now lives inside the same persistent AppLayout
// chrome as the Report tab: pill nav present, one page head, no double gutter,
// matched hover/press feedback, and — the point of the change — switching tabs
// is a client-side route change, not a document reload.
// Usage: NODE_PATH=... node tool/probe_assessments_chrome.js [base] [outdir]
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');
const { installHarnessSession, FIXTURE } = require('./session_harness');

const EXE =
  'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const fixture = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));

const stage = (key, number, title, status, at) => ({
  key,
  number,
  title,
  status,
  completed_at: status === 'complete' ? at || '2026-11-10T09:00:00Z' : null,
  unavailable_reason: null,
});
const stages = () => [
  stage('select_property', 1, 'Select property', 'complete'),
  stage('business_requirements', 2, 'Business preferences', 'current'),
  stage('location_evidence', 3, 'Location evidence', 'incomplete'),
  stage('ai_explanation', 4, 'AI explanation', 'incomplete'),
  stage('assessment_report', 5, 'Assessment report', 'incomplete'),
];
function record(i) {
  const prop = fixture.rows[i % fixture.rows.length];
  return {
    assessment_id: `as-chrome-${i + 1}`,
    property_id: prop.id,
    status: 'in_progress',
    current_stage: 2,
    current_stage_key: 'business_requirements',
    completed_stages: 1,
    total_stages: 5,
    progress_percent: 20,
    report_available: false,
    requirements: { business_type: 'Cafe' },
    requirements_version: 2,
    stages: stages(),
    capabilities: {},
    next_action: {
      kind: 'continue',
      stage_key: 'business_requirements',
      label: 'Answer the business preferences',
    },
    property: prop,
    created_at: '2026-11-10T08:00:00Z',
    updated_at: '2026-11-14T16:20:00Z',
  };
}
const records = [record(0), record(1)];

(async () => {
  const [, , baseArg, outArg] = process.argv;
  const base = baseArg || 'http://127.0.0.1:8090';
  const outdir = outArg || 'tool/screenshots';
  fs.mkdirSync(outdir, { recursive: true });

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
  await page.route('**/api/v1/assessments/me**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ data: records, meta: { total: records.length } }),
    }),
  );
  await page.route('**/api/v1/assessments/by-property/**', (route) => {
    const url = new URL(route.request().url());
    const id = decodeURIComponent(
      url.pathname.split('/by-property/')[1]?.split('?')[0] || '',
    );
    const match = records.find((r) => r.property_id === id) || records[0];
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ assessment: match }),
    });
  });

  await page.goto(`${base}/entrepreneur/assessments`, {
    waitUntil: 'networkidle',
    timeout: 30000,
  });
  await page.waitForSelector('.audit-table tbody tr', { timeout: 15000 });
  await page.waitForTimeout(400);

  const checks = {};

  // --- chrome present -------------------------------------------------------
  checks['app shell entrepreneur'] =
    (await page.locator('.app-shell.app-shell--entrepreneur').count()) === 1;
  checks['pill nav present'] = await page.evaluate(() => {
    const nav = document.querySelector('.app-pill__nav');
    return nav ? nav.querySelectorAll('a').length : 0;
  });
  checks['assessment tab marked current'] = await page.evaluate(() => {
    const active = document.querySelector('.app-pill__link--active');
    return !!active && active.textContent.trim() === 'Assessment';
  });

  // --- no duplicated furniture ---------------------------------------------
  checks['single page head'] = (await page.locator('.page-head').count()) === 1;
  checks['single breadcrumb trail'] = (await page.locator('.crumbs').count()) === 1;
  checks['single dev bypass banner'] =
    (await page.locator('.app-content__inner > .panel[role="status"]').count()) <= 1;

  // --- the tab is not double-inset -----------------------------------------
  const band = await page.evaluate(() => {
    const inner = document.querySelector('.app-content__inner');
    const page_ = document.querySelector('.asw-page');
    if (!inner || !page_) return null;
    const cs = getComputedStyle(inner);
    const usable =
      inner.getBoundingClientRect().width -
      parseFloat(cs.paddingLeft) -
      parseFloat(cs.paddingRight);
    return {
      usable: Math.round(usable),
      pageWidth: Math.round(page_.getBoundingClientRect().width),
      pageMaxWidth: getComputedStyle(page_).maxWidth,
    };
  });
  checks['no second width band'] =
    !!band &&
    band.pageMaxWidth === 'none' &&
    Math.abs(band.usable - band.pageWidth) <= 2;

  // Where this tab actually starts drawing text. The Report tab insets its
  // content inside `main.sra-workspace`; if the two disagree, the whole page
  // jumps sideways on every tab switch.
  const aswLeft = await page.evaluate(() => {
    const el = document.querySelector('.asw-page');
    if (!el) return null;
    const cs = getComputedStyle(el);
    return Math.round(el.getBoundingClientRect().left + parseFloat(cs.paddingLeft));
  });

  // --- interaction feedback matches the report tab --------------------------
  const btn = await page.evaluate(() => {
    const el = document.querySelector('.asw-row-btn:not(.asw-row-btn--danger)');
    if (!el) return null;
    const cs = getComputedStyle(el);
    return { transition: cs.transitionProperty, duration: cs.transitionDuration };
  });
  checks['row button animates hover'] =
    !!btn && /background/.test(btn.transition) && /transform/.test(btn.transition);

  const bar = await page.evaluate(() => {
    const el = document.querySelector('.asw-step__bar');
    return el ? Math.round(el.getBoundingClientRect().height) : null;
  });
  checks['progress bar 6px (matches report)'] = bar === 6;

  const rowHover = await (async () => {
    const row = page.locator('.audit-table tbody tr').first();
    const before = await row.evaluate((el) => getComputedStyle(el).backgroundColor);
    await row.hover();
    await page.waitForTimeout(260);
    const after = await row.evaluate((el) => getComputedStyle(el).backgroundColor);
    await page.mouse.move(4, 4);
    return { before, after };
  })();
  checks['row answers hover'] = rowHover.before !== rowHover.after;

  await page.screenshot({
    path: path.join(outdir, 'assessments_chrome.png'),
    fullPage: true,
  });

  // --- the actual requirement: tab switch does not reload the document ------
  await page.evaluate(() => {
    window.__swSameDocument = true;
  });
  const navCountBefore = await page.evaluate(
    () => performance.getEntriesByType('navigation').length,
  );
  await page.locator('.app-pill__link', { hasText: 'Report' }).click();
  await page.waitForURL('**/entrepreneur/cafe-report', { timeout: 15000 });
  await page.waitForTimeout(900);

  const survived = await page.evaluate(() => window.__swSameDocument === true);
  const navCountAfter = await page.evaluate(
    () => performance.getEntriesByType('navigation').length,
  );
  checks['nav link switched tab'] = page.url().includes('/entrepreneur/cafe-report');
  checks['no document reload on tab switch'] = survived && navCountAfter === navCountBefore;
  checks['report tab still has pill nav'] =
    (await page.locator('.app-pill__nav a').count()) >= 8;

  const reportLeft = await page.evaluate(() => {
    const el = document.querySelector('.sra-workspace');
    if (!el) return null;
    const cs = getComputedStyle(el);
    return Math.round(el.getBoundingClientRect().left + parseFloat(cs.paddingLeft));
  });
  checks['content inset matches report tab'] =
    aswLeft !== null && reportLeft !== null && Math.abs(aswLeft - reportLeft) <= 1;

  await page.screenshot({
    path: path.join(outdir, 'assessments_chrome_report_after_switch.png'),
    fullPage: true,
  });

  console.log('band:', JSON.stringify(band), 'button:', JSON.stringify(btn));
  console.log('content inset px:', JSON.stringify({ assessments: aswLeft, report: reportLeft }));
  console.log('row hover:', JSON.stringify(rowHover));
  console.log('checks:', JSON.stringify(checks, null, 1));
  const failed = Object.entries(checks).filter(([, v]) => !v).map(([k]) => k);
  console.log(
    failed.length ? 'FAILED: ' + failed.join(', ') : 'ALL CHECKS PASSED',
  );
  console.log(errors.length ? errors.join('\n') : 'no console/page errors');
  await browser.close();
  process.exit(failed.length ? 2 : 0);
})().catch((e) => {
  console.error('FATAL', e.message);
  process.exit(1);
});
