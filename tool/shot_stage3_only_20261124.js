// Stage 3 capture that waits for the persisted objectives to render.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');
const fs = require('fs');
const URL = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638&stage=location_evidence';
const DIR = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/deliverables/screenshots/20261124_stage34';
fs.mkdirSync(DIR, { recursive: true });

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  let page = ctx.pages().find(p => p.url().includes('127.0.0.1:8093'));
  if (!page) page = await ctx.newPage();
  await page.setViewportSize({ width: 1440, height: 1100 });
  await page.goto('http://127.0.0.1:8093/', { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(4000);
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(6000);

  // The panel prints a loading placeholder first; wait for it to be replaced by
  // the real rows rather than photographing the spinner.
  try {
    await page.waitForFunction(
      () => !/Reading persisted research objectives/i.test(document.body.innerText || ''),
      null, { timeout: 45000 });
  } catch (e) { console.log('still loading after 45s'); }
  await page.waitForTimeout(3000);

  const text = await page.evaluate(() => document.body.innerText || '');
  console.log(JSON.stringify({
    url: page.url(),
    stillLoading: /Reading persisted research objectives/i.test(text),
    objectiveRows: (text.match(/proposal:[0-9a-f-]{36}/g) || []).length,
    approvedLine: (text.match(/Objectives approved[^\n]*/i) || [])[0] || null,
    rails: (text.match(/✓ Reserved/g) || []).length,
    states: (text.match(/State:\s*[A-Z_]+/g) || []).slice(0, 4),
  }, null, 1));
  await page.screenshot({ path: `${DIR}/stage3_bdj.png`, fullPage: false });
  await browser.close();
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
