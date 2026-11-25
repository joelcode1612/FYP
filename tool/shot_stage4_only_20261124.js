// Stage 4 capture on its own, with the settle time the QG panel needs.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');
const fs = require('fs');
const URL = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638&stage=ai_explanation';
const DIR = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/deliverables/screenshots/20261124_stage34';
fs.mkdirSync(DIR, { recursive: true });

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  let page = ctx.pages().find(p => p.url().includes('127.0.0.1:8093'));
  if (!page) page = await ctx.newPage();
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto('http://127.0.0.1:8093/', { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(4000);
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(8000);
  try {
    await page.waitForFunction(() => document.body.innerText.includes('Section B'),
      null, { timeout: 40000 });
  } catch (e) { console.log('Section B not found'); }
  await page.waitForTimeout(4000);

  // Bring the AI Execution Status card into view so the progress rails are in
  // the frame, not below the fold.
  await page.evaluate(() => {
    const el = Array.from(document.querySelectorAll('*'))
      .find(n => n.children.length === 0 && /AI Execution Status/i.test(n.textContent || ''));
    if (el) el.scrollIntoView({ block: 'center' });
  });
  await page.waitForTimeout(1500);

  const text = await page.evaluate(() => document.body.innerText || '');
  console.log(JSON.stringify({
    url: page.url(),
    rails: (text.match(/✓ Reserved/g) || []).length,
    states: (text.match(/State:\s*[A-Z_]+/g) || []).slice(0, 4),
    hasGenerate: /Generate questions for this objective/.test(text),
    hasSectionB: text.includes('Section B'),
  }, null, 1));
  await page.screenshot({ path: `${DIR}/stage4_qg.png`, fullPage: false });
  await browser.close();
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
