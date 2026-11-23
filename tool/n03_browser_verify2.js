// N03 — real Jaspr browser E2E, second pass.
//
// Adds what the first pass could not answer:
//   * is the research-objective surface reachable through NORMAL navigation,
//     or only by typing the standalone URL?
//   * do the proposals render on Stage 3 rather than inside Stage 2?
//
// Read-only. Writes screenshots + backend/var/e2e/n03_browser2.out.json.
const { chromium } = require('playwright');
const fs = require('fs');

const BASE = 'http://127.0.0.1:8092';
const ASSESSMENT = '4fc0abc2-ba52-4e41-aaa3-cf14fc822b37';
const SHOTS = 'backend/var/e2e/shots';

const results = [];
function check(id, ok, detail) {
  results.push({ id, status: ok ? 'PASS' : 'FAIL', detail });
  console.log(`[${ok ? 'PASS' : 'FAIL'}] ${id}${detail ? ' — ' + detail : ''}`);
}
function note(id, detail) {
  results.push({ id, status: 'INFO', detail });
  console.log(`[INFO] ${id}${detail ? ' — ' + detail : ''}`);
}

(async () => {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await chromium.launch({ headless: true, channel: 'chrome' });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1800 } });
  const page = await ctx.newPage();

  const providerCalls = [];
  const api = [];
  const consoleErrors = [];
  page.on('response', r => {
    const u = r.url();
    if (u.includes('tokenharbor')) providerCalls.push(`${r.status()} ${u}`);
    if (u.includes('/api/v1/m2/') || u.includes('objective-proposals'))
      api.push(`${r.request().method()} ${r.status()} ${u.replace(BASE, '').slice(0, 130)}`);
  });
  const failedResources = [];
  page.on('response', r => {
    if (r.status() >= 400 && !r.url().includes('/api/')) failedResources.push(`${r.status()} ${r.url()}`);
  });
  page.on('console', m => { if (m.type() === 'error') consoleErrors.push(m.text().slice(0, 160)); });

  // ---- 1. real login through the normal form ------------------------
  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle', timeout: 45000 });
  await page.fill('#lp-email', 'gatebc-e2e-b9e62014@example.invalid');
  await page.fill('#lp-password', 'e2e-local-password');
  await page.click('button.lp-submit');
  await page.waitForTimeout(6000);
  const afterLogin = page.url();
  check('login-succeeded', !/\/login/.test(afterLogin), `landed on ${afterLogin.replace(BASE, '')}`);
  await page.screenshot({ path: `${SHOTS}/n03b_01_after_login.png`, fullPage: true });

  // ---- 2. is the standalone route reachable from the UI? ------------
  // The sidebar is the normal way a user reaches a destination. Count links.
  const sidebarLinks = await page.locator('a[href*="m2-workflow"]').count();
  const navLinks = await page.locator('nav a[href*="m2-workflow"], aside a[href*="m2-workflow"]').count();
  note('sidebar-link-to-m2-workflow', `${sidebarLinks} link(s) in DOM, ${navLinks} inside nav/aside`);

  // Walk the Assessment destination, which IS a sidebar entry.
  await page.goto(`${BASE}/entrepreneur/assessments`, { waitUntil: 'networkidle', timeout: 45000 });
  await page.waitForTimeout(5000);
  const assessBody = await page.innerText('body');
  await page.screenshot({ path: `${SHOTS}/n03b_02_assessments_normal_nav.png`, fullPage: true });
  check('assessment-destination-loads', assessBody.length > 200,
    `${assessBody.length} chars rendered`);

  // The only in-app link to the standalone route is the DEF-11 unbound notice,
  // which appears for an assessment with no verified M2 link.
  const fallbackLink = await page.locator('a[href*="m2-workflow"]').count();
  note('fallback-link-present', `${fallbackLink} in-app link(s) to the standalone route on this page`);

  // ---- 3. deep link to the standalone page -------------------------
  await page.goto(`${BASE}/entrepreneur/m2-workflow?assessment=${ASSESSMENT}`,
    { waitUntil: 'networkidle', timeout: 45000 });
  await page.waitForTimeout(9000);
  let body = await page.innerText('body');
  fs.writeFileSync('backend/var/e2e/n03b_stage2_text.txt', body, 'utf8');
  await page.screenshot({ path: `${SHOTS}/n03b_03_stage2_default.png`, fullPage: true });

  // ---- 4. Stage 2 is the default, and Stage 3 content is NOT here ---
  const stepper = page.locator('.asw-stage-switch');
  const stepperVisible = await stepper.isVisible().catch(() => false);
  check('stage-stepper-present', stepperVisible,
    stepperVisible ? 'Stage 2 / Stage 3 switch rendered' : 'stepper absent');

  const stage2Active = await page.locator('.asw-stage-switch .tab.is-active:has-text("Stage 2")').count();
  check('stage2-is-default', stage2Active === 1, `${stage2Active} active Stage 2 pill`);

  const proposalsOnStage2 = /Most suggested/i.test(body) ||
    /explore what the entrepreneur wants to establish first about interest/i.test(body);
  check('proposals-absent-from-stage2', !proposalsOnStage2,
    proposalsOnStage2 ? 'proposals still leak into Stage 2' : 'Stage 2 shows no proposals');

  const stage3Enabled = await page.locator('.asw-stage-switch button:has-text("Stage 3"):not([disabled])').count();
  check('stage3-unlocked-by-confirmation', stage3Enabled === 1,
    stage3Enabled === 1 ? 'Stage 3 pill enabled (declaration confirmed)' : 'Stage 3 pill disabled');

  // ---- 5. open Stage 3 ---------------------------------------------
  await page.locator('.asw-stage-switch button:has-text("Stage 3")').click();
  await page.waitForTimeout(9000);
  body = await page.innerText('body');
  fs.writeFileSync('backend/var/e2e/n03b_stage3_text.txt', body, 'utf8');
  await page.screenshot({ path: `${SHOTS}/n03b_04_stage3_objectives.png`, fullPage: true });

  const stage3Active = await page.locator('.asw-stage-switch .tab.is-active:has-text("Stage 3")').count();
  check('stage3-activates', stage3Active === 1, `${stage3Active} active Stage 3 pill`);

  // Stage 3 must not carry the Stage 2 questionnaire: if it does, the objectives
  // still read as part of the declaration.
  const questionnaireOnStage3 = /Which area are you currently considering/i.test(body) ||
    /Question \d+ of 19/i.test(body);
  check('stage3-hides-questionnaire', !questionnaireOnStage3,
    questionnaireOnStage3 ? 'questionnaire still rendered on Stage 3' : 'Stage 3 shows objectives only');

  // ---- 6. the two LIVE proposals, on Stage 3 -----------------------
  const countLine = /2 proposals\s*·\s*2 source-confirmed/i.test(body);
  check('two-source-confirmed-proposals', countLine,
    /2 proposals[^\n]*/.exec(body)?.[0]?.slice(0, 60) || 'count line missing');

  const hasP1 = /explore what the entrepreneur wants to establish first about interest/i.test(body);
  const hasP2 = /investigate candidate trading areas and the locational considerations/i.test(body);
  check('proposal-65121f3e-visible', hasP1, 'objective text of 65121f3e rendered on Stage 3');
  check('proposal-c3a8c85e-visible', hasP2, 'objective text of c3a8c85e rendered on Stage 3');

  const mostSuggested = (body.match(/Most suggested/gi) || []).length;
  check('recommendation-category', mostSuggested >= 2, `${mostSuggested} "Most suggested" label(s)`);

  const reason1 = /despite naming concept interest as the priority topic/i.test(body);
  const reason2 = /leaves the geographic scope of any later customer work undefined/i.test(body);
  check('reason-text-rendered', reason1 && reason2, `reason1=${reason1} reason2=${reason2}`);

  const src = /M2V2-11/.test(body) && /M2V2-01/.test(body);
  check('source-references-rendered', src,
    `M2V2-01=${/M2V2-01/.test(body)} M2V2-11=${/M2V2-11/.test(body)}`);

  const exec = /Execution mode\s*(LIVE|SIMULATED|DETERMINISTIC)/i.exec(body);
  check('execution-provenance', !!exec, exec ? `mode ${exec[1]}` : 'not shown');
  if (exec) check('execution-provenance-is-live', exec[1].toUpperCase() === 'LIVE', exec[1]);
  const model = /deepseek-v4\.1-flash-1017/i.test(body);
  check('model-identity-rendered', model, model ? 'deepseek-v4.1-flash-1017' : 'not shown');
  const validation = /validation VALID/i.test(body);
  check('validation-status-rendered', validation, validation ? 'validation VALID' : 'not shown');
  const reviewState = /Awaiting your decision/i.test(body) && !/Review state unreadable/i.test(body);
  check('review-state-readable', reviewState,
    reviewState ? 'CANDIDATE renders as Awaiting your decision' : 'still unreadable');

  // ---- 7. owner controls present, no decision changed ---------------
  const approve = await page.locator('button:has-text("Approve")').count();
  const reject = await page.locator('button:has-text("Reject")').count();
  check('review-controls', approve > 0 && reject > 0, `${approve} approve / ${reject} reject`);
  const candidateOnly = /Candidate only|nothing here is approved/i.test(body);
  check('candidate-only-disclaimer', candidateOnly, 'proposals not presented as approved');

  // ---- 8. confirmation / context identity --------------------------
  const conf = /bb0e20c8-f565-409e-943e-fd555aa336a0/i.test(body) && /revision 23/i.test(body);
  check('confirmation-rev-23', conf,
    /bb0e20c8[^\s]*/i.exec(body)?.[0] || 'confirmation not rendered');
  const ctxLine = /Business context\s+141d8ffc[^\n]*persisted and current/i.test(body);
  check('bcb-context-persisted-current', ctxLine,
    ctxLine ? 'context stated persisted and current' : 'context status line missing');

  // ---- 9. refresh: same proposals after reopening Stage 3 ----------
  await page.reload({ waitUntil: 'networkidle', timeout: 45000 });
  await page.waitForTimeout(9000);
  const afterReload = await page.innerText('body');
  const resetToStage2 = /Most suggested/i.test(afterReload) === false;
  note('stage-resets-to-2-on-reload', resetToStage2
    ? 'reload returns to Stage 2 (stage is view state, not persisted)'
    : 'reload kept Stage 3');
  await page.locator('.asw-stage-switch button:has-text("Stage 3")').click();
  await page.waitForTimeout(9000);
  const afterBody = await page.innerText('body');
  const afterIds = [
    /explore what the entrepreneur wants to establish first about interest/i.test(afterBody),
    /investigate candidate trading areas and the locational considerations/i.test(afterBody),
  ];
  check('persistence-after-refresh', afterIds.every(Boolean),
    `proposal1=${afterIds[0]} proposal2=${afterIds[1]} after reload + reopen`);
  const afterSrc = /M2V2-11/.test(afterBody) && /M2V2-01/.test(afterBody);
  check('persistence-source-refs', afterSrc, 'source refs survive refresh');
  await page.screenshot({ path: `${SHOTS}/n03b_05_after_refresh_stage3.png`, fullPage: true });

  // ---- 10. read-only guarantees ------------------------------------
  check('no-tokenharbour-call', providerCalls.length === 0,
    providerCalls.length ? providerCalls.slice(0, 3).join(' | ') : 'zero provider requests');
  const writes = api.filter(l => /^(POST|PUT|PATCH|DELETE)/.test(l));
  check('no-write-calls', writes.length === 0,
    writes.length ? writes.slice(0, 3).join(' | ') : 'read-only session');

  const KNOWN_ORPHAN = 'assessment_overview_page.css';
  const unexpected = [...new Set(failedResources)].filter(u => !u.includes(KNOWN_ORPHAN));
  check('no-unexpected-resource-failures', unexpected.length === 0,
    unexpected.slice(0, 3).join(' | ') || 'only the known orphan stylesheet');
  const scriptErrors = consoleErrors.filter(e => !/Failed to load resource/i.test(e));
  check('no-script-errors', scriptErrors.length === 0,
    scriptErrors.slice(0, 2).join(' | ') || 'no JavaScript errors');

  // ---- 11. reachability verdict ------------------------------------
  // The route is registered but has no sidebar destination. The only in-app
  // link is the DEF-11 unbound notice, which appears only for an assessment
  // with no verified M2 link. That is not the normal workflow for a confirmed
  // M2 assessment, so this is reported honestly as PARTIAL.
  const reachableNormally = sidebarLinks > 0 || navLinks > 0;
  check('reachable-without-typing-url', reachableNormally,
    reachableNormally
      ? 'a sidebar/nav destination exists'
      : 'no sidebar destination; only the unbound-assessment fallback links here');

  const out = {
    contract: 'n03-browser/2', assessment_id: ASSESSMENT,
    final_url: page.url(), api: api.slice(-30),
    provider_calls: providerCalls, console_errors: consoleErrors,
    failed_resources: [...new Set(failedResources)],
    results, pass: results.filter(r => r.status === 'PASS').length,
    fail: results.filter(r => r.status === 'FAIL').length,
  };
  fs.writeFileSync('backend/var/e2e/n03_browser2.out.json', JSON.stringify(out, null, 1), 'utf8');
  console.log(`\n${out.pass} passed / ${out.fail} failed`);
  await browser.close();
})().catch(e => { console.error('ERROR:', e.message); process.exit(1); });
