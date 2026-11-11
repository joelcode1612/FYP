// Browser verification for the redesigned three-step Admin Agent Invitation
// dialog (/admin/agents).
//
// Everything runs inside the browser: the real auth_bundle.js is replaced by
// a stub `window.sitewiseAuth` bridge that serves fixture data for the staff
// GET endpoints and RECORDS the POST /api/v1/staff/agents payload. No request
// ever leaves the page, so no Supabase identity is provisioned and no
// invitation email is sent.
//
// Checks:
//  1. Anonymous /admin/agents is NOT redirected when the bridge reports an
//     admin profile (guard sanity) — and the page renders the roster.
//  2. "Invite agent" opens a `dialog--invite` panel ~940px wide at 1440px.
//  3. Company assignment AND work email are visible together (step 1,
//     two-column .ag-invite-form grid).
//  4. Existing -> new -> existing company mode switch preserves state.
//  5. Submitting with missing fields stays on step 1 and focuses the first
//     invalid field.
//  6. Email-format validation; duplicate-agent email is flagged inline
//     without submitting.
//  7. Review step shows entered values; Back to details preserves them.
//  8. Exactly ONE POST /api/v1/staff/agents with the preserved payload
//     (company_id, full_name, email, phone_number, allow_existing:false);
//     result step renders the backend response values.
//  9. Escape closes the dialog; footer actions stay inside the viewport.
// 10. At 390px the dialog is single-column and viewport-constrained.
const { chromium } = require('playwright-core');

const BASE = process.env.BASE || 'http://127.0.0.1:8144';

const results = [];
function check(name, ok, detail) {
  results.push({ name, ok, detail: detail || '' });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  [' + detail + ']' : ''}`);
}

