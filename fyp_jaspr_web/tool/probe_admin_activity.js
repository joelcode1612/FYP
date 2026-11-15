// Headless probe for the rebuilt /admin/activity (System Activity) page.
//
// The security-audit endpoint is stubbed at the network level with a
// deterministic fixture, so every interaction below is checked against
// KNOWN data: tabs fire server queries with the right query string,
// pagination pages through real totals, the details dialog shows the
// fixture's fields, and the CSV export downloads authorized rows only.
//
// Usage: node tool/probe_admin_activity.js [baseUrl]
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = process.argv[2] || 'http://127.0.0.1:8090';

const ADMIN = {
  sources: {
    administrative: { available: true, detail: 'Existing public.role_change_audit feed.' },
    authentication: {
      available: false,
      detail:
        'auth.audit_log_entries is not reachable through this backend: the Supabase PostgREST API does not expose the auth schema (default db-schemas are public + storage) and no direct database connection is configured.',
    },
    mfa: {
      available: false,
      detail:
        'Administrator MFA actions (factor resets) come from the existing staff audit feed; Supabase-side MFA verification events are not available on this deployment.',
    },
  },
  events: [
    adminEv('e1', 'staff.suspended', 'Account suspended', 'agent@sitewise.test', 'Agent', 'admin@sitewise.test', '2026-11-15T09:00:00Z', { new_status: 'suspended' }),
    authAdminEv('e2', 'staff.mfa_factor_reset', 'MFA factor reset (administrator)', 'agent@sitewise.test', 'admin@sitewise.test', '2026-11-15T08:12:00Z'),
    adminEv('e3', 'listing.assigned', 'Listing assigned to agent', 'agent@sitewise.test', 'Agent', 'admin@sitewise.test', '2026-11-15T07:45:00Z', {}),
    adminEv('e4', 'staff.invited', 'Agent invitation sent', 'newagent@sitewise.test', null, 'admin@sitewise.test', '2026-11-14T16:20:00Z', {}),
    authAdminEv('e5', 'staff.mfa_factor_reset', 'MFA factor reset (administrator)', 'agent2@sitewise.test', 'admin@sitewise.test', '2026-11-14T11:05:00Z'),
    adminEv('e6', 'company.registered', 'Company registered', '', null, 'admin@sitewise.test', '2026-11-13T10:00:00Z', {}),
  ],
  total: 32,
  page: 1,
  page_size: 25,
  notes: [
    'No failed authentication events are shown: GoTrue writes audit entries on success only, so failed sign-ins and failed MFA verifications are not recorded by the auth source.',
  ],
};

const PAGE2 = {
  ...ADMIN,
  events: Array.from({ length: 7 }, (_, i) =>
    adminEv(`p2-${i + 1}`, 'staff.activated', 'Account activated', `agent${i + 1}@sitewise.test`, 'Agent', 'admin@sitewise.test', `2026-11-1${i}T09:00:00Z`, {}),
  ),
  page: 2,
};

const AUTH_ONLY = { ...ADMIN, events: [], total: 0, page: 1 };

function adminEv(id, action, title, email, role, by, when, details) {
  return {
    id: `admin:${id}:${when}`,
    category: action.includes('mfa') ? 'mfa' : 'admin',
    action,
    title,
    summary: 'Administrative action recorded by the SiteWise staff audit feed when the operation completed.',
    affected_email: email,
    affected_user_id: `uid-${id}`,
    performed_by_email: by,
    performed_by_user_id: 'uid-admin',
    role,
    created_at: when,
    result: 'success',
    source: 'SiteWise staff audit',
    details,
  };
}
function authAdminEv(id, action, title, email, by, when) {
  return adminEv(id, action, title, email, 'Agent', by, when, {});
}

