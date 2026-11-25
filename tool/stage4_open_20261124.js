// Open Stage 4 (Questionnaire Construction) at Section B and report what the
// owner will see: QG permission status, recovery availability, and the Generate
// Questions control. It never clicks Generate — the dispatch is the owner's.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');
const fs = require('fs');

const URL = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638&stage=ai_explanation';
const SHOT = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/deliverables/screenshots/20261124_stage4_ready';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  let page = ctx.pages().find(p => p.url().includes('127.0.0.1:8093'));
  if (!page) page = await ctx.newPage();
  await page.bringToFront();
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(4000);

  // The stage panel loads its data asynchronously; wait for Section B to appear.
  try {
    await page.waitForFunction(
      () => document.body.innerText.includes('Section B'), null, { timeout: 45000 });
  } catch (e) {
    console.log('Section B not found within timeout');
  }
  await page.waitForTimeout(2500);

  const info = await page.evaluate(() => {
    const text = document.body.innerText || '';
    const lines = text.split('\n').map(s => s.trim()).filter(Boolean);
    const pick = (needle, span = 4) => {
      const i = lines.findIndex(l => l.toLowerCase().includes(needle.toLowerCase()));
      return i < 0 ? null : lines.slice(i, i + span);
    };
    const buttons = Array.from(document.querySelectorAll('button, [role="button"]'))
      .map(b => ({
        text: (b.innerText || '').trim().slice(0, 90),
        disabled: b.disabled === true || b.getAttribute('aria-disabled') === 'true',
      }))
      .filter(b => b.text);
    const bIdx = lines.findIndex(l => l.includes('Section B'));
    return {
      url: location.href,
      hasSectionB: text.includes('Section B'),
      sectionBText: bIdx < 0 ? [] : lines.slice(bIdx, bIdx + 70),
      statusLines: lines.filter(l => /permission|attempt|progress|state:|reserved|dispatched|returned|validated|persisted|recovery/i.test(l)).slice(0, 40),
      permission: pick('QG processing permission', 4),
      recovery: pick('recovery', 6),
      generate: buttons.filter(b => /generate/i.test(b.text)),
      reviewControls: buttons.filter(b => /approve|reject/i.test(b.text)),
      buttons: buttons.slice(0, 40),
    };
  });

  fs.mkdirSync(SHOT.substring(0, SHOT.lastIndexOf('/')), { recursive: true });
  await page.screenshot({ path: SHOT + '.png', fullPage: false });
  console.log(JSON.stringify(info, null, 1));
  await browser.close();
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
