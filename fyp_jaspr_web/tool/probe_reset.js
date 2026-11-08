// Functional probe for the rebuilt "Set a New Password" page and the
// callback page's error state, against the built site served on :8090.
// Checks: two-panel structure, three-step tracker, live requirements list,
// eye toggles, empty-submit errors, expired-link callback state, responsive
// stacking, console cleanliness.
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = process.env.BASE || 'http://127.0.0.1:8090';

const log = (label, v) => console.log(`  ${label}: ${v}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const b = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const ctx = await b.newContext({ viewport: { width: 1440, height: 980 } });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', (e) => errs.push('PAGEERR: ' + e.message));
  p.on('console', (m) => {
    if (m.type() === 'error' && !m.text().includes('404')) errs.push('CONSOLE: ' + m.text().slice(0, 160));
  });

  // --- 1. /reset-password structure ----------------------------------------
  await p.goto(BASE + '/reset-password/', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(900);
  log('rst-wrap', await p.locator('.rst-wrap').count());
  log('hero h1 aria-label', await p.locator('h1').getAttribute('aria-label'));
  log('steps', await p.locator('.rst-steps li').count());
  log('step states', (await p.locator('.rst-steps li').evaluateAll((els) =>
    els.map((e) => e.className.replace(/rst-step ?|is-\w+/g, (m) => m.startsWith('is') ? m : '')))).join(','));
  log('card', await p.locator('.rst-card').count());
  log('password fields', await p.locator('#rst-password, #rst-confirm').count());
  log('eye toggles', await p.locator('.rst-card .field__eye, .rst-card button.rst-eye, .rst-card .lp-eye').count());
  log('requirement items', await p.locator('.rst-reqs li').count());
  log('submit label', await p.locator('.rst-submit').innerText());
  log('back link', await p.locator('.rst-back a').getAttribute('href'));

  // --- 2. eye toggles -------------------------------------------------------
  const before = await p.locator('#rst-password').getAttribute('type');
  await p.locator('.lp-eye').first().click();
  const after = await p.locator('#rst-password').getAttribute('type');
  log('eye toggle', `${before} -> ${after}`);

  // --- 3. empty submit errors ----------------------------------------------
  await p.locator('.rst-submit').click();
  await sleep(400);
  log('field errors', (await p.locator('.lp-err:not(.is-hidden)').allInnerTexts()).join(' | '));
  log('alert', await p.locator('.lp-alert:not(.is-hidden)').first().innerText().catch(() => 'MISSING'));

  // --- 4. requirement checklist reacts to typing ---------------------------
  await p.fill('#rst-password', 'Abcdef1!');
  await sleep(300);
  log('ok items after typing', await p.locator('.rst-req.is-ok').count());

  // --- 5. expired-link callback state ---------------------------------------
  await p.goto(
    BASE + '/auth/callback?next=%2Freset-password&error_code=otp_expired' +
      '&error_description=Email%20link%20is%20invalid%20or%20has%20expired',
    { waitUntil: 'networkidle', timeout: 60000 },
  );
  await sleep(900);
  log('callback title', await p.locator('.empty__title, [class*="empty"] h2, h2').first().innerText().catch(() => 'MISSING'));
  log('callback body', await p.locator('.empty__body, [class*="empty"] p').first().innerText().catch(() => 'MISSING'));
  log('callback links', (await p.locator('.empty__links a').evaluateAll((els) =>
    els.map((e) => e.textContent.trim() + '->' + e.getAttribute('href')))).join(', '));

  // --- 6. responsive: no horizontal overflow at 800px -----------------------
  await p.setViewportSize({ width: 800, height: 900 });
  await p.goto(BASE + '/reset-password/', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(700);
  log('overflow @800', await p.evaluate(() =>
    `${document.documentElement.scrollWidth} vs ${window.innerWidth}`));
  log('stacked (shell rows)', await p.locator('.rst-shell').evaluate((e) =>
    getComputedStyle(e).gridTemplateColumns.split(' ').length));

  await p.setViewportSize({ width: 1440, height: 980 });
  await p.goto(BASE + '/reset-password/', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(900);
  await p.screenshot({ path: 'tool/_diag/reset_page.png', fullPage: false });

  console.log(errs.length ? 'ERRORS:\n' + errs.join('\n') : '  console: clean');
  await b.close();
})().catch((e) => {
  console.error('PROBE FAILED:', e.message);
  process.exit(1);
});
