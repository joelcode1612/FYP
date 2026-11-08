// Functional probe for the entrepreneur Explore page (/entrepreneur/explore).
// Uses the headless session harness (session_harness.js) so the API responses
// come from the git-ignored fixture, not a Supabase session.
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = 'http://127.0.0.1:8141';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (l, v) => console.log(`  ${l}: ${v}`);

(async () => {
  const b = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const ctx = await b.newContext({ viewport: { width: 1440, height: 980 } });
  const p = await ctx.newPage();
  await installHarnessSession(p, { role: 'entrepreneur' });
  const errs = [];
  const t0 = Date.now();
  p.on('pageerror', (e) =>
    errs.push(`PAGEERR@${((Date.now() - t0) / 1000).toFixed(1)}s ` +
      `msg=${(e.message || '').slice(0, 120)} stack=${(e.stack || '').slice(0, 600)}`));
  p.on('console', (m) => {
    if (m.type() === 'error' && !m.text().includes('404')) errs.push('CONSOLE: ' + m.text().slice(0, 140));
  });

  const resp = await p.goto(BASE + '/entrepreneur/explore/', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(1500);
  log('http status', resp.status());
  log('page heading', (await p.locator('h1').first().innerText().catch(() => 'MISSING')).replace(/\s+/g, ' ').slice(0, 60));

  // Filter panel + results
  log('filter panel present', await p.locator('.filters').count());
  log('count line', (await p.locator('.explore__results-head p').first().innerText().catch(() => 'MISSING')).slice(0, 70));
  log('sort options', await p.locator('.explore__sort select option').count());
  log('property cards', await p.locator('.pgrid .pcard').count());
  log('map pins', await p.locator('.map-pin').count());
  log('map clusters', await p.locator('.map-cluster').count());
  log('legend items', await p.locator('.map-legend .lg').count());
  log('analysis cards (initial)', await p.locator('.analysis .a-card').count());

  // Keyword search narrows results (debounced 250ms)
  const before = await p.locator('.pgrid .pcard').count();
  const input = p.locator('input[type="search"]').first();
  if (await input.count()) {
    await input.fill('cafe');
    await sleep(900);
    const after = await p.locator('.pgrid .pcard').count();
    log(`keyword "cafe": cards ${before} -> ${after}`, after <= before ? 'ok' : 'UNEXPECTED');
    await input.fill('');
    await sleep(900);
  } else {
    log('keyword input', 'NOT FOUND');
  }

  // Sorting changes the first card
  const firstBefore = await p.locator('.pgrid .pcard h3').first().innerText().catch(() => '');
  await p.locator('.explore__sort select').selectOption({ label: 'Rent: low to high' });
  await sleep(700);
  const firstAfter = await p.locator('.pgrid .pcard h3').first().innerText().catch(() => '');
  log('sort applied', firstBefore !== firstAfter ? 'ok' : 'UNCHANGED');

  // Cluster -> zoom in; show-all resets
  await p.locator('.map-cluster').first().dispatchEvent('click');
  await sleep(600);
  log('zoom label after cluster click', await p.locator('.explore__map-zoom').innerText().catch(() => 'none'));
  await p.locator('.explore__zoom-btn').last().dispatchEvent('click');
  await sleep(500);
  log('zoom label after show-all', (await p.locator('.explore__map-zoom').count()) ? 'STILL SHOWN' : 'reset');

  // Pin selection -> popup + grid highlight (map/list sync)
  const pins = p.locator('.map-pin');
  if (await pins.count()) {
    await pins.first().dispatchEvent('click');
    await sleep(1200);
    log('selected popup title', (await p.locator('.analysis .a-card h3').first().innerText().catch(() => 'MISSING')).slice(0, 50));
    log('popup id/type line', (await p.locator('.analysis .a-card p.meta').first().innerText().catch(() => 'MISSING')).slice(0, 50));
    log('active pin highlighted', await p.locator('.map-pin--active').count());
    log('grid card highlighted', await p.locator('.pcard--selected').count());
    log('analysis cards after pin click', await p.locator('.analysis .a-card').count());
  } else {
    log('pin click', 'NO PINS (all clustered at zoom 1)');
  }

  // Locate button on a card pans + scrolls to the map
  const locate = p.locator('.pcard button', { hasText: 'Locate' }).first();
  if (await locate.count()) {
    await locate.dispatchEvent('click');
    await sleep(1200);
    log('locate: active pin', await p.locator('.map-pin--active').count());
    log('locate: active cluster', await p.locator('.map-cluster--active').count());
    log('locate: selected card', (await p.locator('.analysis .a-card h3').first().innerText().catch(() => 'MISSING')).slice(0, 40));
    log('locate: analysis h3s', (await p.locator('.analysis .a-card h3').allInnerTexts()).join(' | ').slice(0, 90));
  }

  // Overflow + screenshots
  for (const vp of [{ width: 1440, height: 980 }, { width: 390, height: 844 }]) {
    await p.setViewportSize(vp);
    await p.goto(BASE + '/entrepreneur/explore/', { waitUntil: 'networkidle' });
    await sleep(1200);
    const of = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    log(`overflow @${vp.width}px`, of);
    await p.screenshot({ path: `tool/_diag/explore_${vp.width}.png`, fullPage: false });
  }

  log('errors', errs.length ? errs.join(' | ') : 'none');
  await b.close();
})();
