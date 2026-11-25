// Capture Stage 3 (BDJ) and Stage 4 (QG) as the owner sees them. Read-only.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');
const fs = require('fs');

const BASE = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638';
const DIR = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/deliverables/screenshots/20261124_stage34';
fs.mkdirSync(DIR, { recursive: true });

const STAGES = [
  ['stage3_bdj', 'location_evidence'],
  ['stage4_qg', 'ai_explanation'],
];

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  let page = ctx.pages().find(p => p.url().includes('127.0.0.1:8093'));
  if (!page) page = await ctx.newPage();
  await page.setViewportSize({ width: 1440, height: 1000 });

  const report = {};
  // Warm up: land once and let the SPA restore its session from localStorage.
  // Navigating straight to a deep link races the auth guard and bounces to
  // /login even though the token is valid.
  await page.goto(`${BASE}&stage=ai_explanation`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(7000);

  for (const [name, stage] of STAGES) {
    await page.goto(`${BASE}&stage=${stage}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(9000);
    if (page.url().includes('/login')) {
      // One retry after the session has had time to restore.
      await page.goto('http://127.0.0.1:8093/', { waitUntil: 'domcontentloaded' });
      await page.waitForTimeout(4000);
      await page.goto(`${BASE}&stage=${stage}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
      await page.waitForTimeout(9000);
    }
    const text = await page.evaluate(() => document.body.innerText || '');
    report[name] = {
      url: page.url(),
      hasState: /State:\s*\w+/.test(text),
      states: (text.match(/State:\s*[A-Z_]+/g) || []).slice(0, 4),
      objectives: (text.match(/proposal:[0-9a-f-]{36}/g) || []).slice(0, 4),
      progressRails: (text.match(/✓ Reserved/g) || []).length,
    };
    await page.screenshot({ path: `${DIR}/${name}.png`, fullPage: false });
  }
  console.log(JSON.stringify(report, null, 1));
  await browser.close();
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
