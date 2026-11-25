const { chromium } = require('playwright-core');

const URL_WS = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02087';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  for (const p of ctx.pages()) {
    if ((p.url() || '').includes('127.0.0.1:8093')) { try { await p.close(); } catch (e) {} }
  }
  const page = await ctx.newPage();

  let counting = false;
  const calls = [];
  page.on('request', (r) => {
    if (counting && r.url().includes('/api/v1/')) calls.push(r.url().replace('http://127.0.0.1:8093', ''));
  });

  await page.goto(URL_WS, { waitUntil: 'domcontentloaded', timeout: 45000 });
  const btn = page.getByRole('button', { name: /View Stage 4: Question review/i });
  await btn.first().waitFor({ state: 'visible', timeout: 45000 });
  await btn.first().click();
  await page.waitForFunction(
    () => Array.from(document.querySelectorAll('.p1-card')).some((c) => /Section A · Fixed core/.test(c.innerText)),
    null, { timeout: 45000 },
  );
  await page.waitForTimeout(6000); // let the initial burst settle

  // Now watch an idle window: any request here is a loop, not initial load.
  counting = true;
  const mutations = await page.evaluate(() => new Promise((resolve) => {
    let n = 0;
    const obs = new MutationObserver((recs) => { n += recs.length; });
    obs.observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true });
    setTimeout(() => { obs.disconnect(); resolve(n); }, 10000);
  }));
  counting = false;

  console.log('IDLE-WINDOW API REQUESTS (' + calls.length + '):');
  const tally = {};
  for (const c of calls) tally[c] = (tally[c] || 0) + 1;
  for (const [k, v] of Object.entries(tally)) console.log('  ' + v + 'x ' + k);
  console.log('DOM MUTATIONS IN 10s IDLE:', mutations);
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
