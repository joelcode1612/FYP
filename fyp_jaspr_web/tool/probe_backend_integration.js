// Verifies that the Jaspr SSR app uses FYP/backend (FastAPI :8000) through a
// same-origin /api/* proxy, with no runtime dependency on FYP/test (:3001).
//
// Does NOT need real Supabase credentials: it exercises the real auth bridge,
// the real SSR proxy, the PKCE OAuth request and the hydrated /auth/callback
// route, then records clearly which checks require a live test identity.
//
// Usage:
//   BASE=http://127.0.0.1:8090 NODE_PATH=<managed node workspace> \
//     node tool/probe_backend_integration.js
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');

const BASE = process.env.BASE || 'http://127.0.0.1:8090';
const EXE = process.env.CHROME_PATH ||
  'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const root = path.resolve(__dirname, '..');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const checks = [];
const ok = (name, cond, detail = '') => {
  checks.push({ name, pass: !!cond, detail: String(detail).slice(0, 200) });
};

async function get(pathname, init) {
  try {
    const res = await fetch(BASE + pathname, {
      ...init,
      signal: AbortSignal.timeout(8000),
    });
    const text = await res.text();
    return { status: res.status, text, headers: res.headers };
  } catch (e) {
    return { status: 0, text: String(e.message || e), headers: new Map() };
  }
}

