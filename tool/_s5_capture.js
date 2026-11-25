const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');
const fs = require('fs');
const TARGET = '/entrepreneur/assessments?id=MD-03209&stage=assessment_report';
const DIR = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/deliverables/screenshots/20261125_preview';
fs.mkdirSync(DIR, { recursive: true });
(async () => {
  const b = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = b.contexts()[0];
  const page = await ctx.newPage();
  await page.bringToFront();
  await page.setViewportSize({ width: 1280, height: 1400 });
  await page.goto('http://127.0.0.1:8093/login', { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.evaluate(async () => { try { await window.sitewiseAuth.ready; } catch (_) {} });
  await page.waitForTimeout(1200);
  await page.evaluate((t) => { history.pushState({}, '', t); window.dispatchEvent(new PopStateEvent('popstate', { state: {} })); }, TARGET);
  await page.waitForFunction(() => /Q13/.test(document.body.innerText || ''), { timeout: 90000 });
  await page.waitForTimeout(9000);
  const txt = await page.evaluate(() => document.body.innerText || '');
  fs.writeFileSync(DIR + '/publish_questionnaire.txt', txt, 'utf8');
  console.log('TEXT_BYTES', txt.length);
  try {
    await page.screenshot({ path: DIR + '/publish_questionnaire.png', animations: 'disabled', timeout: 60000, fullPage: false });
    console.log('SHOT_TOP ok');
  } catch (e) { console.log('SHOT_TOP fail', e.message); }
  // Expand the first "chevron_right" details to show response options, then shoot.
  try {
    await page.screenshot({ path: DIR + '/publish_questionnaire_full.png', animations: 'disabled', timeout: 60000, fullPage: true });
    console.log('SHOT_FULL ok');
  } catch (e) { console.log('SHOT_FULL fail', e.message); }
  await page.close(); await b.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
