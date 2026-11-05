// Verify the new/updated auth surfaces render in the production build:
//  - /staff/mfa          -> dark staff card, "Secure Your Staff Account",
//                           amber callout, code field, MFA note
//  - /reset-password     -> dark staff card, New/Confirm password fields
//  - /forgot             -> auth card with email field + "Continue" submit
//  - /login?portal=staff -> still the dark-glass sign-in (regression)
// These pages are pre-auth so no Supabase session is needed to render them.
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = process.env.BASE || 'http://127.0.0.1:8141';

const checks = [];
const ok = (n, c) => checks.push({ name: n, pass: !!c });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));

  const txt = (sel) => page.locator(sel).first().innerText().catch(() => '');
  const count = (sel) => page.locator(sel).count();

  // --- /staff/mfa -----------------------------------------------------------
  await page.goto(BASE + '/staff/mfa', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(1200);
  ok('staff/mfa dark card', (await count('.login-page.is-staff .stf-card')) >= 1);
  ok('staff/mfa title "Secure Your Staff Account"',
    /Secure Your Staff Account/.test(await txt('.stf-card-title')));
  ok('staff/mfa amber callout', (await count('.stf-callout')) >= 1);
  ok('staff/mfa MFA note', (await count('.stf-mfa-note')) >= 1);
  ok('staff/mfa switcher present', (await count('.portal-switch')) >= 1);

  // --- /reset-password ------------------------------------------------------
  await page.goto(BASE + '/reset-password', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(1000);
  ok('reset dark card', (await count('.login-page.is-staff .stf-card')) >= 1);
  ok('reset New Password field', (await count('#rst-password')) === 1);
  ok('reset Confirm field', (await count('#rst-confirm')) === 1);
  ok('reset eye toggles', (await count('.lp-eye')) >= 1);
  ok('reset submit present', (await count('.stf-submit')) === 1);

  // --- /forgot --------------------------------------------------------------
  await page.goto(BASE + '/forgot', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(1000);
  ok('forgot email field', (await count('input[type="email"]')) >= 1);
  ok('forgot submit "Continue"', /Continue/.test(await txt('.auth-submit')));
  ok('forgot no "demo disabled" copy',
    !(await txt('.auth-alert')).includes('Demo build'));

  // --- /login?portal=staff regression ---------------------------------------
  await page.goto(BASE + '/login?portal=staff', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(1000);
  ok('staff sign-in card intact', (await count('.stf-card')) >= 1);
  ok('staff sign-in title', /Sign In/.test(await txt('.stf-card-title')));
  ok('no Google button on staff portal', (await count('.stf-card .lp-social')) === 0);

  for (const w of [1440, 390]) {
    await page.setViewportSize({ width: w, height: 900 });
    await page.goto(BASE + '/staff/mfa', { waitUntil: 'networkidle', timeout: 60000 });
    await sleep(700);
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - window.innerWidth);
    ok(`no h-overflow staff/mfa @${w}`, overflow <= 1);
  }

  const allPass = checks.every((c) => c.pass);
  console.log(JSON.stringify({ checks, pageErrors: errors }, null, 2));
  console.log(allPass ? 'RESULT: PASS' : 'RESULT: FAIL');
  await browser.close();
  process.exit(allPass ? 0 : 1);
})().catch((e) => { console.error('PROBE ERROR', e); process.exit(2); });
