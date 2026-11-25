// Screenshot the exact controls the owner will use: the AI execution rails and
// the Generate Questions action in Section B.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');
const fs = require('fs');

const URL = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638&stage=ai_explanation';
const DIR = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/deliverables/screenshots/20261124_stage34';
fs.mkdirSync(DIR, { recursive: true });

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  let page = null;
  for (const ctx of browser.contexts()) for (const p of ctx.pages()) if (p.url().includes('127.0.0.1:8093')) page = p;
  if (!page) { const ctx = browser.contexts()[0] || await browser.newContext(); page = await ctx.newPage(); }
  await page.bringToFront();
  await page.setViewportSize({ width: 1440, height: 1000 });

  await page.goto('http://127.0.0.1:8093/', { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(4000);
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
  try {
    await page.waitForFunction(() => /Generate questions for this objective/i.test(document.body.innerText || ''),
      null, { timeout: 60000, polling: 500 });
  } catch (_) {}
  await page.waitForTimeout(2500);

  const info = await page.evaluate(() => {
    const btn = [...document.querySelectorAll('button')]
      .find(b => /Generate questions for this objective/i.test(b.textContent || ''));
    if (btn) btn.scrollIntoView({ block: 'center' });
    return { found: !!btn, disabled: btn ? btn.disabled : null, text: btn ? btn.textContent.trim() : null };
  });
  await page.waitForTimeout(1500);
  await page.screenshot({ path: `${DIR}/stage4_generate_action_2342.png` });

  // And a second frame showing the rails above it.
  await page.evaluate(() => {
    const el = [...document.querySelectorAll('*')].find(n => n.children.length === 0 && /AI Execution Status/i.test(n.textContent || ''));
    if (el) el.scrollIntoView({ block: 'start' });
  });
  await page.waitForTimeout(1200);
  await page.screenshot({ path: `${DIR}/stage4_rails_2342.png` });

  console.log(JSON.stringify(info, null, 1));
  await browser.close();
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
