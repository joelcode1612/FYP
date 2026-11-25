// Final Stage 3 + Stage 4 capture. Searches every browser context, because a
// freshly launched Chrome does not always put the page in contexts()[0].
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');
const fs = require('fs');

const BASE = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638';
const DIR = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/deliverables/screenshots/20261124_stage34';
fs.mkdirSync(DIR, { recursive: true });

function findPage(browser) {
  for (const ctx of browser.contexts()) {
    for (const p of ctx.pages()) {
      if (p.url().includes('127.0.0.1:8093')) return p;
    }
  }
  for (const ctx of browser.contexts()) {
    const pages = ctx.pages();
    if (pages.length) return pages[0];
  }
  return null;
}

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  let page = findPage(browser);
  if (!page) {
    const ctx = browser.contexts()[0] || await browser.newContext();
    page = await ctx.newPage();
  }
  await page.bringToFront();
  await page.setViewportSize({ width: 1440, height: 1100 });

  await page.goto('http://127.0.0.1:8093/', { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(5000);

  const out = {};

  // ---- Stage 3 -------------------------------------------------------------
  await page.goto(`${BASE}&stage=location_evidence`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(7000);
  try {
    await page.waitForFunction(
      () => !/Reading persisted research objectives/i.test(document.body.innerText || ''),
      null, { timeout: 45000 });
  } catch (e) { out.stage3_timeout = true; }
  await page.waitForTimeout(3000);
  let t = await page.evaluate(() => document.body.innerText || '');
  out.stage3 = {
    url: page.url(),
    stillLoading: /Reading persisted research objectives/i.test(t),
    objectiveRefs: (t.match(/proposal:[0-9a-f-]{36}/g) || []).length,
    approvedLine: (t.match(/Objectives approved[^\n]*/i) || [])[0] || null,
    rails: (t.match(/✓ Reserved/g) || []).length,
    states: (t.match(/State:\s*[A-Z_]+/g) || []).slice(0, 4),
    hasLive: /\bLIVE\b/.test(t),
  };
  await page.screenshot({ path: `${DIR}/stage3_bdj.png`, fullPage: false });

  // ---- Stage 4 -------------------------------------------------------------
  await page.goto(`${BASE}&stage=ai_explanation`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(8000);
  try {
    await page.waitForFunction(() => document.body.innerText.includes('Section B'),
      null, { timeout: 40000 });
  } catch (e) { out.stage4_timeout = true; }
  await page.waitForTimeout(3000);
  await page.evaluate(() => {
    const el = Array.from(document.querySelectorAll('*'))
      .find(n => n.children.length === 0 && /AI Execution Status/i.test(n.textContent || ''));
    if (el) el.scrollIntoView({ block: 'center' });
  });
  await page.waitForTimeout(1500);
  t = await page.evaluate(() => document.body.innerText || '');
  out.stage4 = {
    url: page.url(),
    rails: (t.match(/✓ Reserved/g) || []).length,
    states: (t.match(/State:\s*[A-Z_]+/g) || []).slice(0, 4),
    hasGenerate: /Generate questions for this objective/.test(t),
    hasSectionB: t.includes('Section B'),
    hasSectionA: t.includes('Section A'),
  };
  await page.screenshot({ path: `${DIR}/stage4_qg.png`, fullPage: false });

  console.log(JSON.stringify(out, null, 1));
  await browser.close();
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
