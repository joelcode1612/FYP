// Ask the live page to fetch the research-workspace read and summarise the rows
// Stage 4 actually receives as `objectives`.
const { chromium } = require('playwright-core');
const BASE = 'http://127.0.0.1:8093';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = await ctx.newPage();
  await page.goto(`${BASE}/entrepreneur/assessments?id=EP-02638&stage=ai_explanation`, {
    waitUntil: 'domcontentloaded', timeout: 60000,
  });
  await page.waitForTimeout(3000);
  const out = await page.evaluate(async () => {
    const url = '/api/v1/m2/confirmations/d5a72e84-c653-4b16-b225-3de857009b45/research-workspace?expected_revision=24';
    const r = await fetch(url, { credentials: 'include' });
    const j = await r.json();
    const rows = Array.isArray(j.rows) ? j.rows : (j.workspace?.rows ?? []);
    return {
      status: r.status,
      topKeys: Object.keys(j),
      rowCount: rows.length,
      rows: rows.map((x) => ({
        id: String(x.id).slice(0, 12),
        approval_status: x.approval_status,
        exact_text: String(x.exact_text || '').slice(0, 70),
      })),
    };
  });
  console.log(JSON.stringify(out, null, 2));
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
