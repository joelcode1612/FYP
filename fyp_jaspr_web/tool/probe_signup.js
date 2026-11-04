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

  // 1. Shell parity with login: same backdrop structure + the landing navbar.
  log('shell classes', await p.$eval('main', e => e.className));
  log('backdrop is signup-city', await p.$eval('.lp-bg', e => getComputedStyle(e).backgroundImage));
  log('nav links', JSON.stringify(await p.$$eval('.lp-nav .navlinks a', els => els.map(a => a.getAttribute('href')))));
  log('nav CTAs', JSON.stringify(await p.$$eval('.lp-nav .nav-btn', els => els.map(a => a.getAttribute('href')))));
  log('brand inverted over hero', await p.$eval('.lp-nav .brand', e => getComputedStyle(e).color));
  log('bar background at top', await p.$eval('.lp-nav .topbar', e => getComputedStyle(e).backgroundColor));
  log('hero clears the bar', await p.evaluate(() => {
    const bar = document.querySelector('.lp-nav').getBoundingClientRect();
    const eye = document.querySelector('.lp-eyebrow').getBoundingClientRect();
    return eye.top >= bar.bottom - 1;
  }));
  log('brand aligns with hero', await p.evaluate(() => {
    const a = document.querySelector('.lp-nav .brand').getBoundingClientRect().left;
    const b = document.querySelector('.lp-eyebrow').getBoundingClientRect().left;
    return Math.round(Math.abs(a - b));
  }));
  log('card aligns with Sign up', await p.evaluate(() => {
    const a = document.querySelector('.lp-nav .nav-btn.signup').getBoundingClientRect().right;
    const b = document.querySelector('.lp-card').getBoundingClientRect().right;
    return Math.round(Math.abs(a - b));
  }));
  log('navbar links resolve to landing', await p.evaluate(() => {
    const a = document.querySelector('.lp-nav .navlinks a');
    return new URL(a.href, location.href).pathname + new URL(a.href, location.href).hash;
  }));

  // 2. Card fits the viewport without scrolling.
  const card = await p.$eval('.lp-card', e => { const r = e.getBoundingClientRect(); return { h: Math.round(r.height), w: Math.round(r.width), top: Math.round(r.top) }; });
  log('card size', JSON.stringify(card));
  log('card clipped above viewport', card.top < 0);
  log('page scrolls', await p.evaluate(() => document.documentElement.scrollHeight > window.innerHeight));

  // 2b. Shorten the viewport so the document can scroll, then check the bar
  //     solidifies and returns to transparent.
  await p.setViewportSize({ width: 1440, height: 600 });
  await p.waitForTimeout(300);
  await p.evaluate(() => window.scrollTo(0, 400));
  await p.waitForTimeout(400);
  log('nav class after scroll', await p.$eval('.lp-nav', e => e.className));
  log('bar background after scroll', await p.$eval('.lp-nav .topbar', e => getComputedStyle(e).backgroundColor));
  log('brand colour after scroll', await p.$eval('.lp-nav .brand', e => getComputedStyle(e).color));
  await p.evaluate(() => window.scrollTo(0, 0));
  await p.waitForTimeout(400);
  log('nav class back at top', await p.$eval('.lp-nav', e => e.className));
  await p.setViewportSize({ width: 1440, height: 980 });
  await p.waitForTimeout(300);

  // 3. The removed signup-only controls must be gone.
  log('account-type / concept / terms nodes (must be 0,0,0)', JSON.stringify([
    await p.locator('.su-seg').count(),
    await p.locator('.su-select').count(),
    await p.locator('#su-terms').count(),
  ]));

  // 4. Empty submit -> validation errors
  await p.click('.lp-submit');
  await p.waitForTimeout(400);
  const errTexts = await p.$$eval('.lp-err:not(.is-hidden)', els => els.map(e => e.textContent.trim()).filter(Boolean));
  log('empty-submit errors', JSON.stringify(errTexts));
  log('alert', await p.$eval('.lp-alert', e => e.textContent.trim()));

  // 5. Password shorter than the documented minimum is rejected
  await p.fill('input[autocomplete="name"]', 'Aisha Rahman');
  await p.fill('input[type="email"]', 'aisha@example.com');
  const pwInputs = await p.$$('input[type="password"]');
  await pwInputs[0].fill('Passw0!');
  await pwInputs[1].fill('Passw0!');
  await p.click('.lp-submit');
  await p.waitForTimeout(300);
  log('7-char rejected', await p.$eval('.su-pw-row .lp-group:first-child .lp-err', e => e.textContent.trim()));
  log('password fields', pwInputs.length);

  // 6. Mismatched confirmation is rejected
  await pwInputs[0].fill('Passw0rd!');
  await pwInputs[1].fill('Passw0rd?');
  await p.click('.lp-submit');
  await p.waitForTimeout(300);
  log('mismatch rejected', await p.$eval('.su-pw-row .lp-group:last-child .lp-err', e => e.textContent.trim()));

  // 7. Password visibility toggle
  await pwInputs[1].fill('Passw0rd!');
  await p.click('.lp-eye >> nth=0');
  await p.waitForTimeout(300);
  const afterToggle = await p.$$eval('input', els => els.filter(e => e.value === 'Passw0rd!').map(e => e.type));
  log('pw types after toggle', JSON.stringify(afterToggle));
  await p.click('.lp-eye >> nth=0');

  // 8. Valid submit
  await p.click('.lp-submit');
  await p.waitForTimeout(600);
  log('final alert', await p.$eval('.lp-alert', e => e.textContent.trim()));
  log('final alert tone', await p.$eval('.lp-alert', e => e.className));
  log('remaining visible errors', JSON.stringify(await p.$$eval('.lp-err:not(.is-hidden)', els => els.map(e => e.textContent.trim()).filter(Boolean))));
  log('still on signup', p.url());

  // 9. Switch link back to login
  log('switch link href', await p.$eval('.lp-switch a', e => e.getAttribute('href')));

  console.log('  errors:', errs.length ? errs.join(' | ') : 'none');
  await b.close();
})();
