// Regression probe for the /entrepreneur/assets/sitewise-mark-64.png 404.
// Verifies the brand <img> renders with a ROOT-absolute src (/assets/...) and
// that no request to a route-relative /entrepreneur/assets/... is ever made.
const { chromium } = require('playwright-core');

const BASE = process.env.BASE || 'http://127.0.0.1:8095';

(async () => {
  const browser = await chromium.launch({
    args: ['--no-proxy-server', '--no-sandbox'],
  });
  const page = await browser.newPage();

  const bad = [];
  const logoReqs = [];
  page.on('response', (r) => {
    const u = r.url();
    if (u.includes('sitewise-mark-64.png')) {
      logoReqs.push({ url: u, status: r.status() });
    }
    if (r.status() === 404) bad.push(u);
  });

  let fail = 0;
  const ok = (name, cond, extra) =>
    console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`) ||
    (cond ? null : fail++);

  // Landing page carries the topbar brand mark.
  await page.goto(BASE + '/', { waitUntil: 'networkidle', timeout: 30000 }).catch(() => {});
  await page.waitForSelector('img[src$="sitewise-mark-64.png"]', { timeout: 15000 }).catch(() => {});
  const srcs = await page.$$eval('img[src$="sitewise-mark-64.png"]', (els) =>
    els.map((e) => e.getAttribute('src'))
  );
  ok('brand img rendered', srcs.length > 0, 'count=' + srcs.length);
  ok('brand src is root-absolute', srcs.every((s) => s.startsWith('/assets/')), JSON.stringify(srcs));

  // Sub-route: previously produced the 404.
  await page.goto(BASE + '/entrepreneur/', { waitUntil: 'networkidle', timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(1500);
  const srcs2 = await page.$$eval('img[src$="sitewise-mark-64.png"]', (els) =>
    els.map((e) => e.getAttribute('src'))
  ).catch(() => []);
  ok('sub-route brand src root-absolute', srcs2.every((s) => s.startsWith('/assets/')), JSON.stringify(srcs2));

  ok('no 404 for sitewise-mark-64.png', !bad.some((u) => u.includes('sitewise-mark-64.png')),
    'bad=' + JSON.stringify(logoReqs));
  ok('no /entrepreneur/assets/ request', !logoReqs.some((r) => r.url.includes('/entrepreneur/assets/')),
    'reqs=' + JSON.stringify(logoReqs));

  await browser.close();
  console.log(fail === 0 ? 'ALL PASS' : `FAILURES=${fail}`);
  process.exit(fail === 0 ? 0 : 1);
})();
