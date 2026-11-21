// Compare the CLICK/HOVER feedback of the Assessment tab and the Report tab.
//
// Measures computed styles in each interaction state (normal → hover →
// selected/active) on both live pages, and saves cropped screenshots of the
// list areas for visual comparison.
//
// Run:
//   NODE_PATH=C:/Users/Lenovo/.workbuddy-ai/binaries/node/workspace/node_modules \
//   node tool/probe_click_states.js [baseUrl] [outdir]
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness.js');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const catalogueRows = JSON.parse(
  fs.readFileSync(
    path.join(__dirname, '..', '..', 'test', '.data', 'jaspr_catalog_fixture.json'),
    'utf8',
  ),
).rows;

function record(i, { status = 'in_progress', completed = 1, report = false } = {}) {
  const prop = catalogueRows[i % catalogueRows.length];
  const iso = '2026-11-15T09:00:00Z';
  const stage = (key, number, title, s) => ({
    key,
    number,
    title,
    status: s,
    completed_at: s === 'complete' ? iso : null,
    unavailable_reason: null,
  });
  return {
    assessment_id: `AS-CLICK-${i}`,
    property_id: prop.id,
    status,
    current_stage: completed + 1,
    current_stage_key: 'location_evidence',
    completed_stages: completed,
    total_stages: 5,
    progress_percent: completed * 20,
    report_available: report,
    requirements: { business_type: 'Cafe' },
    requirements_version: 3,
    stages: [
      stage('select_property', 1, 'Select property', 'complete'),
      stage('business_requirements', 2, 'Business preferences', completed >= 1 ? 'complete' : 'current'),
      stage('location_evidence', 3, 'Location evidence', completed >= 2 ? 'complete' : 'incomplete'),
      stage('ai_explanation', 4, 'AI explanation', 'incomplete'),
      stage('assessment_report', 5, 'Assessment report', 'incomplete'),
    ],
    capabilities: {},
    next_action: { kind: 'continue', stage_key: 'location_evidence', label: 'Review location evidence', reason: null },
    property: prop,
    created_at: iso,
    updated_at: iso,
  };
}

const RECORDS = [
  record(0, { completed: 1 }),
  record(1, { completed: 2 }),
  record(2, { completed: 0 }),
];

const style = (el) => {
  const cs = getComputedStyle(el);
  return {
    background: cs.backgroundColor,
    border: cs.borderColor,
    borderWidth: cs.borderWidth,
    radius: cs.borderRadius,
    shadow: cs.boxShadow === 'none' ? 'none' : cs.boxShadow,
    transform: cs.transform,
    filter: cs.filter,
    transition: cs.transitionDuration,
    outline: cs.outlineStyle === 'none' ? 'none' : `${cs.outlineWidth} ${cs.outlineColor}`,
    cursor: cs.cursor,
  };
};

