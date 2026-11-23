// N02 Task 3 — what the reachable normal-application pages actually show for
// the synthetic M2 assessment. Establishes exactly which Task 3 items the
// normal UI can and cannot satisfy.
const { chromium } = require('playwright');
const fs = require('fs');

const BASE = 'http://127.0.0.1:8092';
const ASSESSMENT = '4fc0abc2-ba52-4e41-aaa3-cf14fc822b37';
const MARKET = 'c4523d9e-c2ca-5bd6-b592-7cc4f0d96399';
const SHOTS = 'backend/var/e2e/shots';

(async () => {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await chromium.launch({ headless: true, channel: 'chrome' });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1400 } });
  const page = await ctx.newPage();
  const api = [];
  page.on('response', r => {
    const u = r.url();
    if (u.includes('/api/v1/m2') || u.includes('objective-proposals'))
      api.push(`${r.status()} ${u.replace(BASE, '').slice(0, 120)}`);
  });

  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle', timeout: 45000 });
  await page.fill('#lp-email', 'gatebc-e2e-b9e62014@example.invalid');
  await page.fill('#lp-password', 'e2e-local-password');
  await page.click('button.lp-submit');
  await page.waitForTimeout(5000);

  const report = {};

  // ---- A. the M2 workflow page (reachable; keys on the M2 assessment id) ----
  await page.goto(`${BASE}/entrepreneur/m2-workflow?assessment=${ASSESSMENT}`,
    { waitUntil: 'networkidle', timeout: 45000 });
  await page.waitForTimeout(6000);
  const m2Text = await page.innerText('body');
  fs.writeFileSync('backend/var/e2e/n02_m2workflow_text.txt', m2Text, 'utf8');
  await page.screenshot({ path: `${SHOTS}/n02_05_m2_workflow.png`, fullPage: true });
  report.m2_workflow = {
    url: page.url(),
    chars: m2Text.length,
    answers_visible: (m2Text.match(/M2V2-\d\d/g) || []).length,
    mentions_confirmed: /confirm/i.test(m2Text),
    mentions_bcb: /BCB|1\.2\.1/i.test(m2Text),
    mentions_19: /\b19\b/.test(m2Text),
    head: m2Text.slice(0, 1200),
  };

  // ---- B. the marketplace assessment workspace (Stage 3 mount point) -------
  await page.goto(`${BASE}/entrepreneur/assessments?assessment=${MARKET}&stage=location_evidence`,
    { waitUntil: 'networkidle', timeout: 45000 });
  await page.waitForTimeout(5000);
  const wsText = await page.innerText('body');
  fs.writeFileSync('backend/var/e2e/n02_market_workspace_text.txt', wsText, 'utf8');
  await page.screenshot({ path: `${SHOTS}/n02_06_market_workspace.png`, fullPage: true });
  report.market_workspace = {
    url: page.url(),
    chars: wsText.length,
    stage3_available: !/unavailable/i.test(wsText),
    mentions_objectives: /Research objectives/i.test(wsText),
    head: wsText.slice(0, 1200),
  };

  report.api = api.slice(-30);
  fs.writeFileSync('backend/var/e2e/n02_browser_surface.json',
    JSON.stringify(report, null, 1), 'utf8');

  console.log('=== M2 workflow page ===');
  console.log(' url            :', report.m2_workflow.url);
  console.log(' M2V2 refs      :', report.m2_workflow.answers_visible);
  console.log(' confirm shown  :', report.m2_workflow.mentions_confirmed);
  console.log(' BCB shown      :', report.m2_workflow.mentions_bcb);
  console.log('\n=== marketplace workspace ===');
  console.log(' url            :', report.market_workspace.url);
  console.log(' stage3 avail   :', report.market_workspace.stage3_available);
  console.log(' objectives     :', report.market_workspace.mentions_objectives);
  console.log('\n=== m2/objective api calls ===');
  console.log(report.api.join('\n') || ' (none)');

  await browser.close();
})().catch(e => { console.error('ERROR:', e.message); process.exit(1); });
