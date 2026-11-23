// Authenticated Jaspr browser E2E against a genuine Supabase identity (P3.4).
//
// Why this is different from session_harness.js
// ---------------------------------------------
// The harness replaces the auth bridge with a stand-in and answers the API from
// a fixture. That proves the pages render; it proves nothing about authentication.
// This script instead seeds a REAL session — an ES256 token issued by Supabase and
// verified by the FastAPI backend against the project's JWKS — and then checks the
// three outcomes that matter:
//
//   CONTROL A  no session        -> workspace redirects to /login (guard active)
//   CONTROL B  genuine session   -> workspace renders, API authorizes
//   CONTROL C  tampered token    -> rejected (verification not weakened)
//
// CONTROL C is the point of the exercise: it shows that admitting CONTROL B is
// evidence of real verification rather than evidence of a bypass.
//
// Usage:
//   node probe_auth_e2e_p3.js <outdir>
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');

const EXE = process.env.CHROME_EXE
  || 'C:/Users/HP/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const ORIGIN = process.env.ORIGIN || 'http://127.0.0.1:8090';
const SESSION_FILE = path.join(__dirname, '..', '..', 'backend', 'var', 'e2e_p3_session.json');

const ROUTE = '/entrepreneur';
const OUT = process.argv[2] || path.join(__dirname, 'screenshots', 'p3_auth_e2e');

function loadSession() {
  if (!fs.existsSync(SESSION_FILE)) {
    throw new Error(`Missing session at ${SESSION_FILE}. Run the sign-in step first.`);
  }
  return JSON.parse(fs.readFileSync(SESSION_FILE, 'utf8'));
}

async function probe(browser, { name, session, tamper }) {
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
    bypassCSP: true,
    ignoreHTTPSErrors: true,
  });
  const page = await ctx.newPage();
  const consoleErrors = [];
  const apiCalls = [];
  page.on('pageerror', (e) => consoleErrors.push('pageerror: ' + e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') consoleErrors.push('console: ' + m.text().slice(0, 200));
  });
  page.on('response', async (r) => {
    const u = r.url();
    if (u.includes('/api/v1/')) {
      apiCalls.push({ url: u.replace(ORIGIN, ''), status: r.status() });
    }
  });

  if (session) {
    const payload = {
      storage_key: session.storage_key,
      session: JSON.parse(JSON.stringify(session.session)),
    };
    if (tamper) {
      // Flip one character of the signature. The header and claims stay valid,
      // so only signature verification can reject this.
      const parts = payload.session.access_token.split('.');
      const sig = parts[2];
      const i = Math.floor(sig.length / 2);
      parts[2] = sig.slice(0, i) + (sig[i] === 'A' ? 'B' : 'A') + sig.slice(i + 1);
      payload.session.access_token = parts.join('.');
    }
    await ctx.addInitScript(([key, value]) => {
      window.localStorage.setItem(key, value);
    }, [payload.storage_key, JSON.stringify(payload.session)]);
  }

  await page.goto(ORIGIN + ROUTE, { waitUntil: 'domcontentloaded', timeout: 45000 });
  // Give the router and the auth bootstrap time to settle.
  await page.waitForTimeout(4500);

  const url = page.url();
  const bodyText = (await page.evaluate(() => document.body.innerText)) || '';
  const html = await page.content();

  const redirectedToLogin = /\/login/.test(url);
  const hasWorkspaceChrome = /Explore|Recommendation|Dashboard|Assessment|Propert/i.test(bodyText);
  const demoBypassVisible = /demo mode|without a login/i.test(bodyText);

  const shot = path.join(OUT, `${name}.png`);
  await page.screenshot({ path: shot, fullPage: false });

  await ctx.close();
  return {
    name,
    final_url: url,
    redirected_to_login: redirectedToLogin,
    body_text_length: bodyText.length,
    body_excerpt: bodyText.replace(/\s+/g, ' ').slice(0, 220),
    has_workspace_chrome: hasWorkspaceChrome,
    demo_bypass_visible: demoBypassVisible,
    html_length: html.length,
    api_calls: apiCalls.slice(0, 12),
    console_errors: consoleErrors.slice(0, 8),
    screenshot: path.relative(path.join(__dirname, '..', '..'), shot),
  };
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const session = loadSession();
  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-sandbox', '--no-proxy-server'],
  });

  const results = [];
  results.push(await probe(browser, { name: 'A_no_session', session: null }));
  results.push(await probe(browser, { name: 'B_genuine_session', session }));
  results.push(await probe(browser, { name: 'C_tampered_token', session, tamper: true }));

  await browser.close();

  const report = {
    artifact: 'PROJECT1_P3_AUTH_BROWSER_E2E_RESULTS',
    origin: ORIGIN,
    route: ROUTE,
    identity: {
      email: session.email,
      user_id: session.user_id,
      token_alg: session.token_alg,
      token_kid: session.token_kid,
    },
    controls: results,
  };
  const outFile = path.join(OUT, 'results.json');
  fs.writeFileSync(outFile, JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
})().catch((e) => {
  console.error('PROBE FAILED:', e.message);
  process.exit(1);
});
