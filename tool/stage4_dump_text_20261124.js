// Dump the rendered Stage 4 text so the QG permission, recovery offer and review
// controls can be located precisely. Read-only: no clicks, no dispatch.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');
const fs = require('fs');

const URL = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638&stage=ai_explanation';
const OUT = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/backend/var/e2e/pg18/stage4_page_text_20261124.txt';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  let page = ctx.pages().find(p => p.url().includes('127.0.0.1:8093'));
  if (!page) page = await ctx.newPage();
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(5000);
  try {
    await page.waitForFunction(() => document.body.innerText.includes('Section B'),
      null, { timeout: 45000 });
  } catch (e) {}
  await page.waitForTimeout(2500);
  const text = await page.evaluate(() => document.body.innerText || '');
  fs.writeFileSync(OUT, text, 'utf8');
  console.log('chars:', text.length, '->', OUT);
  await browser.close();
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