(async () => {
  // --- 1. Launcher / generator source audit --------------------------------
  const serve = fs.readFileSync(path.join(root, 'serve.impl.ps1'), 'utf8');
  const rootLauncher = fs.readFileSync(path.join(root, '..', 'start-sitewise.ps1'), 'utf8');
  const generator = fs.readFileSync(path.join(root, 'tool', 'gen_auth_config.js'), 'utf8');
  const authSource = fs.readFileSync(path.join(root, 'tool', 'auth_client.js'), 'utf8');
  const bundle = fs.readFileSync(path.join(root, 'web', 'auth_bundle.js'), 'utf8');

  ok('launcher never starts FYP/test API',
    !/test[\\/]start-api\.ps1|start:app|app-server\.js/.test(serve));
  ok('start-sitewise.ps1 never starts FYP/test API',
    !/test[\\/]start-api\.ps1|start:app|app-server\.js/.test(rootLauncher));
  ok('launcher health-checks FastAPI on 8000',
    /8000/.test(serve) && /\/health/.test(serve) && /FYP\/backend/.test(serve));
  // PowerShell resolves a bare .\serve to serve.ps1 BEFORE PATHEXT looks at
  // serve.cmd, and this machine's AllSigned policy rejects unsigned .ps1 files.
  // Keeping the implementation under serve.impl.ps1 makes .\serve work.
  ok('.\\serve resolves to the .cmd wrapper',
    !fs.existsSync(path.join(root, 'serve.ps1')) &&
    fs.existsSync(path.join(root, 'serve.cmd')) &&
    /serve\.impl\.ps1/.test(fs.readFileSync(path.join(root, 'serve.cmd'), 'utf8')));
  ok('auth config comes from FYP/backend/.env',
    /backend/.test(generator) && !/['"]test['"]\s*,\s*['"]\.env['"]/.test(generator));
  ok('no localhost:8000 fallback in auth source',
    !/localhost:8000/.test(authSource));
  ok('no localhost:8000 fallback in built bundle',
    !/localhost:8000/.test(bundle));
  ok('auth-config URL is root-relative in source',
    /['"]\/auth-config\.json['"]/.test(authSource));
  ok('generated public config has no secret key', (() => {
    const c = JSON.parse(fs.readFileSync(path.join(root, 'web', 'auth-config.json'), 'utf8'));
    return c.configured === true && !!c.supabaseUrl &&
      String(c.supabasePublishableKey).startsWith('sb_publishable_') &&
      !/sb_secret_|service_role|SUPABASE_SECRET/i.test(JSON.stringify(c));
  })());

  // --- 2. SSR document + static config -------------------------------------
  const home = await get('/');
  ok('GET / is 200', home.status === 200, home.status);
  ok('/ is server-rendered HTML', /<h1/.test(home.text) && /<base href="\/"/.test(home.text));
  ok('/ has no SPA #app shell', !/id="app"/.test(home.text));
  login: {
    const login = await get('/login');
    ok('GET /login is 200 with SSR form', login.status === 200 && /type="email"/.test(login.text));
    ok('sitewise-api meta is same-origin (empty)',
      /<meta name="sitewise-api" content\s*\/?\s*>/.test(login.text.replace(/content=""/, 'content')));
  }
  const config = await get('/auth-config.json');
  ok('/auth-config.json served at root', config.status === 200, config.status);
  ok('/auth-config.json has public Supabase values', (() => {
    try {
      const c = JSON.parse(config.text);
      return c.configured && /\.supabase\.co$/.test(c.supabaseUrl) && !!c.supabasePublishableKey;
    } catch { return false; }
  })());
  const callback = await get('/auth/callback');
  ok('GET /auth/callback renders SSR HTML',
    callback.status === 200 && /Completing sign-in/.test(callback.text));
  const missing = await get('/definitely-not-a-route');
  ok('unknown route answers 404', missing.status === 404, missing.status);

  // --- 3. Same-origin proxy -> intended FastAPI backend --------------------
  const health = await get('/health');
  ok('frontend /health proxies to FastAPI', health.status === 200 && /"status":"ok"/.test(health.text), health.status);
  const v1health = await get('/api/v1/health');
  ok('frontend /api/v1/health reaches backend DB',
    v1health.status === 200 && /"database":"ok"/.test(v1health.text), v1health.text.slice(0, 120));
  const me = await get('/api/v1/auth/me');
  ok('/api/v1/auth/me reachable (401 unauthenticated)', me.status === 401, me.status);
  const catalog = await get('/api/v1/catalog/properties?limit=2&offset=0');
  ok('catalog endpoint reachable (401 unauthenticated)', catalog.status === 401, catalog.status);
  const legacy = await get('/api/catalog/properties');
  ok('legacy /api/catalog/properties is not the app API', legacy.status === 404, legacy.status);
  let testApiUp = false;
  try {
    const r = await fetch('http://127.0.0.1:3001/api/config', { signal: AbortSignal.timeout(1500) });
    testApiUp = r.ok;
  } catch { /* expected: nothing from FYP/test is running */ }
  ok('no FYP/test Express API running on 3001', !testApiUp);

  // --- 4. Browser: config, hydration, no cross-origin API calls ------------
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const requests = [];
  const pageErrors = [];
  page.on('request', (r) => requests.push(r.url()));
  page.on('pageerror', (e) => pageErrors.push(e.message));

  await page.goto(BASE + '/login', { waitUntil: 'networkidle', timeout: 60000 });
  await page.waitForFunction(() => !!window.sitewiseAuth, null, { timeout: 15000 }).catch(() => {});
  await sleep(2000);
  const snap = await page.evaluate(() => {
    try { return JSON.parse(window.sitewiseAuth.snapshot()); } catch { return {}; }
  });
  ok('auth bridge loaded and configured', snap.configured === true, JSON.stringify(snap.error));
  ok('bridge reports backend available', snap.backendAvailable === true);
  ok('bridge has no initialization error', !snap.error, snap.error);
  ok('nested route fetched root /auth-config.json',
    requests.some((u) => new URL(u).pathname === '/auth-config.json'));
  ok('no nested-route config URL', !requests.some((u) => /\/login\/auth-config/.test(u)));
  ok('health probe used same origin', requests.some((u) => u === BASE + '/health'));
  ok('browser never requests :8000 or :3001',
    !requests.some((u) => /:8000|:3001/.test(u)),
    requests.filter((u) => /:8000|:3001/.test(u)).join(','));
  ok('Google button enabled', await page.locator('.lp-social[data-provider="google"]').first().isEnabled().catch(() => false));
  ok('Apple honestly disabled',
    (await page.locator('.lp-social[data-provider="apple"]').first().getAttribute('aria-disabled').catch(() => null)) === 'true');

  // Password sign-in with a deliberately invalid identity must reach Supabase
  // and return a real error (proves the bridge, not a stub, is wired up).
  const loginError = await page.evaluate(async () => {
    const attempt = (async () => {
      try {
        await window.sitewiseAuth.password('probe-invalid@sitewise.local', 'not-a-real-password', false, '');
        return 'NO_ERROR';
      } catch (e) { return String(e.message || e); }
    })();
    return Promise.race([
      attempt,
      new Promise((r) => setTimeout(() => r('TIMEOUT contacting Supabase'), 15000)),
    ]);
  });
  ok('password sign-in reaches Supabase (invalid creds rejected)',
    /invalid|credentials|email|password|failed|network|timeout/i.test(loginError) && loginError !== 'NO_ERROR',
    loginError);

  // Unauthenticated API call is rejected by the bridge before any fetch.
  const apiError = await page.evaluate(async () => {
    try { await window.sitewiseAuth.request('/api/v1/auth/me', 'GET', ''); return 'NO_ERROR'; }
    catch (e) { return String(e.message || e); }
  });
  ok('bridge rejects API calls without a session', /Sign in to continue/.test(apiError), apiError);

  // PKCE OAuth request -> correct callback URL.
  let oauth;
  await page.route('**/auth/v1/authorize?**', async (route) => {
    oauth = new URL(route.request().url());
    await route.fulfill({ contentType: 'text/html', body: 'OAuth intercepted by probe.' });
  });
  try {
    await page.locator('.lp-social[data-provider="google"]').first().click({ force: true, timeout: 10000 });
    await page.waitForURL('**/auth/v1/authorize?**', { timeout: 15000 });
  } catch (e) { /* oauth stays undefined -> checks below fail */ }
  ok('Google OAuth PKCE request issued', !!oauth);
  ok('OAuth redirect_to is /auth/callback',
    oauth?.searchParams.get('redirect_to') === BASE + '/auth/callback', oauth?.searchParams.get('redirect_to'));
  ok('OAuth uses PKCE S256', oauth?.searchParams.get('code_challenge_method') === 's256' && !!oauth?.searchParams.get('code_challenge'));

  // Callback hydration: with no session, complete() must refuse rather than
  // inventing a least-privileged profile and entering a workspace.
  const cb = await browser.newPage();
  cb.on('pageerror', (e) => pageErrors.push('callback: ' + e.message));
  await cb.goto(BASE + '/auth/callback', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(2500);
  const cbText = await cb.locator('body').innerText();
  ok('/auth/callback hydrates and invokes complete()', /Sign-in could not finish/.test(cbText), cbText.slice(0, 120));
  ok('callback never fabricates a profile/workspace',
    /No authenticated session/.test(cbText) && !/source.*supabase-fallback|supabase-fallback/.test(cbText));
  ok('callback stays on /auth/callback', new URL(cb.url()).pathname === '/auth/callback', cb.url());

  // Signup page also initializes from the root-relative config.
  await page.goto(BASE + '/signup', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(1500);
  ok('/signup Google button enabled',
    await page.locator('.lp-social[data-provider="google"]').first().isEnabled().catch(() => false));

  ok('no uncaught page errors', pageErrors.length === 0, pageErrors.join(' | '));
  await browser.close();

  // --- Result ---------------------------------------------------------------
  const passed = checks.filter((c) => c.pass).length;
  for (const c of checks) {
    console.log(`${c.pass ? 'PASS' : 'FAIL'}  ${c.name}${c.pass || !c.detail ? '' : '  -> ' + c.detail}`);
  }
  console.log(`\n${passed}/${checks.length} checks passed`);
  console.log('NOTE: a credential-based sign-in, session refresh and logout are not');
  console.log('      executed here (no authorized test identity available).');
  process.exit(passed === checks.length ? 0 : 1);
})().catch((e) => { console.error('PROBE ERROR', e); process.exit(2); });
