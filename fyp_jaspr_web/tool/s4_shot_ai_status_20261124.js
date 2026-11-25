// Capture the AI Execution Status card (the reusable progress indicator) and
// quote its text, plus the Section B card, on the final bundle.
const { chromium } = require('playwright-core');
const BASE = 'http://127.0.0.1:8093';
const ID = 'EP-02638';
const OUT = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/backend/var/e2e/shots';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = await ctx.newPage();
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.bringToFront();
  await page.goto(`${BASE}/entrepreneur/assessments?id=${ID}&stage=ai_explanation`, {
    waitUntil: 'domcontentloaded', timeout: 60000,
  });
  await page.waitForFunction(
    () => Array.from(document.querySelectorAll('button'))
      .some((b) => /Generate questions for this objective/i.test(b.innerText || '')),
    null, { timeout: 150000, polling: 1000 },
  );
  await page.waitForTimeout(2000);

  const ai = await page.evaluateHandle(() =>
    Array.from(document.querySelectorAll('.p1-card'))
      .find((c) => /AI Execution Status/i.test((c.innerText || '').split('\n')[0] || '')));
  const el = ai.asElement();
  if (!el) { console.log('AI card not found'); process.exit(2); }
  await el.screenshot({ path: `${OUT}/stage4_ai_status_20261124.png`, timeout: 60000 });
  const text = await page.evaluate((node) => (node.innerText || '').trim(), el);
  console.log('--- AI Execution Status ---');
  console.log(text);
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
