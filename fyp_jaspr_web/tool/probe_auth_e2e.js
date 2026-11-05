// End-to-end authentication check against the REAL intended backend.
//
// Creates one temporary, email-confirmed Supabase test identity with the
// service-role key (read from FYP/backend/.env at run time, never shipped to
// the browser), signs in through the real Jaspr auth bundle, verifies the
// /api/v1/auth/me round trip and catalogue access through the same-origin
// proxy, checks session restoration on refresh, then signs out.
//
// A `finally` block ALWAYS deletes the test identity and any profile rows it
// created (Supabase public.users + local sitesense.users), then verifies the
// original row counts are restored. Existing real users are never modified.
//
// Usage:
//   BASE=http://127.0.0.1:8090 NODE_PATH=<managed node workspace> \
//     node tool/probe_auth_e2e.js
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { chromium } = require('playwright-core');

const BASE = process.env.BASE || 'http://127.0.0.1:8090';
const EXE = process.env.CHROME_PATH ||
  'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const backendDir = path.resolve(__dirname, '..', '..', 'backend');
const pythonExe = path.join(backendDir, '.venv', 'Scripts', 'python.exe');

function envValue(text, name) {
  const m = new RegExp('^' + name + '=(.*)$', 'm').exec(text);
  return m ? m[1].trim().replace(/^["']|["']$/g, '') : '';
}
const envText = fs.readFileSync(path.join(backendDir, '.env'), 'utf8');
const SUPA = envValue(envText, 'SUPABASE_URL').replace(/\/+$/, '');
const ADMIN = envValue(envText, 'SUPABASE_SECRET_KEY');
const DB_URL = envValue(envText, 'DATABASE_URL').replace('postgresql+psycopg2://', 'postgresql://');
const adminHeaders = { apikey: ADMIN, Authorization: 'Bearer ' + ADMIN, 'Content-Type': 'application/json' };

const checks = [];
const ok = (name, cond, detail = '') => {
  checks.push({ name, pass: !!cond, detail: String(detail).slice(0, 220) });
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function adminFetch(pathname, init = {}) {
  return fetch(SUPA + pathname, {
    ...init,
    headers: { ...adminHeaders, ...(init.headers || {}) },
    signal: AbortSignal.timeout(15000),
  });
}
async function supaUserCount() {
  try {
    const rows = await (await adminFetch('/rest/v1/users?select=user_id')).json();
    return Array.isArray(rows) ? rows.length : -1;
  } catch { return -1; }
}
function localUserCount() {
  try {
    return execFileSync(pythonExe, ['-c',
      'import psycopg2,sys;c=psycopg2.connect(sys.argv[1]);q=c.cursor();q.execute("select count(*) from users");print(q.fetchone()[0]);c.close()',
      DB_URL], { encoding: 'utf8' }).trim();
  } catch { return 'error'; }
}
function deleteLocalUser(id) {
  try {
    execFileSync(pythonExe, ['-c',
      'import psycopg2,sys;c=psycopg2.connect(sys.argv[1]);q=c.cursor();q.execute("delete from users where user_id=%s",(sys.argv[2],));c.commit();print(q.rowcount);c.close()',
      DB_URL, id], { encoding: 'utf8' });
  } catch (e) { console.log('  cleanup: local profile delete failed:', String(e.message).slice(0, 120)); }
}

(async () => {
  const beforeSupa = await supaUserCount();
  const beforeLocal = localUserCount();
  console.log(`baseline: supabase public.users=${beforeSupa}, sitesense.users=${beforeLocal}`);

  const email = `sitewise.probe.${crypto.randomUUID().slice(0, 8)}@example.com`;
  const password = 'Pr0be-' + crypto.randomBytes(9).toString('hex');
  let userId = null;
  let browser;
  let blocked = null;

  try {
    // --- Create an isolated, email-confirmed test identity -----------------
    const created = await adminFetch('/auth/v1/admin/users', {
      method: 'POST',
      body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { full_name: 'Sitewise Probe' } }),
    });
    const body = await created.json().catch(() => ({}));
    userId = body.id || body.sub || (body.user && body.user.id) || null;
    if (!userId) {
      // The live Supabase project currently refuses new auth.users rows:
      // its public.users protection trigger raises P0001 on the provisioning
      // insert. This is a project-side configuration issue, NOT a frontend
      // integration fault. Report it precisely and never claim a pass.
      blocked = `admin API ${created.status}: ${JSON.stringify(body).slice(0, 300)}`;
      throw new Error('__BLOCKED__'); // `finally` still cleans up / verifies counts
    }
    ok('temporary test identity created', true);

    // --- Sign in through the real browser bridge ---------------------------
    browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    const pageErrors = [];
    const badHosts = [];
    page.on('pageerror', (e) => pageErrors.push(e.message));
    page.on('request', (r) => { if (/:8000|:3001/.test(r.url())) badHosts.push(r.url()); });

    await page.goto(BASE + '/login', { waitUntil: 'networkidle', timeout: 60000 });
    await page.waitForFunction(() => !!window.sitewiseAuth, null, { timeout: 15000 });
    await page.waitForFunction(() => JSON.parse(window.sitewiseAuth.snapshot()).configured === true, null, { timeout: 15000 });

    const signIn = await page.evaluate(async ({ email, password }) => {
      try {
        await window.sitewiseAuth.password(email, password, false, '');
        return 'OK';
      } catch (e) { return String(e.message || e); }
    }, { email, password });
    ok('real password sign-in succeeded',
      signIn === 'OK' || /navigation|context was destroyed/i.test(signIn), signIn);

    let landed = true;
    try { await page.waitForURL('**/entrepreneur**', { timeout: 20000 }); }
    catch { landed = false; }
    ok('active entrepreneur routed to /entrepreneur', landed, page.url());

    // --- Authoritative profile from the intended backend -------------------
    await sleep(1200);
    const profile = await page.evaluate(async () => {
      try {
        const snap = JSON.parse(window.sitewiseAuth.snapshot());
        const raw = await window.sitewiseAuth.request('/api/v1/auth/me', 'GET', '');
        return { snap, me: JSON.parse(raw) };
      } catch (e) { return { error: String(e.message || e) }; }
    });
    ok('GET /api/v1/auth/me returns verified profile',
      profile.me?.user_id === userId, JSON.stringify(profile.me || profile.error).slice(0, 200));
    ok('server-assigned role and status are entrepreneur/active',
      profile.me?.role === 'entrepreneur' && profile.me?.account_status === 'active',
      `${profile.me?.role}/${profile.me?.account_status}`);
    ok('no client-side role escalation', !profile.me?.source?.includes('fallback'));

    const catalog = await page.evaluate(async () => {
      try {
        return JSON.parse(await window.sitewiseAuth.request('/api/v1/catalog/properties?limit=2&offset=0', 'GET', ''));
      } catch (e) { return { error: String(e.message || e) }; }
    });
    ok('authenticated catalogue read through intended backend',
      Array.isArray(catalog.data) && catalog.data.length === 2 && catalog.meta?.total === 2126,
      JSON.stringify(catalog).slice(0, 160));

    // --- Session survives a full document refresh (SSR guard + cookies) ----
    await page.reload({ waitUntil: 'networkidle', timeout: 60000 });
    await sleep(1500);
    ok('refresh preserves authenticated session',
      new URL(page.url()).pathname.startsWith('/entrepreneur'), page.url());
    const restored = await page.evaluate(() => {
      try { return JSON.parse(window.sitewiseAuth.snapshot()); } catch { return {}; }
    });
    ok('profile restored after refresh', !!restored.profile && restored.profile.role === 'entrepreneur',
      JSON.stringify(restored.profile || restored.error).slice(0, 160));

    // --- Unauthorized workspace is refused ---------------------------------
    await page.goto(BASE + '/admin', { waitUntil: 'networkidle', timeout: 60000 });
    await sleep(600);
    ok('role boundary: entrepreneur cannot enter /admin',
      !new URL(page.url()).pathname.startsWith('/admin'), page.url());

    // --- Logout -------------------------------------------------------------
    await page.goto(BASE + '/entrepreneur', { waitUntil: 'networkidle', timeout: 60000 });
    await sleep(800);
    await page.evaluate(async () => window.sitewiseAuth.signout());
    await page.waitForURL('**/login**', { timeout: 20000 });
    ok('logout redirects to /login', new URL(page.url()).pathname.startsWith('/login'), page.url());
    const afterLogout = await page.evaluate(() => document.cookie);
    ok('logout clears SSR session cookies', !/sitewise_session=|sitewise_token=/.test(afterLogout), afterLogout);

    ok('browser never contacted :8000 or :3001 directly', badHosts.length === 0, badHosts.join(','));
    ok('no uncaught page errors', pageErrors.length === 0, pageErrors.join(' | '));
    await browser.close();
    browser = null;
  } catch (e) {
    if (e.message !== '__BLOCKED__') {
      console.error('PROBE ERROR in auth flow:', e);
      process.exitCode = 2;
    }
  } finally {
    if (browser) { await browser.close().catch(() => {}); }
    if (userId) {
      // Remove any Supabase public.users row created by a provisioning trigger.
      try {
        const res = await adminFetch('/rest/v1/users?user_id=eq.' + userId, { method: 'DELETE' });
        console.log(`  cleanup: supabase public.users row -> ${res.status}`);
      } catch (e) { console.log('  cleanup: public.users delete failed:', String(e.message).slice(0, 100)); }
      deleteLocalUser(userId);
      try {
        const res = await adminFetch('/auth/v1/admin/users/' + userId, { method: 'DELETE' });
        console.log(`  cleanup: auth user deleted -> ${res.status}`);
        ok('temporary test identity deleted', res.status === 200 || res.status === 204, res.status);
      } catch (e) { ok('temporary test identity deleted', false, String(e.message)); }
    }
    await sleep(500);
    const afterSupa = await supaUserCount();
    const afterLocal = localUserCount();
    console.log(`after cleanup: supabase public.users=${afterSupa}, sitesense.users=${afterLocal}`);
    ok('Supabase public.users row count restored', afterSupa === beforeSupa, `${beforeSupa} -> ${afterSupa}`);
    ok('local sitesense.users row count restored', String(afterLocal) === String(beforeLocal), `${beforeLocal} -> ${afterLocal}`);
  }

  if (blocked) {
    console.log('\nBLOCKED: credential-based sign-in could not be executed.');
    console.log('  ' + blocked);
    console.log('  Cause: the live Supabase project\'s public.users protection trigger');
    console.log('         rejects the auth.users provisioning insert (P0001).');
    console.log('  Not verified here: real sign-in, /auth/me round trip, session refresh, logout.');
    console.log('  Remaining rows were restored (see cleanup lines above).');
    process.exit(3);
  }

  const passed = checks.filter((c) => c.pass).length;
  for (const c of checks) {
    console.log(`${c.pass ? 'PASS' : 'FAIL'}  ${c.name}${c.pass || !c.detail ? '' : '  -> ' + c.detail}`);
  }
  console.log(`\n${passed}/${checks.length} checks passed`);
  process.exit(passed === checks.length ? 0 : 1);
})().catch((e) => { console.error('PROBE ERROR', e); process.exit(2); });
