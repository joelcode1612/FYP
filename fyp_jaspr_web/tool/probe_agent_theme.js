// Agent workspace theme verification (uploaded DESIGN.md §4 light palette).
//
// The authenticated /agent routes fail closed behind the staff guard (bearer
// token checked against FastAPI, active staff role, aal2), so an end-to-end
// signed-in walkthrough is not possible without a real agent identity. This
// probe verifies what the change actually touched instead:
//
//   1. Guard behaviour is preserved: unauthenticated /agent 302s to the login
//      return-target, and the landing page keeps rendering (no theme leak).
//   2. The BUILT stylesheet re-themes a fixture that mirrors AppLayout's DOM:
//      agent shell = light blue canvas, white cards, royal-blue selected
//      controls, light form controls; plain shell (entrepreneur/owner base)
//      = unchanged dark canvas with the dark active chip.
//
// Usage: BASE=http://127.0.0.1:8090 node tool/probe_agent_theme.js
// (NODE_PATH must expose playwright-core.)

const { chromium } = require('playwright-core');
const fs = require('fs');
const path = require('path');

const BASE = process.env.BASE || 'http://127.0.0.1:8090';
const fixturePath = path.join(__dirname, 'agent_theme_fixture.html');
const builtCssPath = path.join(__dirname, '..', 'build', 'jaspr', 'styles.css');

const checks = [];
const ok = (name, pass, detail = '') =>
  checks.push({ name, pass: !!pass, detail });

