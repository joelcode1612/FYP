const { chromium } = require('playwright-core');

const URL_WS = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02087';
const OUT = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/backend/var/e2e/stage4_sectionA_browser_20261124.png';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  for (const p of ctx.pages()) {
    if ((p.url() || '').includes('127.0.0.1:8093')) { try { await p.close(); } catch (e) {} }
  }
  const page = await ctx.newPage();
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto(URL_WS, { waitUntil: 'domcontentloaded', timeout: 45000 });
  const btn = page.getByRole('button', { name: /View Stage 4: Question review/i });
  await btn.first().waitFor({ state: 'visible', timeout: 45000 });
  await btn.first().click();
  await page.waitForFunction(
    () => Array.from(document.querySelectorAll('.p1-card')).some((c) => /Section A · Fixed core/.test(c.innerText)),
    null, { timeout: 45000 },
  );
  await page.waitForTimeout(3000);

  // Scroll the Section A card to the top of the viewport, then capture a fixed
  // region. A clip skips Playwright's element-stability wait.
  await page.evaluate(() => {
    const card = Array.from(document.querySelectorAll('.p1-card'))
      .find((c) => /Section A · Fixed core/.test(c.innerText));
    if (card) card.scrollIntoView({ block: 'start' });
  });
  await page.waitForTimeout(1200);
  await page.screenshot({ path: OUT, clip: { x: 0, y: 0, width: 1440, height: 900 }, timeout: 60000 });
  console.log('saved:', OUT);
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
