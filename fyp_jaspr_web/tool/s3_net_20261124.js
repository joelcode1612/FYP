// Log the network responses Stage 3 issues, and whether the objective panel
// ever leaves its loading state. Read-only.
const { chromium } = require('playwright-core');
const BASE = 'http://127.0.0.1:8093';
const ID = 'EP-02638';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = await ctx.newPage();
  await page.setViewportSize({ width: 1440, height: 900 });
  const seen = [];
  page.on('response', async (r) => {
    const u = r.url();
    if (!u.includes('/api/') && !u.includes('/auth/')) return;
    seen.push(`${r.status()} ${r.request().method()} ${u.replace(BASE, '')}`);
  });
  await page.goto(`${BASE}/entrepreneur/assessments?id=${ID}&stage=location_evidence`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  for (const ms of [2000, 5000, 10000, 15000]) {
    await page.waitForTimeout(ms === 2000 ? 2000 : ms - 0);
    const txt = await page.evaluate(() => {
      const hit = Array.from(document.querySelectorAll('*')).find((e) => /Reading persisted research objectives|No research objectives|objective/i.test((e.innerText || '').trim()) && (e.innerText || '').length < 400);
      return hit ? (hit.innerText || '').replace(/\s+/g, ' ').slice(0, 220) : null;
    });
    console.log(`t+${ms}ms objectivePanel:`, txt);
  }
  console.log('\n--- api responses ---');
  console.log(seen.join('\n'));
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
