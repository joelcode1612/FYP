// Focused capture: the AI Execution Status card (both progress rails) and
// Stage 5 at viewport size (the full page is too tall to rasterise reliably).
const fs = require('fs');
const path = require('path');
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');

const OUT = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/deliverables/screenshots/20261124_stage4_live';
const BASE = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638&stage=';

const settled = () => {
  const body = document.body.innerText;
  if (!body.includes('AI Execution Status')) return false;
  if (body.includes('Loading verified status')) return false;
  return /State: (BLOCKED|PROCESSING|RETURNED|VALIDATING|PERSISTED|FAILED|UNKNOWN_OUTCOME)/.test(body);
};

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = ctx.pages().find(p => p.url().includes('127.0.0.1:8093')) || await ctx.newPage();
  await page.bringToFront();
  await page.setViewportSize({ width: 1440, height: 1000 });

  await page.goto(BASE + 'ai_explanation', { waitUntil: 'domcontentloaded', timeout: 60000 });
  try { await page.waitForFunction(settled, { timeout: 180000 }); }
  catch (e) { console.log('card did not settle'); }
  await page.waitForTimeout(2000);

  const card = page.locator('.p1-ai').first();
  if (await card.count()) {
    await card.scrollIntoViewIfNeeded();
    await page.waitForTimeout(800);
    await card.screenshot({ path: path.join(OUT, 'progress_indicator_20261124.png') });
    console.log('[progress] written');
    console.log(await card.innerText());
  } else {
    console.log('no .p1-ai card');
  }

  await page.goto(BASE + 'assessment_report', { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(14000);
  await page.screenshot({ path: path.join(OUT, 'stage5_20261124.png'), fullPage: false });
  console.log('[stage5] written');
  const head = await page.evaluate(() => document.body.innerText.split('\n').filter(Boolean).slice(0, 12).join(' | '));
  console.log('  top: ' + head);

  await browser.close();
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
