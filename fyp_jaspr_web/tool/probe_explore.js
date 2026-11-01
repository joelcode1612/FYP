// Functional probe for the entrepreneur Explore page (/entrepreneur/explore).
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = 'http://127.0.0.1:8141';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (l, v) => console.log(`  ${l}: ${v}`);

(async () => {
  const b = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const ctx = await b.newContext({ viewport: { width: 1440, height: 980 } });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', (e) => errs.push('PAGEERR: ' + e.message));
  p.on('console', (m) => {
    if (m.type() === 'error' && !m.text().includes('404')) errs.push('CONSOLE: ' + m.text().slice(0, 140));
  });

  const resp = await p.goto(BASE + '/entrepreneur/explore/', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(1200);
  log('http status', resp.status());
  log('page heading', (await p.locator('h1').first().innerText().catch(() => 'MISSING')).replace(/\s+/g, ' ').slice(0, 60));

  // Filter panel + results
  log('filter panel present', await p.locator('.filters, .filter-panel, form').count());
  log('count line', (await p.locator('p.small').first().innerText().catch(() => 'MISSING')).slice(0, 70));
  log('property cards', await p.locator('.pgrid .prop-card, .pgrid > *').count());
  log('map pins', await p.locator('.map-pin').count());
  log('legend items', await p.locator('.map-legend .lg').count());
  log('analysis cards (initial)', await p.locator('.analysis .a-card').count());
  log('initial analysis hint', (await p.locator('.analysis .a-card h3').first().innerText().catch(() => 'MISSING')).slice(0, 40));

  // Filter interaction: keyword search narrows results
  const before = await p.locator('.pgrid > *').count();
  const input = p.locator('input[type="search"], input[placeholder*="earch"], input[type="text"]').first();
  if (await input.count()) {
    await input.fill('cafe');
    await sleep(700);
    const after = await p.locator('.pgrid > *').count();
    log(`keyword "cafe": cards ${before} -> ${after}`, after <= before ? 'ok' : 'UNEXPECTED');
    await input.fill('');
    await sleep(500);
  } else {
    log('keyword input', 'NOT FOUND');
  }

  // Pin selection -> analysis loads
  const pins = p.locator('.map-pin');
  if (await pins.count()) {
    await pins.first().dispatchEvent('click');
    await sleep(1200);
    log('analysis cards after pin click', await p.locator('.analysis .a-card').count());
    log('selected property card', (await p.locator('.analysis .a-card h3').first().innerText().catch(() => 'MISSING')).slice(0, 50));
    log('active pin highlighted', await p.locator('.map-pin--active').count());
    log('suitability stat present', await p.locator('.stat strong').count());
  } else {
    log('pin click', 'NO PINS');
  }

  // Zoom
  const zoomLabelBefore = await p.locator('.explore__map-zoom').count();
  await p.locator('.explore__zoom-btn').first().dispatchEvent('click');
  await sleep(500);
  log('zoom label after zoom-in', await p.locator('.explore__map-zoom').innerText().catch(() => 'none'));
  await p.locator('.explore__zoom-btn').last().dispatchEvent('click');
  await sleep(300);
  log('zoom label after zoom-out', await p.locator('.explore__map-zoom').count() ? await p.locator('.explore__map-zoom').innerText() : 'none');

  // Layer toggle
  const layer = p.locator('.layer-toggle').nth(1);
  await layer.dispatchEvent('click');
  await sleep(300);
  log('layer toggle clickable', 'ok');

  // Overflow + screenshots
  for (const vp of [{ width: 1440, height: 980 }, { width: 390, height: 844 }]) {
    await p.setViewportSize(vp);
    await p.goto(BASE + '/entrepreneur/explore/', { waitUntil: 'networkidle' });
    await sleep(900);
    const of = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    log(`overflow @${vp.width}px`, of);
    await p.screenshot({ path: `tool/_diag/explore_${vp.width}.png`, fullPage: false });
  }

  log('errors', errs.length ? errs.join(' | ') : 'none');
  await b.close();
})();