// The stub replaces ONLY web/auth_bundle.js; everything else is the real
// built app.
const STUB_BUNDLE = `
(function () {
  const calls = [];
  const agents = [{
    user_id: 'u-1', full_name: 'Aina Rahman', email: 'aina@agency.my',
    phone_number: '+60 12 345 6789', role: 'agent', account_status: 'active',
    agent_profile: { agent_id: 'ag-1', company_id: 11 },
    company: { company_id: 11, company_name: 'Aina Realty Sdn Bhd' },
    created_at: '2026-11-01T09:00:00Z', invitation_status: '', invitation_id: ''
  }];
  const companies = [
    { company_id: 11, company_name: 'Aina Realty Sdn Bhd' },
    { company_id: 12, company_name: 'Borneo Estates' }
  ];
  function route(path, method, bodyJson) {
    const body = bodyJson ? JSON.parse(bodyJson) : null;
    if (method === 'GET' && path.indexOf('/api/v1/staff/overview') === 0) {
      // One request, three reads: the page's current load contract.
      return JSON.stringify({
        agents: agents,
        companies: companies,
        invitations: [{
          invitation_id: 'inv-9', invited_email: 'pending@agency.my',
          invitation_status: 'sent', created_at: '2026-11-05T10:00:00Z',
          sent_at: '2026-11-05T10:00:00Z', expires_at: '2026-11-12T10:00:00Z',
          invited_by_user_id: 'u-admin', invited_user_id: ''
        }],
        summary: { total_agents: 1, active_agents: 1,
          pending_agents: 0, suspended_agents: 0, open_invitations: 1,
          invitations: 1, companies: 2 }
      });
    }
    if (method === 'GET' && path === '/api/v1/saved-properties/me') {
      return JSON.stringify([]);
    }
    if (method === 'GET' && path.indexOf('/api/v1/staff/agents') === 0) {
      return JSON.stringify(agents);
    }
    if (method === 'GET' && path.indexOf('/api/v1/staff/invitations') === 0) {
      return JSON.stringify([{
        invitation_id: 'inv-9', invited_email: 'pending@agency.my',
        invitation_status: 'sent', created_at: '2026-11-05T10:00:00Z',
        sent_at: '2026-11-05T10:00:00Z', expires_at: '2026-11-12T10:00:00Z',
        invited_by_user_id: 'u-admin', invited_user_id: ''
      }]);
    }
    if (method === 'GET' && path.indexOf('/api/v1/staff/companies') === 0) {
      return JSON.stringify(companies);
    }
    if (method === 'GET' && path.indexOf('/api/v1/staff/summary') === 0) {
      return JSON.stringify({ total_agents: 1, active_agents: 1,
        pending_agents: 0, suspended_agents: 0, open_invitations: 1,
        invitations: 1, companies: 2 });
    }
    if (method === 'GET' && path.indexOf('/api/v1/staff/audit') === 0) {
      return JSON.stringify([]);
    }
    if (method === 'POST' && path === '/api/v1/staff/companies') {
      return JSON.stringify({ company_id: 13, company_name: body.company_name });
    }
    if (method === 'POST' && path === '/api/v1/staff/agents') {
      calls.push({ path: path, method: method, body: body });
      return JSON.stringify({
        invited: true, invitation_status: 'sent', email: body.email,
        account_status: 'pending', agent_user_id: 'u-new-1',
        audit_recorded: true
      });
    }
    return JSON.stringify({ detail: 'stub bridge: unhandled ' + method + ' ' + path });
  }
  window.__inviteCalls = calls;
  window.sitewiseAuth = {
    ready: Promise.resolve(),
    snapshot: function () {
      return JSON.stringify({
        configured: true,
        profile: { role: 'admin', email: 'admin@sitewise.test',
                   full_name: 'Test Admin', aal: 'aal2' }
      });
    },
    request: function (path, method, body) {
      return Promise.resolve(route(path || '', method || 'GET', body || ''));
    },
    requestDetailed: function (path, method, body) {
      return Promise.resolve({ ok: true,
        body: JSON.parse(route(path || '', method || 'GET', body || '')) });
    },
    google: function () { return Promise.resolve(); },
    password: function () { return Promise.resolve(); },
    mfaChallengeStart: function () { return Promise.resolve(''); },
    mfaChallengeVerify: function () { return Promise.resolve(); },
    mfaEnrollStart: function () { return Promise.resolve(); },
    mfaEnrollVerify: function () { return Promise.resolve(); },
    resetPassword: function () { return Promise.resolve(''); },
    updatePassword: function () { return Promise.resolve(); },
    signup: function () { return Promise.resolve(''); },
    complete: function () { return Promise.resolve(); },
    signout: function () { return Promise.resolve(); },
    consumePasswordNotice: function () { return null; },
    download: function () { return Promise.resolve(JSON.stringify({ ok: false, message: 'stub' })); },
    requestMultipart: function () { return Promise.resolve(JSON.stringify({})); }
  };
})();
`;

