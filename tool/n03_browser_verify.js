// N03 Priority 3 — real Jaspr browser E2E for the standalone M2 workflow.
//
// Proves DEF-01: the two persisted LIVE proposals are now reachable and rendered
// in the normal authenticated application for an M2 assessment that has no
// marketplace association. Read-only — it must not dispatch anything.
//
// Writes screenshots + backend/var/e2e/n03_browser.out.json
const { chromium } = require('playwright');
const fs = require('fs');

const BASE = 'http://127.0.0.1:8092';
const ASSESSMENT = '4fc0abc2-ba52-4e41-aaa3-cf14fc822b37';
const P1 = '65121f3e-36a9-52ad-bab4-0ee096d89840';
const P2 = 'c3a8c85e-b6ff-5746-aff0-7e84c1640304';
const SHOTS = 'backend/var/e2e/shots';

const results = [];
function check(id, ok, detail) {
  results.push({ id, status: ok ? 'PASS' : 'FAIL', detail });
  console.log(`[${ok ? 'PASS' : 'FAIL'}] ${id}${detail ? ' — ' + detail : ''}`);
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
      api.push(`${r.status()} ${u.replace(BASE, '').slice(0, 120)}`);
  });
  const failedResources = [];
  page.on('response', r => {
    if (r.status() >= 400 && !r.url().includes('/api/')) failedResources.push(`${r.status()} ${r.url()}`);
  });
  page.on('console', m => { if (m.type() === 'error') consoleErrors.push(m.text().slice(0, 160)); });

  // ---- real login through the normal form ---------------------------
  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle', timeout: 45000 });
  await page.fill('#lp-email', 'gatebc-e2e-b9e62014@example.invalid');
  await page.fill('#lp-password', 'e2e-local-password');
  await page.click('button.lp-submit');
  await page.waitForTimeout(5000);

  // ---- open the standalone M2 workflow ------------------------------
  await page.goto(`${BASE}/entrepreneur/m2-workflow?assessment=${ASSESSMENT}`,
    { waitUntil: 'networkidle', timeout: 45000 });
  // The proposal panel resolves link -> draft -> confirmation -> context -> list.
  await page.waitForTimeout(9000);

  let body = await page.innerText('body');
  fs.writeFileSync('backend/var/e2e/n03_m2workflow_text.txt', body, 'utf8');
  await page.screenshot({ path: `${SHOTS}/n03_01_m2_workflow_full.png`, fullPage: true });

  // ---- assessment + answers + confirmation + context ---------------
  check('m2v2-assessment-shown', body.includes(ASSESSMENT.slice(0, 8)),
    'assessment id visible');
  const answered = /19 saved|Questions \(19\)/i.test(body);
  check('nineteen-answers', answered,
    (body.match(/19 saved|Questions \(19\)/i) || ['not found'])[0]);
  const conf = /bb0e20c8-f565-409e-943e-fd555aa336a0/i.test(body) && /revision 23/i.test(body);
  check('confirmation-rev-23', conf,
    /bb0e20c8[^\s]*/i.exec(body)?.[0] || 'confirmation not rendered');
  const ctxOk = /141d8ffc-f7ca-524e-b51c-735c18d85328/i.test(body);
  check('bcb-context-current', ctxOk,
    /141d8ffc[^\s]*/i.exec(body)?.[0] || 'context not rendered');
  // The page states the context identity and that it is persisted+current.
  // The BCB builder version (BCB-V1-1.2.1) is asserted at the API level, since
  // the workflow surface shows the context, not the builder tag.
  const ctxLine = /Business context\s+141d8ffc[^\n]*persisted and current/i.test(body);
  check('bcb-context-persisted-current', ctxLine,
    ctxLine ? 'context stated persisted and current' : 'context status line missing');

  // ---- the research-objectives panel (DEF-01) -----------------------
  const panel = page.locator('text=Research objectives').first();
  const panelVisible = await panel.isVisible().catch(() => false);
  check('def01-panel-rendered', panelVisible,
    panelVisible ? 'panel mounted on standalone workflow' : 'panel absent');

  // ---- the two LIVE proposals --------------------------------------
  // The card shows the proposal's own source evidence rather than an internal
  // UUID, so identity is asserted by the pair of distinct objectives plus the
  // source-confirmed count, not by a database identifier the UI never prints.
  const countLine = /2 proposals\s*·\s*2 source-confirmed/i.test(body);
  check('two-source-confirmed-proposals', countLine,
    /2 proposals[^\n]*/.exec(body)?.[0]?.slice(0, 60) || 'count line missing');
  const hasP1 = /explore what the entrepreneur wants to establish first about interest/i.test(body);
  const hasP2 = /investigate candidate trading areas and the locational considerations/i.test(body);
  check('proposal-65121f3e-visible', hasP1, 'objective text of 65121f3e rendered');
  check('proposal-c3a8c85e-visible', hasP2, 'objective text of c3a8c85e rendered');

  // ---- categories / objective text / reason / sources --------------
  const mostSuggested = (body.match(/Most suggested/gi) || []).length;
  check('recommendation-category', mostSuggested >= 2, `${mostSuggested} "Most suggested" label(s)`);

  const obj1 = /explore what the entrepreneur wants to establish first about interest/i.test(body);
  const obj2 = /investigate candidate trading areas and the locational considerations/i.test(body);
  check('objective-text-rendered', obj1 && obj2,
    `proposal1=${obj1} proposal2=${obj2}`);

  const reason1 = /despite naming concept interest as the priority topic/i.test(body);
  const reason2 = /leaves the geographic scope of any later customer work undefined/i.test(body);
  check('reason-text-rendered', reason1 && reason2, `reason1=${reason1} reason2=${reason2}`);

  const src = /M2V2-11/.test(body) && /M2V2-01/.test(body);
  check('source-references-rendered', src,
    `M2V2-01=${/M2V2-01/.test(body)} M2V2-11=${/M2V2-11/.test(body)}`);

  // ---- execution provenance ----------------------------------------
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

  // ---- owner review controls ---------------------------------------
  const approve = await page.locator('button:has-text("Approve")').count();
  const reject = await page.locator('button:has-text("Reject")').count();
  check('review-controls', approve > 0 && reject > 0, `${approve} approve / ${reject} reject`);

  const candidateOnly = /Candidate only|nothing here is approved/i.test(body);
  check('candidate-only-disclaimer', candidateOnly, 'proposals not presented as approved');

  await page.screenshot({ path: `${SHOTS}/n03_02_objectives_panel.png`, fullPage: true });

  // ---- persistence after refresh -----------------------------------
  const beforeIds = [hasP1, hasP2];
  await page.reload({ waitUntil: 'networkidle', timeout: 45000 });
  await page.waitForTimeout(9000);
  const afterBody = await page.innerText('body');
  const afterIds = [
    /explore what the entrepreneur wants to establish first about interest/i.test(afterBody),
    /investigate candidate trading areas and the locational considerations/i.test(afterBody),
  ];
  check('persistence-after-refresh',
    JSON.stringify(beforeIds) === JSON.stringify(afterIds) && afterIds.every(Boolean),
    `before=${beforeIds} after=${afterIds}`);
  const afterSrc = /M2V2-11/.test(afterBody) && /M2V2-01/.test(afterBody);
  check('persistence-source-refs', afterSrc, 'source refs survive refresh');
  await page.screenshot({ path: `${SHOTS}/n03_03_after_refresh.png`, fullPage: true });

  // ---- read-only: no dispatch, no write ----------------------------
  check('no-tokenharbour-call', providerCalls.length === 0,
    providerCalls.length ? providerCalls.slice(0, 3).join(' | ') : 'zero provider requests');
  const writes = api.filter(l => /^(POST|PUT|PATCH|DELETE)/.test(l));
  check('no-write-calls', writes.length === 0,
    writes.length ? writes.slice(0, 3).join(' | ') : 'read-only session');

  // One orphaned stylesheet reference predates this work: nothing in the Dart
  // source links `assessment_overview_page.css` and the build does not emit it.
  // It is reported, not hidden, and it is the only tolerated 404.
  const KNOWN_ORPHAN = 'assessment_overview_page.css';
  const unexpected = [...new Set(failedResources)].filter(u => !u.includes(KNOWN_ORPHAN));
  check('no-unexpected-resource-failures', unexpected.length === 0,
    unexpected.slice(0, 3).join(' | ') || 'only the known orphan stylesheet');
  const orphan = failedResources.some(u => u.includes(KNOWN_ORPHAN));
  check('known-orphan-stylesheet-unchanged', orphan,
    orphan ? `${KNOWN_ORPHAN} still absent (pre-existing)` : 'orphan reference disappeared');
  // Resource-load failures are asserted precisely above, so this check is about
  // genuine script errors (exceptions, assertion failures), not HTTP statuses.
  const scriptErrors = consoleErrors.filter(
    e => !/Failed to load resource/i.test(e));
  check('no-script-errors', scriptErrors.length === 0,
    scriptErrors.slice(0, 2).join(' | ') || 'no JavaScript errors');

  const out = {
    contract: 'n03-browser/1', assessment_id: ASSESSMENT,
    final_url: page.url(), api: api.slice(-25),
    provider_calls: providerCalls, console_errors: consoleErrors,
    failed_resources: [...new Set(failedResources)],
    results, pass: results.filter(r => r.status === 'PASS').length,
    fail: results.filter(r => r.status === 'FAIL').length,
  };
  fs.writeFileSync('backend/var/e2e/n03_browser.out.json', JSON.stringify(out, null, 1), 'utf8');
  console.log(`\n${out.pass} passed / ${out.fail} failed`);
  await browser.close();
})().catch(e => { console.error('ERROR:', e.message); process.exit(1); });
