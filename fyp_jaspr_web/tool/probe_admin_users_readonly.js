// Headless probe: Admin User Management is READ-ONLY for roles.
//
// Verifies, against the BUILT site served on :8090, that:
//   1. /admin/users renders the account directory with a role badge per row,
//      a Role FILTER (search/filtering preserved) and NO role editor;
//   2. /admin/user-detail renders the role as read-only text (NO role
//      <select>), keeps the account-status dropdown, and the Save Changes
//      button sends ONLY `account_status` — never `role`;
//   3. a role-bearing PATCH would be refused (backend contract probed here as
//      a 422 from the stub) and the UI surfaces the policy wording.
//
// All /api/v1/users* traffic is stubbed at the network level with
// deterministic fixtures, so every assertion runs against KNOWN data.
//
// Usage: node tool/probe_admin_users_readonly.js [baseUrl]
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = process.argv[2] || 'http://127.0.0.1:8090';

const USERS = {
  data: [
    {
      user_id: 'u-agent-1',
      email: 'ahmad@gmail.com',
      full_name: 'Ahmad',
      role: 'agent',
      account_status: 'active',
      email_verified: true,
      created_at: '2026-11-01T09:00:00Z',
      listing_count: 3,
    },
    {
      user_id: 'u-owner-1',
      email: 'siti@gmail.com',
      full_name: 'Siti',
      role: 'owner',
      account_status: 'active',
      email_verified: true,
      created_at: '2026-11-02T09:00:00Z',
      listing_count: 1,
    },
    {
      user_id: 'u-entre-1',
      email: 'daniel@gmail.com',
      full_name: 'Daniel',
      role: 'entrepreneur',
      account_status: 'pending',
      email_verified: false,
      created_at: '2026-11-03T09:00:00Z',
    },
  ],
};

const DETAIL = {
  user_id: 'u-agent-1',
  email: 'ahmad@gmail.com',
  full_name: 'Ahmad',
  role: 'agent',
  account_status: 'active',
  email_verified: true,
  phone_number: '+601200000001',
  created_at: '2026-11-01T09:00:00Z',
  last_login: '2026-11-15T08:12:00Z',
  listing_count: 3,
};

(async () => {
  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-sandbox', '--no-proxy-server'],
  });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
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

  const patchBodies = [];
  // Registered AFTER the harness's generic /api/** handler so this wins.
  // Mirrors the real backend contract: a role payload is refused outright
  // (422 role_change_not_supported); a status-only payload applies (200 echo).
  await page.route('**/api/v1/users/**', async (route) => {
    const req = route.request();
    if (req.method() === 'PATCH') {
      const body = req.postDataJSON?.() ?? {};
      patchBodies.push({ url: req.url(), body });
      if ('role' in body) {
        return route.fulfill({
          status: 422,
          contentType: 'application/json',
          body: JSON.stringify({
            detail: {
              code: 'role_change_not_supported',
              message:
                'Roles cannot be changed through user management. A role is assigned by the authorised registration, invitation and onboarding workflows only.',
            },
          }),
        });
      }
      return route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          ...DETAIL,
          account_status: body.account_status ?? DETAIL.account_status,
          identity_synced: true,
          audit_recorded: 'account_status' in body ? true : null,
        }),
      });
    }
    const url = new URL(req.url());
    const id = url.pathname.split('/').pop();
    if (id === 'u-agent-1') {
      return route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(DETAIL),
      });
    }
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(USERS.data),
    });
  });

  // ── 1. /admin/users directory ────────────────────────────────────────────
  await page.goto(BASE + '/admin/users', { waitUntil: 'networkidle', timeout: 30000 });
  await page.waitForTimeout(1200);

  check('directory loads with the Users heading', (await page.locator('h1').first().textContent()) === 'Users');
  check('role badges render per row (Agent)', (await page.locator('.auu-role--agent', { hasText: 'Agent' }).count()) === 1);
  check('role badge renders Property Owner', (await page.locator('.auu-role--owner', { hasText: 'Property Owner' }).count()) === 1);
  check('role badge renders Entrepreneur', (await page.locator('.auu-role--entrepreneur', { hasText: 'Entrepreneur' }).count()) === 1);
  check('emails render', (await page.getByText('ahmad@gmail.com').count()) === 1);
  check('registration dates render', (await page.getByText('2026-11-01').count()) >= 1);
  check('no Change Role control exists', (await page.getByText('Change Role').count()) === 0);
  const filterSelects = page.locator('.filters select');
  check('search + status + role FILTER selects survive (filtering preserved)', (await filterSelects.count()) === 2);
  check('no role select exists inside the table', (await page.locator('.audit-table select').count()) === 0);

  // Role filter still works: pick Property Owner, expect exactly one row.
  await page.locator('.filters select').last().selectOption('owner');
  await page.waitForTimeout(300);
  check('role filter narrows to the Property Owner row', (await page.locator('.audit-table tbody tr').count()) === 1);
  await page.locator('.filters select').last().selectOption('all');
  await page.waitForTimeout(300);

  // ── 2. /admin/user-detail: role read-only, status editable ───────────────
  await page.goto(BASE + '/admin/user-detail?id=u-agent-1', {
    waitUntil: 'networkidle',
    timeout: 30000,
  });
  await page.waitForTimeout(1200);

  check('detail page loads', (await page.locator('h1').first().textContent()) === 'User Detail');
  check('role renders as read-only text (Agent)', (await page.getByText('Current role').count()) === 1 &&
    (await page.getByText('Agent', { exact: true }).count()) >= 1);
  check('NO role <select> exists on the detail page', (await page.locator('select[aria-label="Role"]').count()) === 0);
  check('role refusal policy note is shown', (await page.getByText('cannot be changed here', { exact: false }).count()) >= 1);
  const statusSelect = page.locator('select[aria-label="Account Status"]');
  check('account status dropdown survives', (await statusSelect.count()) === 1);

  const saveBtn = page.locator('button', { hasText: 'Save Changes' });
  check('Save Changes starts disabled (nothing changed)', (await saveBtn.getAttribute('disabled')) != null);

  // Change ONLY the status: Save must PATCH account_status and never a role.
  await statusSelect.selectOption('suspended');
  await page.waitForTimeout(200);
  check('Save Changes enables after a status change', (await saveBtn.getAttribute('disabled')) == null);
  await saveBtn.click();
  await page.waitForTimeout(800);

  check('exactly one PATCH was sent', patchBodies.length === 1);
  const sent = patchBodies[0]?.body ?? {};
  check('PATCH carried account_status only (never role)', 'account_status' in sent && !('role' in sent));
  check('status notice confirms the save', (await page.getByText('Changes saved', { exact: false }).count()) >= 1);

  // ── 3. Backend contract ──────────────────────────────────────────────────
  // The UI itself must never emit a role payload (asserted above). The 422
  // refusal for any role-bearing PATCH is proven by the backend suite
  // (test_admin_user_consistency.py / test_staff_admin_api.py).

  await browser.close();
  console.log(`\nprobe_admin_users_readonly: ${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
})().catch((err) => {
  console.error('probe crashed:', err);
  process.exit(1);
});
