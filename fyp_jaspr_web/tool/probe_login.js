// Functional probe for the redesigned split-layout login page.
// Checks: structural classes, no navbar, eye toggle, validation errors,
// disabled social providers, forgot/signup routes, remember checkbox.
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = process.env.BASE || 'http://127.0.0.1:8141';

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

  await p.goto(BASE + '/login/', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(900);

  // 1. Structure: split layout present, top navbar absent.
  log('login-page', await p.locator('.login-page').count());
  log('hero present', await p.locator('.lp-hero').count());
  log('accent text', await p.locator('.lp-accent').innerText().catch(() => 'MISSING'));
  log('features', await p.locator('.lp-feature').count());
  log('card present', await p.locator('.lp-card').count());
  log('navbar (must be 0)', await p.locator('.login-page nav, .login-page .lp-topbar').count());
  log('bg image loaded', await p.evaluate(async () => {
    const el = document.querySelector('.lp-bg');
    if (!el) return 'no element';
    const url = getComputedStyle(el).backgroundImage.match(/url\("?(.*?)"?\)/)?.[1];
    if (!url) return 'no url';
    const img = new Image();
    img.src = url;
    await img.decode();
    return `${img.naturalWidth}x${img.naturalHeight}`;
  }));

  // 2. Social providers disabled with explanation.
  const socials = p.locator('.lp-social');
  log('social buttons', await socials.count());
  for (let i = 0; i < await socials.count(); i++) {
    log(`  social[${i}] disabled`, await socials.nth(i).isDisabled());
  }
  log('social note', (await p.locator('.lp-social-note').innerText().catch(() => 'MISSING')).slice(0, 60));

  // 3. Labels are associated with inputs.
  log('email label for', await p.locator('label[for="lp-email"]').count());
  log('email input id', await p.locator('#lp-email').count());
  log('password label for', await p.locator('label[for="lp-password"]').count());

  // 4. Empty submit -> validation errors.
  await p.click('.lp-submit');
  await sleep(300);
  const errsShown = await p.locator('.lp-err:not(.is-hidden)').allInnerTexts();
  log('empty-submit errors', JSON.stringify(errsShown));
  log('alert', (await p.locator('.lp-alert').innerText()).slice(0, 60));

  // 5. Email format validation.
  await p.fill('#lp-email', 'not-an-email');
  await p.fill('#lp-password', 'x');
  await p.click('.lp-submit');
  await sleep(300);
  log('bad-email error', JSON.stringify(await p.locator('.lp-err:not(.is-hidden)').allInnerTexts()));

  // 6. Password visibility toggle.
  const pw = p.locator('#lp-password');
  log('pw type before', await pw.getAttribute('type'));
  await p.click('.lp-eye');
  await sleep(200);
  log('pw type after toggle', await pw.getAttribute('type'));
  log('eye aria-pressed', await p.locator('.lp-eye').getAttribute('aria-pressed'));
  await p.click('.lp-eye');
  await sleep(200);
  log('pw type after 2nd toggle', await pw.getAttribute('type'));

  // 7. Remember checkbox toggles.
  const cb = p.locator('#lp-remember');
  log('remember checked initially', await cb.isChecked());
  await cb.click();
  await sleep(200);
  log('remember after click', await cb.isChecked());
  await cb.click();

  // 8. Valid input -> demo alert.
  await p.fill('#lp-email', 'owner@sitewise.test');
  await p.fill('#lp-password', 'secret123');
  await p.click('.lp-submit');
  await sleep(300);
  log('valid-submit alert', (await p.locator('.lp-alert').innerText()).slice(0, 80));
  log('still on /login', p.url().replace(BASE, ''));

  // 9. Routes from the card.
  log('forgot href', await p.locator('.lp-forgot a').getAttribute('href'));
  log('signup href', await p.locator('.lp-switch a').getAttribute('href'));
  await p.click('.lp-switch a');
  await sleep(500);
  log('signup navigation', p.url().replace(BASE, ''));
  await p.goto(BASE + '/login/', { waitUntil: 'networkidle' });
  await p.click('.lp-forgot a');
  await sleep(500);
  log('forgot navigation', p.url().replace(BASE, ''));

  // 10. Overflow checks at desktop and mobile.
  for (const vp of [{ width: 1440, height: 980 }, { width: 390, height: 844 }]) {
    await p.setViewportSize(vp);
    await p.goto(BASE + '/login/', { waitUntil: 'networkidle' });
    await sleep(600);
    const overflow = await p.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth
    );
    log(`overflow @${vp.width}px`, overflow);
    await p.screenshot({
      path: `tool/_diag/login_${vp.width}.png`,
      fullPage: false,
    });
  }

  log('errors', errs.length ? errs.join(' | ') : 'none');
  await b.close();
})();