(async () => {
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox', '--no-proxy-server'] });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, acceptDownloads: true });
  let pass = 0;
  let fail = 0;
  const check = (name, ok, extra = '') => {
    if (ok) pass++;
    else {
      fail++;
      console.log(`  FAIL: ${name}${extra ? ' — ' + extra : ''}`);
    }
  };

  const page = await ctx.newPage();
  await installHarnessSession(page, { role: 'admin' });

  const requests = [];
  // Registered AFTER the harness's generic /api/** handler so this wins.
  await page.route('**/api/v1/staff/audit/security**', async (route) => {
    const url = new URL(route.request().url());
    const q = url.searchParams;
    requests.push(Object.fromEntries(q.entries()));
    const respond = (body) =>
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
    if (q.get('page') === '2') return respond(PAGE2);
    if (q.get('category') === 'auth') return respond(AUTH_ONLY);
    return respond(ADMIN);
  });

  await page.goto(BASE + '/admin/activity', { waitUntil: 'networkidle', timeout: 30000 });
  await page.waitForTimeout(1200);

  // 1-3. Route + header + navigation entry.
  check('route loads with the page heading', (await page.locator('h1').first().textContent()) === 'System activity');
  const navLink = page.locator('.app-pill a[href*="/admin/activity"]');
  check('nav pill contains the System Activity link', (await navLink.count()) === 1);
  check(
    'nav link text is System Activity',
    ((await navLink.first().textContent()) || '').includes('System Activity'),
  );
  check('Refresh action present', (await page.getByRole('button', { name: 'Refresh' }).count()) >= 1);
  check('Export CSV action present', (await page.getByRole('button', { name: 'Export CSV' }).count()) >= 1);

  // 4-6. Source strip reflects the REAL probe status from the fixture.
  check('three source cards render', (await page.locator('.act-source').count()) === 3);
  const chips = await page.locator('.act-source .act-chip').allTextContents();
  check('admin source chip reads Available', chips[0] === 'Available');
  check('auth source chip reads Not available', chips[1] === 'Not available');
  check('mfa source chip reads Not available', chips[2] === 'Not available');
  const srcText = await page.locator('.act-source').nth(1).textContent();
  check('auth source detail names auth.audit_log_entries', srcText.includes('auth.audit_log_entries'));

  // 7. Table renders the fixture rows.
  check('six fixture rows render', (await page.locator('.audit-table tbody tr').count()) === 6);
  check('first row title', (await page.locator('.audit-table tbody tr').first().textContent()).includes('Account suspended'));
  check('result badge text', (await page.locator('.audit-table .st').first().textContent()).includes('Successful'));

  // 8. Tabs drive server-side category queries.
  await page.getByRole('button', { name: 'Authentication' }).click();
  await page.waitForTimeout(600);
  const authReq = requests.findLast((r) => r.category === 'auth');
  check('Authentication tab sends category=auth', authReq && authReq.category === 'auth');
  check('auth tab shows the honest empty state', (await page.locator('.ops-empty').count()) === 1);

  // 9. Search is debounced and reaches the server.
  await page.getByRole('button', { name: 'All activity' }).click();
  await page.fill('input[type="search"]', 'suspended');
  await page.waitForTimeout(700);
  const searchReq = requests.findLast((r) => r.search === 'suspended');
  check('search reaches the server as search=suspended', Boolean(searchReq));

  // 10. Filters update the query.
  await page.locator('.act-filters select').first().selectOption('failed');
  await page.waitForTimeout(600);
  check('result filter reaches the server', requests.findLast((r) => r.result === 'failed') !== undefined);
  await page.locator('.act-filters select').nth(1).selectOption('agent');
  await page.waitForTimeout(600);
  check('role filter reaches the server', requests.findLast((r) => r.role === 'agent') !== undefined);
  await page.locator('.act-filters select').nth(2).selectOption('7d');
  await page.waitForTimeout(600);
  const dateReq = requests.findLast((r) => r.date_from);
  check('date filter sends a date_from', Boolean(dateReq && dateReq.date_from.startsWith('20')));

  // 11. Pagination walks real totals.
  await page.selectOption('.act-filters select >> nth=0', 'all');
  await page.locator('.act-filters select >> nth=1').selectOption('all');
  await page.locator('.act-filters select >> nth=2').selectOption('all');
  await page.fill('input[type="search"]', '');
  await page.waitForTimeout(700);
  const info = await page.locator('.act-pageinfo').textContent();
  check('page info shows Showing 1–25 of 32', info.includes('Showing 1–25 of 32'), info || '');
  check('two page buttons render', (await page.locator('.act-pagebtn').count()) === 4); // prev + 2 + next
  await page.locator('.act-pagebtn', { hasText: '2' }).last().click();
  await page.waitForTimeout(700);
  check('page 2 requested', requests.some((r) => r.page === '2'));
  check('page 2 renders 7 rows', (await page.locator('.audit-table tbody tr').count()) === 7);

  // 12. Details dialog.
  await page.locator('.act-pagebtn').first().click();
  await page.waitForTimeout(600);
  await page.locator('.audit-table tbody tr').first().getByRole('button', { name: 'View' }).click();
  await page.waitForTimeout(400);
  const dialog = page.locator('[role="dialog"]');
  check('details dialog opens', (await dialog.count()) === 1);
  const dlgText = (await dialog.textContent()) || '';
  check('dialog shows the event id', dlgText.includes('admin:e1:'));
  check('dialog shows performed-by attribution', dlgText.includes('admin@sitewise.test'));
  check('dialog shows the source', dlgText.includes('SiteWise staff audit'));
  check('no secret-looking keys leak', !/password|otp|secret|recovery_code/i.test(dlgText));
  await page.keyboard.press('Escape');
  await page.waitForTimeout(300);
  check('Escape closes the dialog', (await page.locator('[role="dialog"]').count()) === 0);

  // 13. CSV export downloads authorized rows only.
  const downloadPromise = page.waitForEvent('download', { timeout: 10000 });
  await page.getByRole('button', { name: 'Export CSV' }).click();
  const download = await downloadPromise;
  check('csv download fires', Boolean(download));
  check('csv filename', download.suggestedFilename() === 'sitewise-system-activity.csv');
  const stream = await download.createReadStream();
  const csv = (await new Promise((res) => {
    let buf = '';
    stream.on('data', (d) => (buf += d.toString()));
    stream.on('end', () => res(buf));
  }));
  check('csv has the header row', csv.includes('"Event ID"'));
  check('csv includes only page-1 authorized rows (6)', csv.trim().split('\n').length === 7);
  const note = await page.locator('.callout').last().textContent();
  check('export note states the row count', (note || '').includes('6 authorized events'));

  // 14. Backend failure state is honest.
  await page.unrouteAll({ behavior: 'ignoreErrors' });
  await page.route('**/api/v1/staff/audit/security**', (route) =>
    route.fulfill({ status: 502, contentType: 'application/json', body: JSON.stringify({ detail: 'Audit read failed: upstream down' }) }),
  );
  await page.getByRole('button', { name: 'Refresh' }).click();
  await page.waitForTimeout(800);
  const errText = await page.locator('.callout-danger').first().textContent();
  check('failure shows the server sentence', (errText || '').includes('upstream down'));
  check('failure offers Try again', (await page.getByRole('button', { name: 'Try again' }).count()) === 1);

  // 15. Mobile drawer reachability (nav entry at drawer width).
  const mctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const mpage = await mctx.newPage();
  await installHarnessSession(mpage, { role: 'admin' });
  await mpage.route('**/api/v1/staff/audit/security**', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(ADMIN) }),
  );
  await mpage.goto(BASE + '/admin/activity', { waitUntil: 'networkidle', timeout: 30000 });
  await mpage.waitForTimeout(1200);
  const burger = mpage.locator('.topbar__burger');
  if ((await burger.count()) === 1) {
    await burger.click();
    await mpage.waitForTimeout(400);
    check('mobile drawer lists System Activity', (await mpage.locator('a[href*="/admin/activity"]').count()) >= 1);
  } else {
    check('mobile drawer reachable', false, 'no burger found');
  }
  const overflow = await mpage.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  check('no horizontal overflow at 390px', overflow <= 2, `delta=${overflow}`);

  console.log(`\nPASS ${pass}  FAIL ${fail}`);
  await browser.close();
  process.exit(fail === 0 ? 0 : 1);
})().catch((e) => {
  console.error('probe crashed:', e);
  process.exit(1);
});
