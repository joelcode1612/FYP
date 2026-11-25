// Wait for Stage 4 to actually finish loading, log every API response, and dump
// Section B + the preview-questionnaire payload.
const fs = require('fs');
const { chromium } = require('playwright-core');
const BASE = 'http://127.0.0.1:8093';
const ID = 'EP-02638';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = await ctx.newPage();
  await page.setViewportSize({ width: 1440, height: 1000 });

  const log = [];
  const bodies = {};
  page.on('response', async (r) => {
    const u = r.url();
    if (!/\/api\/v1\//.test(u)) return;
    const path = u.replace(BASE, '');
    log.push(`${r.status()} ${r.request().method()} ${path}`);
    if (/preview-questionnaire|objective-proposals|qg-eligib|qg-candidates/.test(path)) {
      try { bodies[path] = { status: r.status(), body: (await r.text()).slice(0, 4000) }; }
      catch (e) { bodies[path] = { status: r.status(), body: '<unreadable>' }; }
    }
  });

  await page.goto(`${BASE}/entrepreneur/assessments?id=${ID}&stage=ai_explanation`, {
    waitUntil: 'domcontentloaded', timeout: 60000,
  });
  // Wait until the panel leaves its loading state (Section A is the first real card).
  let settled = false;
  for (let i = 0; i < 20; i++) {
    await page.waitForTimeout(2000);
    settled = await page.evaluate(() =>
      Array.from(document.querySelectorAll('.p1-card')).some((c) => /Section A|Section B/i.test(c.innerText || '')),
    );
    if (settled) { console.log(`settled after ~${(i + 1) * 2}s`); break; }
  }
  if (!settled) console.log('NOT SETTLED after 40s');
  await page.waitForTimeout(3000);

  const dump = await page.evaluate(() => {
    const cards = Array.from(document.querySelectorAll('.p1-card'));
    const find = (re) => {
      const c = cards.find((x) => re.test((x.innerText || '').split('\n')[0] || ''));
      return c ? (c.innerText || '').trim() : null;
    };
    return {
      allCardTitles: cards.map((c) => (c.innerText || '').split('\n')[0]),
      sectionA: find(/Section A/i),
      sectionB: find(/Section B/i),
      objectiveSources: find(/Research objective sources/i),
      reviewSummary: find(/Review summary/i),
      requiredChecks: find(/Required checks/i),
    };
  });

  console.log('\n--- API LOG ---');
  console.log(log.join('\n'));
  console.log('\n--- CARD TITLES ---');
  console.log(JSON.stringify(dump.allCardTitles));
  for (const k of ['sectionB', 'objectiveSources', 'reviewSummary', 'requiredChecks']) {
    console.log(`\n--- ${k} ---`);
    console.log(dump[k] ? dump[k].slice(0, 1800) : '(card not found)');
  }
  fs.writeFileSync(
    'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/backend/var/e2e/shots/stage4_sectionB_20261124.json',
    JSON.stringify({ dump, log, bodies }, null, 2),
  );
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