(async () => {
  const browser = await chromium.launch({
    // The shell's proxy intercepts loopback traffic; force direct connections
    // so the probe reaches 127.0.0.1 (same reason builds unset proxy vars).
    args: ['--no-proxy-server'],
  });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));

  // --- 1. Client-side guard + landing isolation ------------------------------
  // The build is `jaspr: mode: client`, so workspace protection happens in the
  // client router (lib/app.dart `Router.redirect`): an anonymous /agent request
  // must land on /login with the destination preserved.
  await page.goto(`${BASE}/agent`, { waitUntil: 'load' });
  try {
    await page.waitForURL(/\/login\?next=%2Fagent/, { timeout: 20000 });
    ok('Anonymous /agent is redirected to /login?next=%2Fagent (guard preserved)', true, page.url());
  } catch {
    ok('Anonymous /agent is redirected to /login?next=%2Fagent (guard preserved)', false, 'stayed at ' + page.url());
  }

  await page.goto(`${BASE}/landing`, { waitUntil: 'networkidle' });
  const landing = await page.evaluate(() => ({
    lnd: !!document.querySelector('.lnd'),
    appShell: !!document.querySelector('.app-shell'),
  }));
  ok('Public /landing renders its marketing tree (.lnd)', landing.lnd);
  ok('Landing page carries no app shell (no workspace theme leak)', !landing.appShell);

  // --- 2. Built stylesheet contains the scoped agent block -------------------
  const css = fs.readFileSync(builtCssPath, 'utf8');
  ok('Built CSS carries .app-shell--agent token scope', css.includes('.app-shell.app-shell--agent'));
  ok('Built CSS keeps the admin block (role isolation)', css.includes('.app-shell.app-shell--admin'));
  ok('Built CSS still declares the shared dark shell', /(^|\n)\.app-shell \{/.test(css));

  // --- 3. Computed styles against the real built stylesheet ------------------
  await page.goto('file://' + fixturePath, { waitUntil: 'load' });
  await page.addStyleTag({ content: css });
  // The built stylesheet is ~330KB / 1.4k rules; give Blink a beat to apply
  // it fully before reading computed styles (a mid-parse snapshot yields
  // transitional colors).
  await page.waitForTimeout(600);

  const snap = await page.evaluate(() => {
    const cs = (sel) => {
      const el = document.querySelector(sel);
      return el ? getComputedStyle(el) : null;
    };
    const rgb = (sel, prop) => {
      const s = cs(sel);
      return s ? s[prop] : '';
    };
    return {
      agentShellBg: rgb('#shell-agent', 'backgroundColor'),
      agentShellColor: rgb('#shell-agent', 'colorScheme'),
      agentShellText: rgb('#shell-agent', 'color'),
      agentKpiBg: rgb('#agent-kpi', 'backgroundColor'),
      agentKpiBorder: rgb('#agent-kpi', 'borderTopColor'),
      agentTabBg: rgb('#agent-tab', 'backgroundColor'),
      agentActiveLink: (() => {
        const el = document.querySelector('#shell-agent .app-pill__link--active');
        if (!el) return null;
        const s = getComputedStyle(el);
        return { bg: s.backgroundColor, color: s.color };
      })(),
      agentPill: rgb('#shell-agent .app-pill', 'backgroundColor'),
      agentInputScheme: rgb('#agent-input', 'colorScheme'),
      agentPrimary: rgb('#agent-primary', 'backgroundColor'),
      plainShellBg: rgb('#shell-plain', 'backgroundColor'),
      plainActiveLink: (() => {
        const el = document.querySelector('#shell-plain .app-pill__link--active');
        if (!el) return null;
        return getComputedStyle(el).backgroundColor;
      })(),
      plainInputScheme: rgb('#plain-input', 'colorScheme'),
      plainKpiBg: rgb('#plain-kpi', 'backgroundColor'),
      overflowX: document.documentElement.scrollWidth > document.documentElement.clientWidth,
    };
  });

  const WHITE = 'rgb(255, 255, 255)';
  const BLUE = 'rgb(29, 78, 216)'; // #1D4ED8 royal blue
  ok('Agent canvas is #E8EEF6', snap.agentShellBg === 'rgb(232, 238, 246)', snap.agentShellBg);
  ok('Agent shell color-scheme light', snap.agentShellColor === 'light', snap.agentShellColor);
  ok('Agent body text is slate #1E293B', snap.agentShellText === 'rgb(30, 41, 59)', snap.agentShellText);
  ok('Agent KPI card is white', snap.agentKpiBg === WHITE, snap.agentKpiBg);
  ok('Agent card border is #E2E8F0', snap.agentKpiBorder === 'rgb(226, 232, 240)', snap.agentKpiBorder);
  ok('Agent selected tab is royal blue', snap.agentTabBg === BLUE, snap.agentTabBg);
  ok(
    'Agent nav active pill is royal blue with white text',
    snap.agentActiveLink && snap.agentActiveLink.bg === BLUE && snap.agentActiveLink.color === WHITE,
    snap.agentActiveLink ? `${snap.agentActiveLink.bg} / ${snap.agentActiveLink.color}` : 'missing',
  );
  ok('Agent floating nav stays a white surface', (snap.agentPill || '').startsWith('rgba(255, 255, 255'), snap.agentPill);
  ok('Agent form controls render light', snap.agentInputScheme === 'light', snap.agentInputScheme);
  ok('Agent primary button is the near-black chip', snap.agentPrimary === 'rgb(11, 15, 25)', snap.agentPrimary);

  ok('Plain shell (entrepreneur/owner base) stays dark', snap.plainShellBg === 'rgb(9, 9, 9)', snap.plainShellBg);
  ok('Plain shell active chip unchanged (dark)', snap.plainActiveLink === 'rgb(11, 15, 25)', snap.plainActiveLink);
  ok('Plain shell form controls still dark-scheme', snap.plainInputScheme === 'dark', snap.plainInputScheme);
  ok('Plain shell KPI surface unchanged', snap.plainKpiBg === 'rgb(24, 24, 24)', snap.plainKpiBg);
  ok('No horizontal overflow in fixture', !snap.overflowX);
  ok('No page errors', errors.length === 0, errors.join(' | '));

  await browser.close();

  let failed = 0;
  for (const c of checks) {
    if (!c.pass) failed++;
    console.log(`${c.pass ? 'PASS' : 'FAIL'}  ${c.name}${c.detail && !c.pass ? '  [' + c.detail + ']' : ''}`);
  }
  console.log(`\n${checks.length - failed}/${checks.length} checks passed`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((e) => {
  console.error('PROBE ERROR:', e.message);
  process.exit(1);
});