(async () => {
  const base = process.argv[2] || 'http://127.0.0.1:8091';
  const outdir = process.argv[3] || 'tool/screenshots';
  fs.mkdirSync(outdir, { recursive: true });

  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox', '--no-proxy-server'] });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1000 }, bypassCSP: true });
  const page = await ctx.newPage();
  await installHarnessSession(page, { role: 'entrepreneur' });
  await page.route('**/api/v1/assessments/me**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ data: RECORDS, meta: { total: RECORDS.length } }),
    }),
  );

  const out = {};

  // ---------- REPORT TAB ----------
  await page.goto(`${base}/entrepreneur/cafe-report`, { waitUntil: 'networkidle', timeout: 30000 });
  await page.waitForSelector('.sra-assessment-row', { timeout: 15000 });
  await page.waitForTimeout(400);

  // The first record is auto-selected on mount, so sample a row that is NOT
  // selected for the normal/hover states — otherwise every sample reads back
  // the selected style.
  const rowSel = '.sra-assessment-row';
  const idleRowSel = '.sra-assessment-row:not(.selected)';
  const btnSel = '.sra-button.primary';
  out.report = {
    rowNormal: await page.$eval(idleRowSel, style),
    buttonNormal: await page.$eval(btnSel, style),
  };
  await page.hover(idleRowSel);
  await page.waitForTimeout(250);
  out.report.rowHover = await page.$eval(idleRowSel, style);
  await page.screenshot({ path: path.join(outdir, 'click_report_hover.png'), clip: await page.$eval('.sra-list-panel', (el) => {
    const r = el.getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: Math.min(r.height, 560) };
  }) });

  // Selected state = click a row that is not already selected.
  const rows = await page.$$(rowSel);
  await rows[1].click();
  await page.waitForTimeout(250);
  out.report.rowSelected = await page.$eval(`${rowSel}.selected`, style);
  await page.screenshot({ path: path.join(outdir, 'click_report_selected.png'), clip: await page.$eval('.sra-list-panel', (el) => {
    const r = el.getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: Math.min(r.height, 560) };
  }) });

  // Button hover + pressed (:active).
  await page.hover(btnSel);
  await page.waitForTimeout(250);
  out.report.buttonHover = await page.$eval(btnSel, style);
  const box = await (await page.$(btnSel)).boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.waitForTimeout(140);
  out.report.buttonActive = await page.$eval(btnSel, style);
  await page.mouse.move(5, 5);
  await page.mouse.up();

  // ---------- ASSESSMENT TAB ----------
  await page.goto(`${base}/entrepreneur/assessments`, { waitUntil: 'networkidle', timeout: 30000 });
  await page.waitForSelector('table.audit-table', { timeout: 15000 });
  await page.waitForTimeout(500);

  out.assessment = {
    // The list row itself (is it interactive at all?).
    tableRow: await page.$eval('table.audit-table tbody tr', style),
    // The row's action button — the real click target.
    rowButton: await page.$eval('.asw-row-btn', style),
    // The page-level CTA (.btn vocabulary: lift + press scale).
    pageButton: await page.$eval('.btn', style),
    // Filter chips.
    filterTab: await page.$eval('.tab[aria-selected="false"]', style),
  };
  await page.hover('table.audit-table tbody tr');
  await page.waitForTimeout(250);
  out.assessment.tableRowHover = await page.$eval('table.audit-table tbody tr td', style);

  await page.hover('.asw-row-btn');
  await page.waitForTimeout(300);
  out.assessment.rowButtonHover = await page.$eval('.asw-row-btn', style);

  // Page-level CTA (.btn): hover lift and press scale.
  await page.hover('.btn');
  await page.waitForTimeout(300);
  out.assessment.pageButtonHover = await page.$eval('.btn', style);
  const b3 = await (await page.$('.btn')).boundingBox();
  await page.mouse.move(b3.x + b3.width / 2, b3.y + b3.height / 2);
  await page.mouse.down();
  await page.waitForTimeout(160);
  out.assessment.pageButtonActive = await page.$eval('.btn', style);
  await page.mouse.move(5, 5);
  await page.mouse.up();

  // Selected filter chip (solid fill). Done BEFORE the press test, because
  // releasing the mouse on a real button would click it and navigate away.
  await page.click('.tab[aria-selected="false"]');
  await page.waitForTimeout(250);
  out.assessment.filterTabSelected = await page.$eval('.tab[aria-selected="true"]', style);
  await page.click('.tab[aria-selected="false"]'); // back to "All"
  await page.waitForTimeout(200);

  const tableBox = await page.$eval('section.panel', (el) => {
    const r = el.getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: Math.min(r.height, 620) };
  });
  await page.screenshot({ path: path.join(outdir, 'click_assessment_list.png'), clip: tableBox });
  await page.hover('.asw-row-btn');
  await page.waitForTimeout(250);
  await page.screenshot({ path: path.join(outdir, 'click_assessment_hover.png'), clip: tableBox });

  // Pressed state: press down on the button, measure, then move away and
  // release so no click/navigation fires.
  const b2 = await (await page.$('.asw-row-btn')).boundingBox();
  await page.mouse.move(b2.x + b2.width / 2, b2.y + b2.height / 2);
  await page.mouse.down();
  await page.waitForTimeout(140);
  out.assessment.rowButtonActive = await page.$eval('.asw-row-btn', style);
  await page.mouse.move(5, 5);
  await page.mouse.up();

  fs.writeFileSync(path.join(outdir, 'click_states.json'), JSON.stringify(out, null, 2));
  console.log(JSON.stringify(out, null, 2));
  await browser.close();
})().catch((e) => {
  console.error('FATAL', e.message);
  process.exit(1);
});
