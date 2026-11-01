// Functional probe for the signup page on the shared login shell.
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = process.argv[2] || 'http://127.0.0.1:8141';

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

  // 1. Shell parity with login: same backdrop structure, no navbar.
  log('shell classes', await p.$eval('main', e => e.className));
  log('backdrop is signup-city', await p.$eval('.lp-bg', e => getComputedStyle(e).backgroundImage));
  log('navbar present (must be 0)', await p.locator('.topbar').count());

  // 2. Card fits the viewport without scrolling.
  const card = await p.$eval('.lp-card', e => { const r = e.getBoundingClientRect(); return { h: Math.round(r.height), w: Math.round(r.width), top: Math.round(r.top) }; });
  log('card size', JSON.stringify(card));
  log('card clipped above viewport', card.top < 0);
  log('page scrolls', await p.evaluate(() => document.documentElement.scrollHeight > window.innerHeight));

  // 3. Empty submit -> validation errors
  await p.click('.lp-submit');
  await p.waitForTimeout(400);
  const errTexts = await p.$$eval('.lp-err:not(.is-hidden)', els => els.map(e => e.textContent.trim()).filter(Boolean));
  log('empty-submit errors', JSON.stringify(errTexts));
  log('alert', await p.$eval('.lp-alert', e => e.textContent.trim()));

  // 4. Password shorter than the documented minimum is rejected
  await p.fill('input[autocomplete="name"]', 'Aisha Rahman');
  await p.fill('input[type="email"]', 'aisha@example.com');
  const pwInputs = await p.$$('input[type="password"]');
  await pwInputs[0].fill('Passw0!');
  await pwInputs[1].fill('Passw0!');
  await p.check('#su-terms');
  await p.click('.lp-submit');
  await p.waitForTimeout(300);
  log('7-char rejected', await p.$eval('.su-pw-row .lp-group:first-child .lp-err', e => e.textContent.trim()));
  log('password fields', pwInputs.length);

  // 5. Password visibility toggle
  await pwInputs[0].fill('Passw0rd!');
  await pwInputs[1].fill('Passw0rd!');
  await p.click('.lp-eye >> nth=0');
  await p.waitForTimeout(300);
  const afterToggle = await p.$$eval('input', els => els.filter(e => e.value === 'Passw0rd!').map(e => e.type));
  log('pw types after toggle', JSON.stringify(afterToggle));
  await p.click('.lp-eye >> nth=0');

  // 6. Switch account type via the segmented control
  await p.click('.su-seg__opt >> nth=1');
  await p.waitForTimeout(300);
  log('selected option', await p.$eval('.su-seg__opt.is-selected', e => e.textContent.trim()));
  log('aria-checked values', JSON.stringify(await p.$$eval('.su-seg__opt', els => els.map(e => e.getAttribute('aria-checked')))));
  log('hint follows selection', (await p.$eval('.su-seg-hint', e => e.textContent.trim())).slice(0, 40));
  await p.click('.su-seg__opt >> nth=0');

  // 7. Select F&B concept
  const opts = await p.$$eval('.su-select option', els => els.map(e => e.value));
  log('concept options', JSON.stringify(opts));
  await p.selectOption('.su-select', { label: 'Cloud Kitchen' });
  await p.waitForTimeout(200);
  log('concept value', await p.$eval('.su-select', e => e.value));

  // 8. The terms row must not be a <label for="su-terms">: its Terms/Privacy
  //    links would then toggle the checkbox when clicked.
  log('terms text tag', await p.$eval('.su-terms .lp-remember-text', e => e.tagName));
  log('terms label-for (must be null)', await p.$eval('.su-terms .lp-remember-text', e => e.getAttribute('for')));
  const checkedBefore = await p.isChecked('#su-terms');
  await p.click('.su-terms .lp-remember-text small');
  await p.waitForTimeout(200);
  log('clicking the text does not toggle', checkedBefore === await p.isChecked('#su-terms'));

  // 9. Valid submit
  await p.click('.lp-submit');
  await p.waitForTimeout(600);
  log('final alert', await p.$eval('.lp-alert', e => e.textContent.trim()));
  log('final alert tone', await p.$eval('.lp-alert', e => e.className));
  log('remaining visible errors', JSON.stringify(await p.$$eval('.lp-err:not(.is-hidden)', els => els.map(e => e.textContent.trim()).filter(Boolean))));
  log('still on signup', p.url());

  // 10. Switch link back to login
  log('switch link href', await p.$eval('.lp-switch a', e => e.getAttribute('href')));

  console.log('  errors:', errs.length ? errs.join(' | ') : 'none');
  await b.close();
})();
