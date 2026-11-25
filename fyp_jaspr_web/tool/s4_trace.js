const { chromium } = require('playwright-core');

const URL_WS = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02087';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = await ctx.newPage();

  const apiCalls = [];
  page.on('response', async (r) => {
    const u = r.url();
    if (u.includes('/api/v1/')) apiCalls.push({ status: r.status(), url: u.replace('http://127.0.0.1:8093', '') });
  });

  await page.goto(URL_WS, { waitUntil: 'domcontentloaded', timeout: 40000 });
  await page.waitForTimeout(8000);
  await page.getByRole('button', { name: /View Stage 4: Question review/i }).click();
  await page.waitForTimeout(10000);

  console.log('URL AFTER CLICK:', page.url());
  console.log('--- BODY ---');
  console.log((await page.evaluate(() => document.body.innerText)).slice(0, 1800));
  console.log('--- API CALLS ---');
  console.log(JSON.stringify(apiCalls, null, 1));
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
