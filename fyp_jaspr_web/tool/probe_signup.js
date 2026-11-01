// Functional probe for the rebuilt split-layout signup page.
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = 'http://127.0.0.1:8141';

const log = (label, v) => console.log(`  ${label}: ${v}`);

(async () => {
  const b = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const ctx = await b.newContext({ viewport: { width: 1440, height: 980 } });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', e => errs.push('PAGEERR: ' + e.message));
  p.on('console', m => { if (m.type() === 'error' && !m.text().includes('404')) errs.push('CONSOLE: ' + m.text().slice(0, 160)); });

  await p.goto(BASE + '/signup/', { waitUntil: 'networkidle', timeout: 60000 });
  await p.waitForTimeout(1200);

  // 1. Empty submit -> validation errors
  await p.click('.su-submit');
  await p.waitForTimeout(400);
  const errTexts = await p.$$eval('.su-err:not(.is-hidden)', els => els.map(e => e.textContent.trim()).filter(Boolean));
  log('empty-submit errors', JSON.stringify(errTexts));
  log('alert', await p.$eval('.su-alert', e => e.textContent.trim()));

  // 2. Fill valid data
  await p.fill('input[autocomplete="name"]', 'Aisha Rahman');
  await p.fill('input[type="email"]', 'aisha@example.com');
  const pwInputs = await p.$$('input[type="password"]');
  await pwInputs[0].fill('Passw0rd!');
  await pwInputs[1].fill('Passw0rd!');
  log('password fields', pwInputs.length);

  // 3. Password visibility toggle
  const pwTypeBefore = await pwInputs[0].getAttribute('type');
  await p.click('.su-eye >> nth=0');
  await p.waitForTimeout(300);
  const afterToggle = await p.$$eval('input', els => els.filter(e => e.value === 'Passw0rd!').map(e => e.type));
  log('pw type before', pwTypeBefore);
  log('pw types after toggle', JSON.stringify(afterToggle));

  // 4. Switch account type
  await p.click('.su-type >> nth=1');
  await p.waitForTimeout(300);
  log('selected type after click', await p.$eval('.su-type.is-selected .su-type__title', e => e.textContent.trim()));
  log('aria-checked values', JSON.stringify(await p.$$eval('.su-type', els => els.map(e => e.getAttribute('aria-checked')))));

  // 5. Select F&B concept
  const opts = await p.$$eval('.su-select option', els => els.map(e => e.value));
  log('concept options', JSON.stringify(opts));
  await p.selectOption('.su-select', { label: 'Cloud Kitchen' });
  await p.waitForTimeout(200);
  log('concept value', await p.$eval('.su-select', e => e.value));

  // 6. Terms + valid submit
  await p.check('#su-terms');
  await p.click('.su-submit');
  await p.waitForTimeout(500);
  log('final alert', await p.$eval('.su-alert', e => e.textContent.trim()));
  log('final alert tone', await p.$eval('.su-alert', e => e.className));
  log('remaining visible errors', JSON.stringify(await p.$$eval('.su-err:not(.is-hidden)', els => els.map(e => e.textContent.trim()).filter(Boolean))));
  log('still on signup', p.url());

  // 7. Letter reveal present
  log('lr heading classes', await p.$eval('.su-title', e => e.className));
  log('lr char count', (await p.$$('.su-title .lr-char')).length);

  // 8. Topbar "Sign in" link
  log('navbar Sign in href', await p.$eval('.nav-actions a[href="/login"]', e => e.getAttribute('href')));
  log('navbar brand present', await p.locator('.topbar .brand').count());
  log('old su-topbar (must be 0)', await p.locator('.su-topbar').count());

  console.log('  errors:', errs.length ? errs.join(' | ') : 'none');
  await b.close();
})();