(async () => {
  const browser = await chromium.launch({ args: ['--no-proxy-server'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const pageErrors = [];
  page.on('pageerror', (e) => pageErrors.push('pageerror: ' + e.message));

  await page.route('**/auth_bundle.js', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/javascript',
      body: STUB_BUNDLE,
    }),
  );

  // --- 1. Page loads with the stubbed admin profile -------------------------
  await page.goto(BASE + '/admin/agents', { waitUntil: 'networkidle' });
  await page.waitForTimeout(1200);
  const onAgents = await page.evaluate(() =>
    !!document.querySelector('.ag-stats') &&
    (document.body.textContent || '').indexOf('Agent directory') !== -1,
  );
  check('admin page renders (not redirected to /login)', onAgents);

  // --- 2. Open the invitation dialog ---------------------------------------
  await page.getByRole('button', { name: 'Invite agent' }).first().click();
  await page.waitForSelector('.dialog--invite', { timeout: 5000 });
  await page.waitForTimeout(400);

  const geom = await page.evaluate(() => {
    const d = document.querySelector('.dialog--invite');
    const form = document.querySelector('.ag-invite-form');
    const cols = form ? getComputedStyle(form).gridTemplateColumns : '';
    const footer = d ? d.querySelector('.btn-row') : null;
    const dr = d ? d.getBoundingClientRect() : null;
    const fr = footer ? footer.getBoundingClientRect() : null;
    return {
      width: d ? d.offsetWidth : 0,
      maxWidth: d ? getComputedStyle(d).maxWidth : '',
      cols: cols.split(' ').filter(Boolean).length,
      colTrack: cols,
      sections: document.querySelectorAll('.ag-invite-form__section').length,
      hasCompanyHeading: (document.querySelector('.ag-invite-form__heading') || {}).textContent || '',
      emailVisible: !!(d && Array.from(d.querySelectorAll('input')).some(
        (i) => i.getAttribute('type') !== 'checkbox' && i.offsetParent !== null &&
          (i.placeholder || '').indexOf('@') !== -1)),
      nameVisible: !!(d && Array.from(d.querySelectorAll('input')).some(
        (i) => (i.placeholder || '').indexOf('Aina Rahman') !== -1 && i.offsetParent !== null)),
      companySelect: !!(d && d.querySelector('.ag-invite-form select')),
      footerInViewport: !!(fr && dr && fr.bottom <= window.innerHeight + 1 && fr.height > 0),
      dialogClipped: !!(dr && dr.bottom > window.innerHeight + 1),
    };
  });
  check('dialog--invite panel opens', geom.width > 0, `width=${geom.width}px maxWidth=${geom.maxWidth}`);
  check('desktop width 900-960px', geom.width >= 900 && geom.width <= 961, `${geom.width}px`);
  check('two-column .ag-invite-form grid', geom.cols === 2, geom.colTrack);
  check('both form sections render together', geom.sections === 2, geom.sections + ' sections');
  check('company heading visible', /Company assignment/i.test(geom.hasCompanyHeading));
  check('work email field visible on step 1', geom.emailVisible);
  check('full name field visible on step 1', geom.nameVisible);
  check('existing-company dropdown visible on step 1', geom.companySelect);
  check('footer actions inside viewport', geom.footerInViewport);
  check('no dialog content clipped below viewport', !geom.dialogClipped);

  // --- 4. Mode switch existing -> new -> existing ---------------------------
  await page.getByRole('button', { name: 'New company' }).first().click();
  await page.waitForTimeout(200);
  const newMode = await page.evaluate(() => {
    const d = document.querySelector('.dialog--invite');
    return {
      input: !!Array.from(d.querySelectorAll('input')).find(
        (i) => (i.placeholder || '').indexOf('Aina Realty Sdn Bhd') !== -1),
      selectGone: !d.querySelector('.ag-invite-form select'),
    };
  });
  check('new-company mode shows name input', newMode.input);
  check('new-company mode hides dropdown', newMode.selectGone);
  await page.fill('.ag-invite-form input[placeholder="e.g. Aina Realty Sdn Bhd"]', 'X');
  await page.getByRole('button', { name: 'Existing company' }).first().click();
  await page.waitForTimeout(200);
  const backToExisting = await page.evaluate(
    () => !!document.querySelector('.dialog--invite .ag-invite-form select'),
  );
  check('switch back to existing mode restores dropdown', backToExisting);

  // --- 5. Submit with missing fields -> stays, focuses first invalid --------
  await page.selectOption('.ag-invite-form select', '12');
  await page.getByRole('button', { name: 'Review details' }).click();
  await page.waitForTimeout(300);
  const stillStep1 = await page.evaluate(() => {
    const d = document.querySelector('.dialog--invite');
    const invalid = d.querySelector('[aria-invalid="true"]');
    return {
      onStep1: !!d.querySelector('.ag-invite-form'),
      invalidCount: d.querySelectorAll('[aria-invalid="true"]').length,
      focusedIsInvalid: document.activeElement === invalid,
      focusedTag: document.activeElement ? document.activeElement.tagName : '',
      errorShown: (d.querySelector('.field__error') || {}).textContent || '',
    };
  });
  check('missing fields keep dialog on step 1', stillStep1.onStep1);
  check('invalid fields flagged', stillStep1.invalidCount >= 2, `${stillStep1.invalidCount} invalid`);
  check('focus moved to first invalid field', stillStep1.focusedIsInvalid, stillStep1.focusedTag);
  check('inline validation message visible', stillStep1.errorShown.length > 0, stillStep1.errorShown);

  // --- 6. Email validation + duplicate detection ----------------------------
  await page.fill('.ag-invite-form input[placeholder="e.g. Aina Rahman"]', 'Joel Test');
  await page.fill('.ag-invite-form input[placeholder="name@agency.my"]', 'not-an-email');
  await page.getByRole('button', { name: 'Review details' }).click();
  await page.waitForTimeout(300);
  const badEmail = await page.evaluate(() => {
    const d = document.querySelector('.dialog--invite');
    return {
      onStep1: !!d.querySelector('.ag-invite-form'),
      error: (d.querySelector('.field__error') || {}).textContent || '',
    };
  });
  check('invalid email format rejected on submit', badEmail.onStep1 && /valid email/i.test(badEmail.error), badEmail.error);

  await page.fill('.ag-invite-form input[placeholder="name@agency.my"]', 'aina@agency.my');
  await page.waitForTimeout(200);
  const dup = await page.evaluate(() => {
    const d = document.querySelector('.dialog--invite');
    return (d.querySelector('.field__error') || {}).textContent || '';
  });
  check('duplicate agent email flagged inline (no submit)', /already uses this email|already exists/i.test(dup), dup);

  // --- 7. Review step, back preserves values --------------------------------
  await page.fill('.ag-invite-form input[placeholder="name@agency.my"]', 'joel.test@agency.my');
  await page.fill('.ag-invite-form input[placeholder="+60 12 345 6789"]', '+60 13 999 8888');
  await page.getByRole('button', { name: 'Review details' }).click();
  await page.waitForTimeout(300);
  const review = await page.evaluate(() => {
    const d = document.querySelector('.dialog--invite');
    const text = (d.textContent || '').replace(/\s+/g, ' ');
    return {
      onReview: !d.querySelector('.ag-invite-form'),
      hasName: text.indexOf('Joel Test') !== -1,
      hasEmail: text.indexOf('joel.test@agency.my') !== -1,
      hasCompany: text.indexOf('Borneo Estates') !== -1,
      hasSend: !!Array.from(d.querySelectorAll('button')).find(
        (b) => (b.textContent || '').indexOf('Send invitation') !== -1),
    };
  });
  check('review step reached', review.onReview);
  check('review shows entered name/email/company', review.hasName && review.hasEmail && review.hasCompany,
    `name=${review.hasName} email=${review.hasEmail} company=${review.hasCompany}`);
  check('Send invitation control present on review', review.hasSend);

  await page.getByRole('button', { name: 'Back to details' }).click();
  await page.waitForTimeout(300);
  const preserved = await page.evaluate(() => {
    const d = document.querySelector('.dialog--invite');
    const val = (sel) => {
      const el = d.querySelector(sel);
      return el ? el.value || el.getAttribute('value') || '' : null;
    };
    const sel = d.querySelector('.ag-invite-form select');
    return {
      name: val('input[placeholder="e.g. Aina Rahman"]'),
      email: val('input[placeholder="name@agency.my"]'),
      phone: val('input[placeholder="+60 12 345 6789"]'),
      company: sel ? sel.value : null,
    };
  });
  check('Back preserves name', preserved.name === 'Joel Test', JSON.stringify(preserved.name));
  check('Back preserves email', preserved.email === 'joel.test@agency.my');
  check('Back preserves phone', preserved.phone === '+60 13 999 8888');
  check('Back preserves company selection', preserved.company === '12');

  // --- 8. Single submission + truthful result -------------------------------
  await page.getByRole('button', { name: 'Review details' }).click();
  await page.waitForTimeout(300);
  const cb = page.locator('.dialog--invite .ops-checkrow input[type="checkbox"]');
  await cb.check({ force: true });
  await page.waitForTimeout(150);
  await page.getByRole('button', { name: 'Send invitation' }).click();
  await page.waitForTimeout(700);
  const sent = await page.evaluate(() => {
    const d = document.querySelector('.dialog--invite');
    const text = (d.textContent || '').replace(/\s+/g, ' ');
    return {
      calls: window.__inviteCalls,
      onResult: text.indexOf('Invitation submitted') !== -1 || !d.querySelector('.ag-invite-form'),
      showsEmail: text.indexOf('joel.test@agency.my') !== -1,
      showsSent: /sent|Sent/i.test(text),
      showsCompany: text.indexOf('Borneo Estates') !== -1,
      sendBtnStillThere: !!Array.from(d.querySelectorAll('button')).find(
        (b) => (b.textContent || '').indexOf('Send invitation') !== -1),
    };
  });
  check('exactly one POST /api/v1/staff/agents', sent.calls.length === 1, `${sent.calls.length} call(s)`);
  const payload = sent.calls[0] ? sent.calls[0].body : null;
  const payloadOk = !!payload &&
    payload.full_name === 'Joel Test' &&
    payload.email === 'joel.test@agency.my' &&
    payload.phone_number === '+60 13 999 8888' &&
    payload.company_id === 12 &&
    payload.allow_existing === false;
  check('POST payload preserves entered values + contract', payloadOk, JSON.stringify(payload));
  check('result step reached after backend response', sent.onResult);
  check('result shows backend-confirmed email + status + company',
    sent.showsEmail && sent.showsSent && sent.showsCompany,
    `email=${sent.showsEmail} sent=${sent.showsSent} company=${sent.showsCompany}`);
  check('submit control no longer offered after success', !sent.sendBtnStillThere);

  // --- 9. Done, reopen, Escape closes --------------------------------------
  await page.getByRole('button', { name: 'Done' }).click();
  await page.waitForTimeout(300);
  const closedAfterDone = await page.evaluate(() => !document.querySelector('.dialog--invite'));
  check('Done closes the dialog', closedAfterDone);

  await page.getByRole('button', { name: 'Invite agent' }).first().click();
  await page.waitForSelector('.dialog--invite', { timeout: 5000 });
  await page.waitForTimeout(300);
  const resetState = await page.evaluate(() => {
    const d = document.querySelector('.dialog--invite');
    return {
      onStep1: !!d.querySelector('.ag-invite-form'),
      emailCleared: (Array.from(d.querySelectorAll('input')).find(
        (i) => (i.placeholder || '').indexOf('@') !== -1) || {}).value === '',
    };
  });
  check('reopen starts a fresh wizard on step 1', resetState.onStep1 && resetState.emailCleared);

  await page.keyboard.press('Escape');
  await page.waitForTimeout(300);
  const closedByEscape = await page.evaluate(() => !document.querySelector('.dialog--invite'));
  check('Escape closes the dialog', closedByEscape);

  // --- 10. Mobile width -----------------------------------------------------
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole('button', { name: 'Invite agent' }).first().click();
  await page.waitForSelector('.dialog--invite', { timeout: 5000 });
  await page.waitForTimeout(400);
  const mobile = await page.evaluate(() => {
    const d = document.querySelector('.dialog--invite');
    const form = d.querySelector('.ag-invite-form');
    const cols = form ? getComputedStyle(form).gridTemplateColumns.split(' ').filter(Boolean).length : 0;
    const dr = d.getBoundingClientRect();
    const footer = d.querySelector('.btn-row');
    const fr = footer ? footer.getBoundingClientRect() : null;
    return {
      width: d.offsetWidth,
      cols,
      fits: dr.left >= 0 && dr.right <= window.innerWidth + 1,
      footerVisible: !!(fr && fr.bottom <= window.innerHeight + 1),
      scrollable: d.scrollHeight >= d.clientHeight,
    };
  });
  check('mobile dialog constrained to viewport', mobile.width <= 390 && mobile.fits, `${mobile.width}px`);
  check('mobile form collapses to one column', mobile.cols === 1, `${mobile.cols} track(s)`);
  check('mobile footer actions reachable', mobile.footerVisible);
  check('mobile body scrolls instead of clipping', mobile.scrollable);

  check('no page errors during the whole run', pageErrors.length === 0,
    pageErrors.slice(0, 3).join(' | '));

  await browser.close();
  const failed = results.filter((r) => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} checks passed`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((e) => {
  console.error('PROBE CRASHED:', e);
  process.exit(2);
});
