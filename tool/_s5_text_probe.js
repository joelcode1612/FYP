const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');
const TARGET = '/entrepreneur/assessments?id=MD-03209&stage=assessment_report';
(async () => {
  const b = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = b.contexts()[0];
  const page = await ctx.newPage();
  await page.bringToFront();
  await page.setViewportSize({ width: 1440, height: 1200 });
  await page.goto('http://127.0.0.1:8093/login', { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.evaluate(async () => { try { await window.sitewiseAuth.ready; } catch (_) {} });
  await page.waitForTimeout(1200);
  await page.evaluate((t) => {
    history.pushState({}, '', t);
    window.dispatchEvent(new PopStateEvent('popstate', { state: {} }));
  }, TARGET);
  await page.waitForTimeout(9000);
  const txt = await page.evaluate(() => document.body.innerText || '');
  console.log('URL:', page.url());
  console.log('LEN:', txt.length);
  console.log('---TEXT---');
  console.log(txt.slice(0, 4000));
  await page.close();
  await b.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
