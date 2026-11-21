/* Authenticated structural + visual verification of the simplified score tab.
 *
 * Creates one temporary email-confirmed Supabase identity (service key read
 * from FYP/backend/.env at run time, never shipped to the browser), signs in
 * through the real Jaspr auth bridge, then verifies the compact SHAP
 * explanation on /entrepreneur/property-detail at desktop and mobile widths.
 * A finally block deletes the identity and any profile rows it created.
 */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { chromium } = require('playwright-core');

const BASE = process.env.BASE || 'http://127.0.0.1:8090';
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1243/chrome-win64/chrome.exe';
const backendDir = path.resolve(__dirname, '..', '..', 'backend');
const pythonExe = path.join(backendDir, '.venv', 'Scripts', 'python.exe');
const OUT = path.join(__dirname, '..', '_shots');

function envValue(text, name) {
  const m = new RegExp('^' + name + '=(.*)$', 'm').exec(text);
  return m ? m[1].trim().replace(/^["']|["']$/g, '') : '';
}
const envText = fs.readFileSync(path.join(backendDir, '.env'), 'utf8');
const SUPA = envValue(envText, 'SUPABASE_URL').replace(/\/+$/, '');
const ADMIN = envValue(envText, 'SUPABASE_SECRET_KEY');
const DB_URL = envValue(envText, 'DATABASE_URL').replace('postgresql+psycopg2://', 'postgresql://');
const adminHeaders = { apikey: ADMIN, Authorization: 'Bearer ' + ADMIN, 'Content-Type': 'application/json' };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function adminFetch(pathname, init = {}) {
  return fetch(SUPA + pathname, {
    ...init,
    headers: { ...adminHeaders, ...(init.headers || {}) },
    signal: AbortSignal.timeout(15000),
  });
}
function deleteLocalUser(id) {
  try {
    execFileSync(pythonExe, ['-c',
      'import psycopg2,sys;c=psycopg2.connect(sys.argv[1]);q=c.cursor();q.execute("delete from users where user_id=%s",(sys.argv[2],));c.commit();print(q.rowcount);c.close()',
      DB_URL, id], { encoding: 'utf8' });
  } catch (e) { console.log('  cleanup: local profile delete failed:', String(e.message).slice(0, 120)); }
}

(async () => {
  const email = `sitewise.probe.${crypto.randomUUID().slice(0, 8)}@example.com`;
  const password = 'Pr0be-' + crypto.randomBytes(9).toString('hex');
  let userId = null;
  let browser = null;
  const results = { errors: [] };

  try {
    const created = await adminFetch('/auth/v1/admin/users', {
      method: 'POST',
      body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { full_name: 'Sitewise Probe' } }),
    });
    const body = await created.json().catch(() => ({}));
    userId = body.id || body.sub || (body.user && body.user.id) || null;
    if (!userId) throw new Error('identity create failed ' + created.status + ': ' + JSON.stringify(body).slice(0, 300));

    browser = await chromium.launch({ executablePath: EXE, args: ['--no-proxy-server', '--no-sandbox'] });
    const page = await browser.newPage({ viewport: { width: 1440, height: 950 } });
    page.on('pageerror', (e) => results.errors.push('pageerror: ' + e.message.slice(0, 200)));
    page.on('console', (m) => {
      if (m.type() === 'error') results.errors.push('console: ' + m.text().slice(0, 200));
    });

    await page.goto(BASE + '/login', { waitUntil: 'networkidle', timeout: 60000 });
    await page.waitForFunction(() => !!window.sitewiseAuth, null, { timeout: 15000 });
    await page.waitForFunction(() => JSON.parse(window.sitewiseAuth.snapshot()).configured === true, null, { timeout: 15000 });
    const signIn = await page.evaluate(async ({ email, password }) => {
      try { await window.sitewiseAuth.password(email, password, false, ''); return 'OK'; }
      catch (e) { return String(e.message || e); }
    }, { email, password });
    results.signIn = signIn;
    await page.waitForURL('**/entrepreneur**', { timeout: 20000 }).catch(() => {});
    await sleep(1000);

    // --- desktop ------------------------------------------------------------
    await page.goto(BASE + '/entrepreneur/property-detail?id=MD-01755', { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3500);
    await page.locator('#sw-info-tab-score').click({ timeout: 20000 });
    await page.waitForTimeout(2000);

    results.heading = (await page.locator('.sw-info__intro h3').textContent().catch(() => 'MISSING')).trim();
    results.fit = await page.locator('.sw-fit').count();
    results.fitTitle = (await page.locator('.sw-fit__title').textContent().catch(() => 'MISSING')).trim();
    results.fitExplain = (await page.locator('.sw-fit__explain').textContent().catch(() => 'MISSING')).trim();
    results.fitAudit = (await page.locator('.sw-fit__audit').textContent().catch(() => '')).trim();
    results.fitWarn = await page.locator('.sw-fit__warn').count();
    results.explain = await page.locator('.sw-explain').count();
    results.explainTitle = (await page.locator('.sw-explain__title').textContent().catch(() => 'MISSING')).trim();
    results.cols = await page.locator('.sw-explain__col').count();
    results.colTitles = await page.locator('.sw-explain__col-title').allTextContents();
    results.items = await page.locator('.sw-explain__item').count();
    results.itemLabels = await page.locator('.sw-explain__item-label').allTextContents();
    results.itemWhys = await page.locator('.sw-explain__item-why').allTextContents();
    results.itemAria = await page.locator('.sw-explain__item').evaluateAll((els) => els.map((e) => e.getAttribute('aria-label') || ''));
    results.bars = await page.locator('.sw-explain__bar').count();
    results.showAllButton = await page.getByText('Show all', { exact: false }).count();
    results.topicTabs = await page.locator('.sw-cats').count();
    results.technicalDetails = await page.locator('.sw-shap__tech').count();
    results.rawShapNumbers = await page.locator('.sw-explain__item-why', { hasText: /0\.\d{3}/ }).count();
    results.disclaimer = (await page.locator('.sw-pd__insights > p.sw-pd__footnote').textContent().catch(() => 'MISSING')).trim();
    results.desktopColTracks = await page.locator('.sw-explain__cols').evaluate((el) => getComputedStyle(el).gridTemplateColumns.split(' ').length);
    await page.locator('.sw-explain').scrollIntoViewIfNeeded();
    await page.screenshot({ path: path.join(OUT, 'score_tab_compact.png') });

    // --- mobile -------------------------------------------------------------
    await page.setViewportSize({ width: 375, height: 820 });
    await page.waitForTimeout(600);
    results.mobileColTracks = await page.locator('.sw-explain__cols').evaluate((el) => getComputedStyle(el).gridTemplateColumns.split(' ').length);
    await page.locator('.sw-explain').scrollIntoViewIfNeeded();
    await page.screenshot({ path: path.join(OUT, 'score_tab_compact_mobile.png') });

    results.jsErrors = results.errors.filter(
      (e) => !e.includes('favicon') && !e.includes('net::') && !e.includes('404'),
    );
    delete results.errors;
    console.log(JSON.stringify(results, null, 2));
  } finally {
    if (browser) await browser.close().catch(() => {});
    if (userId) {
      try {
        const res = await adminFetch('/rest/v1/users?user_id=eq.' + userId, { method: 'DELETE' });
        console.log(`cleanup: supabase public.users row -> ${res.status}`);
      } catch (e) { console.log('cleanup: public.users delete failed:', String(e.message).slice(0, 100)); }
      deleteLocalUser(userId);
      try {
        const res = await adminFetch('/auth/v1/admin/users/' + userId, { method: 'DELETE' });
        console.log(`cleanup: auth user deleted -> ${res.status}`);
      } catch (e) { console.log('cleanup: auth user delete failed:', String(e.message).slice(0, 100)); }
    }
  }
})().catch((e) => {
  console.error('PROBE_FAILED', e.message || e);
  process.exit(1);
});
