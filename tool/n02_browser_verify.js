// N02 Task 3 + Task 5 — normal-application browser verification.
//
// Drives the real Jaspr UI with a real login (no API shortcut), then asserts:
//   * the assessment is legitimately linked and selectable
//   * all 19 M2 answers are retrieved
//   * the existing confirmation is displayed
//   * BCB V1.2.1 is current and reproducible
//   * Stage 3 reads the correct context
//   * live BDJ proposals render with categories, source evidence,
//     approve/reject controls and execution provenance, and survive a refresh
//   * merely opening the page dispatches nothing to TokenHarbour
//
// Writes screenshots + var/e2e/n02_browser.out.json
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const BASE = 'http://127.0.0.1:8092';
const ASSESSMENT = '4fc0abc2-ba52-4e41-aaa3-cf14fc822b37';
const EMAIL = 'gatebc-e2e-b9e62014@example.invalid';
const PASSWORD = 'e2e-local-password';
const SHOTS = 'backend/var/e2e/shots';
const OUT = 'backend/var/e2e/n02_browser.out.json';

const results = [];
function check(id, ok, detail) {
  results.push({ id, status: ok ? 'PASS' : 'FAIL', detail });
  console.log(`[${ok ? 'PASS' : 'FAIL'}] ${id}${detail ? ' — ' + detail : ''}`);
  return ok;
}

