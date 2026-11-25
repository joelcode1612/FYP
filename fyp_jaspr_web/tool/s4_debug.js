const { chromium } = require('playwright-core');

const URL_WS = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02087';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  console.log('pages before:', ctx.pages().length);
  const page = await ctx.newPage();
  const errs = [];
  page.on('pageerror', (e) => errs.push(String(e).slice(0, 200)));

  await page.goto(URL_WS, { waitUntil: 'domcontentloaded', timeout: 40000 });
  await page.waitForTimeout(10000);
  console.log('URL   :', page.url());
  console.log('TITLE :', await page.title());
  const b = await page.evaluate(() => ({
    len: document.body.innerText.length,
    head: document.body.innerText.slice(0, 400).replace(/\s+/g, ' '),
    hasBtn: !!Array.from(document.querySelectorAll('button')).find((x) => /View Stage 4/.test(x.innerText)),
  }));
  console.log('BODY  :', JSON.stringify(b, null, 1));
  console.log('ERRORS:', errs);
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
