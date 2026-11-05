// Verify the redesigned staff portal (reached via ?portal=staff):
//  - Centered dark-glass card on a dark-navy page (.stf-wrap > .stf-shell > .stf-card)
//  - Portal switcher present with the "Agent & Admin Portal" tab active
//  - "Sign In" title + "Access for Agents and Administrators only." sub
//  - Amber "Staff Access Only" callout
//  - Dark email / password fields (MFA field hidden until a challenge)
//  - Remember-me + Forgot Password? row, branded "Sign In" submit
//  - MFA notice footer
//  - No public staff self-registration link
//  - No horizontal overflow at 1440 / 800 / 390 px
const { chromium } = require('playwright-core');

const BASE = process.env.BASE || 'http://127.0.0.1:8141';

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const errors = [];
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));

  await page.goto(BASE + '/login?portal=staff', { waitUntil: 'networkidle' });
  await page.waitForSelector('.stf-card', { timeout: 10000 });
  await page.waitForTimeout(800);

  const snap = await page.evaluate(() => {
    const q = s => document.querySelector(s);
    const qa = s => Array.from(document.querySelectorAll(s));
    const txt = s => (q(s)?.textContent || '').trim().replace(/\s+/g, ' ');
    const mainCls = q('main')?.className || q('.login-page')?.className || '';
    const card = q('.stf-card');
    const callout = q('.stf-callout');
    // light text proxy for the dark-glass theme
    const cardColor = card ? getComputedStyle(card).color : '';
    const calloutBorder = callout ? getComputedStyle(callout).borderTopColor : '';
    const staffTab = qa('.portal-switch__opt').find(o =>
      /Agent & Admin Portal/.test(o.textContent || '') && o.classList.contains('is-active'));
    const entTab = qa('.portal-switch__opt').find(o =>
      /Entrepreneur Portal/.test(o.textContent || ''));
    return {
      mainClass: mainCls,
      // The sign-in portal is a split band (.lp-content > .stf-shell);
      // .stf-wrap now belongs only to standalone MFA / reset-password pages.
      hasShellInContent: !!q('.lp-content > .stf-shell'),
      hasPortalCard: !!q('.stf-card--portal'),
      hasShell: !!q('.stf-shell'),
      hasCard: !!q('.stf-card'),
      isStaffClass: /\bis-staff\b/.test(mainCls),
      cardTitle: txt('.stf-card-title'),
      cardSub: txt('.stf-card-sub'),
      calloutText: txt('.stf-callout'),
      mfaNoteText: txt('.stf-mfa-note'),
      submitText: txt('.stf-submit'),
      emailField: !!q('#stf-email'),
      passwordField: !!q('#stf-password'),
      mfaCount: qa('#stf-mfa').length,
      hasRemember: !!q('#stf-remember'),
      forgotLink: (q('.stf-forgot a')?.getAttribute('href') || '') + '|' +
        txt('.stf-forgot'),
      portalSwitchPresent: !!q('.portal-switch'),
      staffTabActive: !!staffTab,
      entTabPresent: !!entTab,
      cardColor,
      calloutBorder,
      // any public staff registration affordance
      signupLinks: qa('.stf-card a').map(a => ({
        href: a.getAttribute('href'),
        text: (a.textContent || '').trim(),
      })),
    };
  });

  const checks = [];
  const ok = (n, c) => checks.push({ name: n, pass: !!c });
  ok('Split-band shell .lp-content > .stf-shell', snap.hasShellInContent);
  ok('Staff portal card .stf-card--portal', snap.hasPortalCard);
  ok('Card shell .stf-shell', snap.hasShell);
  ok('Dark-glass card .stf-card', snap.hasCard);
  ok('Page carries is-staff class', snap.isStaffClass);
  ok('Portal switcher present', snap.portalSwitchPresent);
  ok('Agent & Admin tab active', snap.staffTabActive);
  ok('Entrepreneur tab present', snap.entTabPresent);
  ok('Card title "Sign In"', /Sign In/.test(snap.cardTitle));
  ok('Sub "Access for Agents and Administrators only."',
    /Access for Agents and Administrators only\./.test(snap.cardSub));
  ok('Amber callout "Staff Access Only"',
    /Staff Access Only/.test(snap.calloutText));
  ok('MFA notice present',
    /Multi-Factor Authentication \(MFA\)/.test(snap.mfaNoteText));
  ok('Email field', snap.emailField);
  ok('Password field', snap.passwordField);
  ok('MFA field hidden initially', snap.mfaCount === 0);
  ok('Remember-me checkbox', snap.hasRemember);
  ok('Forgot link -> /forgot', /\/forgot/.test(snap.forgotLink) &&
    /Forgot Password\?/.test(snap.forgotLink));
  ok('Submit "Sign In"', /Sign In/.test(snap.submitText));
  // light text on card => dark glass theme applied
  ok('Card uses light text (dark theme)', /^rgb\(\s*2[0-3][0-9]/.test(snap.cardColor));
  ok('No public staff registration link',
    !snap.signupLinks.some(l =>
      /\/signup/.test(l.href || '') ||
      /create account|register|sign up/i.test(l.text)));

  // Responsive overflow checks
  const widths = [1440, 800, 390];
  const overflow = {};
  for (const w of widths) {
    await page.setViewportSize({ width: w, height: 900 });
    await page.waitForTimeout(250);
    overflow[w] = await page.evaluate(() =>
      document.documentElement.scrollWidth - window.innerWidth);
    ok('No h-overflow @' + w, overflow[w] <= 1);
  }

  const allPass = checks.every(c => c.pass);
  console.log('=== STAFF PORTAL PROBE ===');
  console.log(JSON.stringify({ snap, overflow, checks, pageErrors: errors }, null, 2));
  console.log(allPass ? 'RESULT: PASS' : 'RESULT: FAIL');
  await browser.close();
  process.exit(allPass ? 0 : 1);
})().catch(e => { console.error('PROBE ERROR', e); process.exit(2); });
