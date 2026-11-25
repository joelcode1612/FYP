// Capture the Section B card itself (element screenshot) plus the legacy
// eligibility diagnostic, so the two verdicts can be compared side by side.
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
    null, { timeout: 120000, polling: 1000 },
  );
  await page.waitForTimeout(1500);

  const handle = await page.evaluateHandle(() =>
    Array.from(document.querySelectorAll('.p1-card'))
      .find((c) => /Section B/i.test((c.innerText || '').split('\n')[0] || '')));
  const el = handle.asElement();
  if (!el) { console.log('Section B card not found'); process.exit(2); }
  await el.screenshot({ path: `${OUT}/stage4_sectionB_after_fix_20261124.png`, timeout: 60000 });
  console.log('saved Section B element screenshot');

  const legacy = await page.evaluate(() => {
    const c = Array.from(document.querySelectorAll('.p1-card'))
      .find((x) => /Generated question candidates/i.test((x.innerText || '').split('\n')[0] || ''));
    return c ? (c.innerText || '').slice(0, 900) : null;
  });
  console.log('\n--- legacy diagnostic ---\n', legacy);
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
