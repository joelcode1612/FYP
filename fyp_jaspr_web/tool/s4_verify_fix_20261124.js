// Verify P1/P3 on the rebuilt bundle: does Stage 4 now see the approved
// objective from Stage 3, and does it offer the generation action?
const fs = require('fs');
const { chromium } = require('playwright-core');
const BASE = 'http://127.0.0.1:8093';
const ID = 'EP-02638';
const OUT = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/backend/var/e2e/shots';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = await ctx.newPage();
  await page.setViewportSize({ width: 1440, height: 1000 });
  const api = [];
  page.on('response', (r) => {
    const u = r.url();
    if (/objective-proposals|qg-candidates|qg-eligib/.test(u)) {
      api.push(`${r.status()} ${r.request().method()} ${u.replace(BASE, '').slice(0, 120)}`);
    }
  });

  // Cache-bust so the rebuilt bundle is definitely the one under test.
  await page.goto(`${BASE}/entrepreneur/assessments?id=${ID}&stage=ai_explanation&v=${Date.now()}`, {
    waitUntil: 'domcontentloaded', timeout: 60000,
  });
  let settled = false;
  for (let i = 0; i < 25; i++) {
    await page.waitForTimeout(2000);
    settled = await page.evaluate(() =>
      Array.from(document.querySelectorAll('.p1-card')).some((c) => /Section B/i.test(c.innerText || '')),
    );
    if (settled) { console.log(`settled after ~${(i + 1) * 2}s`); break; }
  }
  if (!settled) console.log('NOT SETTLED after 50s');
  await page.waitForTimeout(2500);

  const dump = await page.evaluate(() => {
    const cards = Array.from(document.querySelectorAll('.p1-card'));
    const find = (re) => {
      const c = cards.find((x) => re.test((x.innerText || '').split('\n')[0] || ''));
      return c ? (c.innerText || '').trim() : null;
    };
    const buttons = Array.from(document.querySelectorAll('button'))
      .map((b) => (b.innerText || '').trim())
      .filter(Boolean);
    return {
      sectionB: find(/Section B/i),
      objectiveSources: find(/Research objective sources/i),
      buttons,
      hasGenerate: buttons.some((t) => /Generate questions for this objective/i.test(t)),
    };
  });

  console.log('\n--- API (objective/qg) ---');
  console.log(api.length ? api.join('\n') : '(none)');
  console.log('\nhasGenerate:', dump.hasGenerate);
  console.log('\n--- Section B ---');
  console.log(dump.sectionB ? dump.sectionB.slice(0, 1200) : '(not found)');
  console.log('\n--- Research objective sources ---');
  console.log(dump.objectiveSources ? dump.objectiveSources.slice(0, 700) : '(not found)');

  await page.evaluate(() => {
    const c = Array.from(document.querySelectorAll('.p1-card')).find((x) => /Section B/i.test(x.innerText || ''));
    if (c) c.scrollIntoView({ block: 'start' });
  });
  await page.waitForTimeout(1200);
  const file = `${OUT}/stage4_after_fix_20261124.png`;
  await page.screenshot({ path: file, clip: { x: 0, y: 0, width: 1440, height: 1000 }, timeout: 60000 });
  console.log('\nsaved:', file);
  fs.writeFileSync(`${OUT}/stage4_after_fix_20261124.json`, JSON.stringify({ dump, api }, null, 2));
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
