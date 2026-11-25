const { chromium } = require('playwright-core');

const URL_WS = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02087';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = await ctx.newPage();

  const api = [];
  const errors = [];
  page.on('response', async (r) => {
    const u = r.url();
    if (u.includes('/api/v1/')) {
      api.push({ status: r.status(), method: r.request().method(), url: u.replace('http://127.0.0.1:8093', '') });
    }
  });
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text().slice(0, 300)); });
  page.on('pageerror', (e) => errors.push('PAGEERROR: ' + String(e).slice(0, 300)));

  await page.goto(URL_WS, { waitUntil: 'domcontentloaded', timeout: 40000 });
  await page.waitForTimeout(8000);
  await page.getByRole('button', { name: /View Stage 4: Question review/i }).click();
  await page.waitForTimeout(15000);

  console.log('--- ALL API CALLS (' + api.length + ') ---');
  for (const c of api) console.log(`${c.status} ${c.method} ${c.url}`);
  console.log('--- CONSOLE ERRORS (' + errors.length + ') ---');
  for (const e of errors) console.log(e);
  const stuck = await page.evaluate(() => document.body.innerText.includes('Loading verified research records'));
  console.log('--- STUCK ON LOADING:', stuck);
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
