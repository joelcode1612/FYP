// SSR / MPA verification probe.
//
// Proves the three claims that separate this build from the old SPA:
//   1. raw responses already contain the page (no JS needed for content),
//   2. hydration works — real click handlers run in the browser,
//   3. navigation is a document request, not a pushState route swap.
//
// Run against a server started from build/jaspr:
//   BASE=http://127.0.0.1:8090 node tool/probe_ssr_mpa.js
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = process.env.BASE || 'http://127.0.0.1:8090';

const checks = [];
const ok = (n, c, extra = '') => {
  checks.push({ name: n, pass: !!c, extra });
  if (!c && extra) console.log('   note:', n, '->', extra);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function raw(path) {
  const res = await fetch(BASE + path, { redirect: 'manual' });
  return { status: res.status, location: res.headers.get('location'), body: await res.text() };
}

(async () => {
  // --- 1. Server-rendered documents (no browser involved) --------------------
  const home = await raw('/');
  ok('GET / is 200', home.status === 200, String(home.status));
  ok('/ body has the hero <h1>', /<h1[^>]*class="lr/.test(home.body));
  ok('/ body has actual sections, not an empty root', /class="lnd"/.test(home.body) && home.body.length > 20000);
  ok('/ head carries the title', /<title>Sitewise/.test(home.body));
  ok('/ head carries a meta description', /name="description" content="[^"]{40,}/.test(home.body));
  ok('/ links the stylesheet', /stylesheet" type="text\/css" href="styles.css"|href="styles.css" rel="stylesheet"/.test(home.body));
  ok('/ has no <div id="app"> shell', !/id="app"/.test(home.body));

  const login = await raw('/login');
  ok('GET /login is 200', login.status === 200);
  ok('/login server HTML contains the email field', /type="email"/.test(login.body));
  ok('/login server HTML contains an interactive submit button', /lp-submit|lp-signin|type="button"/.test(login.body));

  const staffLogin = await raw('/staff/signin');
  ok('/staff/signin server HTML contains the staff card', /stf-card/.test(staffLogin.body));

  const notFound = await raw('/definitely-not-a-page');
  ok('unknown route answers 404', notFound.status === 404, String(notFound.status));
  ok('404 document has the fallback copy', /Page not found/.test(notFound.body));

  const guarded = await raw('/entrepreneur/explore');
  ok('anonymous workspace request redirects', guarded.status === 302, String(guarded.status));
  ok('redirect keeps the destination in ?next', /next=%2Fentrepreneur%2Fexplore/.test(guarded.location || ''), guarded.location || '');

  const css = await fetch(BASE + '/styles.css');
  ok('stylesheet is served', css.status === 200);
  const js = await fetch(BASE + '/main.client.dart.js');
  ok('client bundle is served', js.status === 200);

  // --- 2. Hydration ---------------------------------------------------------
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  // A session cookie so workspace routes render instead of redirecting.
  const session = Buffer.from(
    JSON.stringify({ user_id: 'probe', role: 'entrepreneur', name: 'Probe User', email: 'probe@sitewise.my' }),
  )
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
  await context.addCookies([{ name: 'sitewise_session', value: session, url: BASE }]);

  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));

  // Landing page interactivity: the challenge pills must switch the copy.
  await page.goto(BASE + '/', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(1500);
  const heroTitle = await page.locator('.lr').first().innerText().catch(() => '');
  ok('landing hydrated: letter-reveal finished', /Find the right place/.test(heroTitle), heroTitle.slice(0, 40));

  const pill = page.locator('.challenge-pill').nth(1);
  const hasPill = (await pill.count()) > 0;
  ok('landing has a challenge pill', hasPill);
  if (hasPill) {
    const selectedBefore = await pill.getAttribute('aria-selected');
    await pill.click({ force: true });
    await sleep(400);
    const selectedAfter = await pill.getAttribute('aria-selected');
    ok('pill click handled in the browser', selectedBefore !== selectedAfter, `${selectedBefore} -> ${selectedAfter}`);
  }

  // The listings themselves need a real Supabase token, but the chrome around
  // them does not: the search control is pure client state, so opening it
  // proves the workspace page hydrated rather than staying inert markup.
  await page.goto(BASE + '/entrepreneur/explore', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(1500);
  ok('explore rendered server-side shell', (await page.locator('.app-shell').count()) === 1);
  const searchBtn = page.locator('button[aria-label="Search listings"]').first();
  const hasSearch = (await searchBtn.count()) > 0;
  ok('explore has the search control', hasSearch);
  if (hasSearch) {
    await searchBtn.click({ force: true });
    await sleep(400);
    ok('search dialog opens (hydration)', (await page.locator('.overlay .dialog').count()) >= 1);
    await page.keyboard.press('Escape');
    await sleep(200);
  }

  // --- 3. Navigation is a document request ---------------------------------
  const nav = await page.goto(BASE + '/', { waitUntil: 'networkidle' });
  ok('navigation returns a document', nav.ok() && (await page.title()).length > 0);
  const navType = await page.evaluate(() => performance.getEntriesByType('navigation')[0]?.type);
  ok('first load is a navigate, not a soft swap', navType === 'navigate' || navType === 'reload', String(navType));

  // Clicking a link must produce a new document: stamp the old one and check it is gone.
  await page.evaluate(() => { window.__ssrProbeStamp = 'alive'; });
  await page.locator('a[href="/login"]').last().click({ force: true });
  await page.waitForLoadState('networkidle');
  const stamp = await page.evaluate(() => window.__ssrProbeStamp || null);
  ok('link click loads a fresh document', stamp === null && page.url().endsWith('/login'), page.url());

  ok('no uncaught page errors', errors.length === 0, errors.join(' | '));

  await browser.close();

  const passed = checks.filter((c) => c.pass).length;
  for (const c of checks) console.log(`${c.pass ? 'PASS' : 'FAIL'}  ${c.name}`);
  console.log(`\n${passed}/${checks.length} checks passed`);
  process.exit(passed === checks.length ? 0 : 1);
})();