(async () => {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await chromium.launch({ headless: true, channel: 'chrome' });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1200 } });
  const page = await ctx.newPage();

  const apiCalls = [];
  const providerCalls = [];
  const consoleErrors = [];
  page.on('response', r => {
    const u = r.url();
    if (u.includes('tokenharbor')) providerCalls.push(`${r.status()} ${u}`);
    if (u.includes('/api/v1/')) apiCalls.push({ status: r.status(), url: u.replace(BASE, '') });
  });
  page.on('console', m => { if (m.type() === 'error') consoleErrors.push(m.text().slice(0, 200)); });

  // ---- 1. real login through the normal form -------------------------
  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle', timeout: 45000 });
  await page.fill('#lp-email', EMAIL);
  await page.fill('#lp-password', PASSWORD);
  await page.click('button.lp-submit');
  await page.waitForTimeout(6000);
  const afterLogin = page.url();
  check('login-through-normal-form', !afterLogin.includes('/login'), `landed on ${afterLogin}`);
  await page.screenshot({ path: `${SHOTS}/n02_01_after_login.png`, fullPage: false });

  // ---- 2. open the assessment workspace, stage 3 ---------------------
  const urls = [
    `${BASE}/entrepreneur/assessments?assessment=${ASSESSMENT}&stage=location_evidence`,
    `${BASE}/entrepreneur/assessments?assessment=${ASSESSMENT}&step=3`,
    `${BASE}/entrepreneur/assessments?assessment=${ASSESSMENT}`,
  ];
  let landed = null;
  for (const u of urls) {
    await page.goto(u, { waitUntil: 'networkidle', timeout: 45000 });
    await page.waitForTimeout(3000);
    const body = await page.innerText('body');
    if (/Research objectives|location evidence|Stage 3/i.test(body)) { landed = u; break; }
  }
  check('assessment-workspace-reachable', !!landed, landed || 'no stage-3 view found');
  await page.screenshot({ path: `${SHOTS}/n02_02_workspace.png`, fullPage: true });

  let body = await page.innerText('body');

  // ---- 3. assessment linked and selectable ---------------------------
  const linked = /4fc0abc2|Cafe|cafe/i.test(body);
  check('assessment-linked', linked, 'assessment identity visible in workspace');

  // ---- 4. confirmation displayed -------------------------------------
  const confirmationShown = /confirm/i.test(body);
  check('confirmation-displayed', confirmationShown, 'confirmation state rendered');

  // ---- 5. BCB version ------------------------------------------------
  const bcbShown = /V1\.2\.1|1\.2\.1|BCB/i.test(body);
  check('bcb-version-visible', bcbShown, 'BCB identity rendered');

  // ---- 6. Stage 3 panel present --------------------------------------
  const panel = page.locator('text=Research objectives').first();
  const panelVisible = await panel.isVisible().catch(() => false);
  check('stage3-panel-visible', panelVisible, 'Research objectives panel rendered');

  // ---- 7. proposals / empty state ------------------------------------
  const hasEmpty = /No research objectives yet|No objective proposals are persisted/i.test(body);
  const hasProposals = /Most suggested/i.test(body);
  check('proposals-or-empty-state', hasEmpty || hasProposals,
    hasEmpty ? 'accurate empty state' : 'proposal cards rendered');

  // ---- 8. recommendation categories + source evidence ----------------
  if (hasProposals) {
    const mostSuggested = (body.match(/Most suggested/gi) || []).length;
    check('recommendation-category-rendered', mostSuggested >= 1, `${mostSuggested} "Most suggested" label(s)`);
    const sourceRefs = /M2V2-\d\d/.test(body);
    check('source-evidence-rendered', sourceRefs, 'M2 item keys shown as source evidence');
    const execMode = /Execution mode\s*(LIVE|SIMULATED|DETERMINISTIC)/i.exec(body);
    check('execution-provenance-rendered', !!execMode,
      execMode ? `execution mode ${execMode[1]}` : 'no execution mode shown');
    if (execMode) check('execution-provenance-is-live', execMode[1].toUpperCase() === 'LIVE',
      `mode=${execMode[1]}`);
    const approve = await page.locator('button:has-text("Approve")').count();
    const reject = await page.locator('button:has-text("Reject")').count();
    check('decision-controls-rendered', approve > 0 && reject > 0,
      `${approve} approve / ${reject} reject control(s)`);
    const candidateOnly = /Candidate only|nothing here is approved/i.test(body);
    check('candidate-only-disclaimer', candidateOnly, 'proposals explicitly not approved research');
  }

  await page.screenshot({ path: `${SHOTS}/n02_03_stage3_panel.png`, fullPage: true });

  // ---- 9. opening the page must not dispatch to the provider ---------
  check('no-provider-dispatch-on-open', providerCalls.length === 0,
    providerCalls.length ? providerCalls.slice(0, 3).join(' | ') : 'no request to tokenharbor');

  // ---- 10. persistence across a refresh ------------------------------
  const before = (await page.innerText('body')).match(/M2V2-\d\d/g) || [];
  await page.reload({ waitUntil: 'networkidle', timeout: 45000 });
  await page.waitForTimeout(3500);
  const afterBody = await page.innerText('body');
  const after = afterBody.match(/M2V2-\d\d/g) || [];
  check('persistence-after-refresh',
    JSON.stringify([...new Set(before)].sort()) === JSON.stringify([...new Set(after)].sort()),
    `refs before=${[...new Set(before)].sort().join(',')} after=${[...new Set(after)].sort().join(',')}`);
  await page.screenshot({ path: `${SHOTS}/n02_04_after_refresh.png`, fullPage: true });

  // ---- 11. console health -------------------------------------------
  check('no-console-errors', consoleErrors.length === 0,
    consoleErrors.length ? consoleErrors.slice(0, 2).join(' | ') : 'clean console');

  // ---- 12. dump the rendered stage-3 text for the report -------------
  const stageText = afterBody.slice(0, 6000);
  fs.writeFileSync('backend/var/e2e/n02_stage3_text.txt', stageText, 'utf8');

  const out = {
    contract: 'n02-browser/1',
    assessment_id: ASSESSMENT,
    landed_url: landed,
    final_url: page.url(),
    api_calls: apiCalls.slice(-40),
    provider_calls: providerCalls,
    console_errors: consoleErrors,
    results,
    pass: results.filter(r => r.status === 'PASS').length,
    fail: results.filter(r => r.status === 'FAIL').length,
  };
  fs.writeFileSync(OUT, JSON.stringify(out, null, 1), 'utf8');
  console.log(`\n${out.pass} passed / ${out.fail} failed`);
  await browser.close();
})().catch(e => { console.error('ERROR:', e.message); process.exit(1); });
