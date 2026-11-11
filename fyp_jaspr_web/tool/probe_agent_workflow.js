// End-to-end verification of the Agent Property Management workflow and the
// administrator review that closes it.
//
//   GET   /api/v1/staff/me/listings
//   GET   /api/v1/staff/listings/{id}
//   GET   /api/v1/staff/listings/{id}/change-requests
//   GET   /api/v1/staff/listings/{id}/verifications
//   POST  /api/v1/staff/listings/{id}/notes
//   GET   /api/v1/staff/change-requests?status=…
//   POST  /api/v1/staff/listings/{id}/change-requests/{rid}/decision
//
// Covers, on the BUILT bundle:
//   1. the persisted server DRAFT is what the editor shows on open (not the
//      live published values);
//   2. unsaved keystrokes survive switching listings and coming back, and the
//      selector marks the listing that holds them;
//   3. a note typed in the Activity tab actually enables "Add note", posts the
//      typed text, and clears the field on success;
//   4. a failed note POST surfaces an inline error instead of pretending;
//   5. the latest rejected / changes-requested decision is visible on the
//      Overview review card without opening the Admin review tab;
//   6. the administrator queue shows the agent's notes and refuses a rejection
//      with no reason (client guard) — no request is sent.
//
// Staff endpoints are answered from inline fixtures (probe-only). Run:
//   NODE_PATH=C:/Users/Lenovo/.workbuddy-ai/binaries/node/workspace/node_modules \
//   node tool/probe_agent_workflow.js
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness.js');

const BASE = process.env.BASE || 'http://127.0.0.1:8141';
const T0 = '2026-11-11T08:00:00Z';

function assignment(listingId, name) {
  return {
    listing_id: listingId,
    agent_id: 7,
    assigned_by_user_id: 'harness-admin',
    created_at: T0,
    updated_at: T0,
    name,
    address: `${listingId} Test Street`,
    city: 'Petaling Jaya',
    state: 'Selangor',
    property_type: 'Shop lot',
    rental_price: 4500,
    size_sqft: 1680,
    floor_level: 0,
    availability: 'Immediate',
    is_published: true,
    verification_status: 'approved',
    owner_user_id: 'harness-owner',
    property_exists: true,
  };
}

function facts(listingId, name) {
  return {
    id: listingId,
    name,
    property_type: 'Shop lot',
    description: 'Live description from the operational row.',
    address: `${listingId} Test Street`,
    city: 'Petaling Jaya',
    state: 'Selangor',
    postcode: '47300',
    rental_price: 4500,
    size_sqft: 1680,
    psf: 2.68,
    availability: 'Immediate',
    floor_level: 0,
    has_parking: false,
    is_fnb_suitable: false,
    verification_status: 'approved',
    is_published: true,
    owner_user_id: 'harness-owner',
    updated_at: T0,
  };
}

const ASSIGNMENTS = [assignment(201, 'Corner shoplot, SS15'), assignment(202, 'Uptown retail unit')];

// 201 carries an open DRAFT proposal that differs from the live row.
const DETAIL_201 = {
  listing: ASSIGNMENTS[0],
  property: facts(201, 'Corner shoplot, SS15'),
  owner: { user_id: 'harness-owner', full_name: 'Owner Demo', email: 'owner@nasihouse.my' },
  photos: [],
  change_request: {
    change_request_id: 'cr-draft-201',
    listing_id: 201,
    proposed_by: 'harness-agent',
    status: 'draft',
    changes: {
      name: { from: 'Corner shoplot, SS15', to: 'Corner shoplot, SS15 (renovated)' },
      rental_price: { from: 4500, to: 4800 },
    },
    created_at: T0,
    updated_at: T0,
  },
};

const DETAIL_202 = {
  listing: ASSIGNMENTS[1],
  property: facts(202, 'Uptown retail unit'),
  owner: { user_id: 'harness-owner', full_name: 'Owner Demo', email: 'owner@nasihouse.my' },
  photos: [],
  change_request: null,
};

// 201 has one rejected request: the agent must see why, on the Overview card.
const HISTORY_201 = {
  requests: [
    {
      change_request_id: 'cr-old-201',
      listing_id: 201,
      proposed_by: 'harness-agent',
      status: 'rejected',
      changes: { rental_price: { from: 4200, to: 4500 } },
      reason: 'Rent confirmed with the landlord.',
      review_note: 'Attach the signed tenancy addendum before resubmitting.',
      created_at: '2026-11-09T08:00:00Z',
      updated_at: '2026-11-10T08:00:00Z',
    },
    DETAIL_201.change_request,
  ],
  audit: [
    { audit_id: 1, listing_id: 201, action: 'note_added', actor_user_id: 'harness-agent', note: 'Landlord called back.', created_at: T0 },
  ],
};

async function withAgentPage(browser, fn, { noteStatus = 200 } = {}) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const page = await context.newPage();
  const pageErrors = [];
  const posts = [];
  page.on('pageerror', (e) => pageErrors.push(e.message));

  await installHarnessSession(page, { role: 'agent' });
  await page.route('**/api/v1/staff/me/listings', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ agent: { agent_id: 7 }, listings: ASSIGNMENTS }) }),
  );
  await page.route(/\/api\/v1\/staff\/listings\/201$/, (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(DETAIL_201) }),
  );
  await page.route(/\/api\/v1\/staff\/listings\/202$/, (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(DETAIL_202) }),
  );
  await page.route(/\/api\/v1\/staff\/listings\/\d+\/change-requests$/, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(/\/201\//.test(route.request().url()) ? HISTORY_201 : { requests: [], audit: [] }),
    }),
  );
  await page.route(/\/api\/v1\/staff\/listings\/\d+\/verifications$/, (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ verifications: [] }) }),
  );
  await page.route(/\/api\/v1\/staff\/listings\/\d+\/notes$/, async (route) => {
    posts.push(route.request().postDataJSON() || {});
    if (noteStatus !== 200) {
      return route.fulfill({
        status: noteStatus,
        contentType: 'application/json',
        body: JSON.stringify({ detail: 'The note store rejected the write.' }),
      });
    }
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true }) });
  });

  try {
    return await fn(page, { pageErrors, posts });
  } finally {
    await context.close();
  }
}

const titleInput = (page) => page.locator('label.field:has-text("Property title") input').first();
const noteInput = (page) => page.locator('input[aria-label="New internal note"]');
const addNoteButton = (page) => page.locator('button:has-text("Add note")');

async function openDetailsTab(page) {
  await page.locator('button[role="tab"]:has-text("Listing details")').first().click();
  await page.waitForTimeout(250);
}

async function main() {
  const browser = await chromium.launch({ args: ['--no-proxy-server'] });
  const checks = [];
  const ok = (name, pass, extra = '') => {
    checks.push({ name, pass: !!pass });
    if (!pass) console.log(`  FAIL ${name} ${extra}`);
  };

  // --- 1. persisted draft restored -----------------------------------------
  await withAgentPage(browser, async (page, { pageErrors }) => {
    await page.goto(`${BASE}/agent/property-detail?id=201`, { waitUntil: 'networkidle' });
    await page.waitForTimeout(1200);
    await openDetailsTab(page);

    ok('[draft] title shows the PROPOSED value', (await titleInput(page).inputValue()) === 'Corner shoplot, SS15 (renovated)', await titleInput(page).inputValue());
    const rent = await page.locator('label.field:has-text("Monthly rental") input').first().inputValue();
    ok('[draft] rental shows the PROPOSED value', rent === '4800', rent);
    const notice = await page.evaluate(() => document.body.innerText);
    ok('[draft] the editor says the proposal is open, not the live row', /draft/i.test(notice));

    // --- 5. rejection reason visible on the OVERVIEW card -------------------
    await page.locator('button[role="tab"]:has-text("Overview")').first().click();
    await page.waitForTimeout(400);
    const overview = await page.evaluate(() => document.body.innerText);
    ok('[decision] overview shows the rejection reason', /signed tenancy addendum/i.test(overview), overview.slice(0, 200));
    ok('[decision] overview says the request was rejected', /rejected/i.test(overview));

    ok('[draft] no page errors', pageErrors.length === 0, pageErrors.join('; '));
  });

  // --- 2. unsaved keystrokes survive a listing switch ----------------------
  await withAgentPage(browser, async (page, { pageErrors }) => {
    await page.goto(`${BASE}/agent/property-detail?id=201`, { waitUntil: 'networkidle' });
    await page.waitForTimeout(1200);
    await openDetailsTab(page);

    await titleInput(page).fill('Unsaved title typed by the agent');
    await page.waitForTimeout(300);

    // Tab switches are pure state changes: the value must survive them.
    await page.locator('button[role="tab"]:has-text("Photos & media")').first().click();
    await page.waitForTimeout(300);
    await openDetailsTab(page);
    ok('[switch] a tab switch keeps the typed value', (await titleInput(page).inputValue()) === 'Unsaved title typed by the agent', await titleInput(page).inputValue());

    // Switch to the other assigned listing through the selector.
    await page.locator('a.swpm-selector[href*="id=202"]').first().click();
    await page.waitForTimeout(1200);
    await openDetailsTab(page);
    ok('[switch] the other listing loads its own values', (await titleInput(page).inputValue()) === 'Uptown retail unit', await titleInput(page).inputValue());

    const marked = await page.evaluate(() => {
      const card = document.querySelector('a.swpm-selector[href*="id=201"]');
      return card ? card.innerText : '';
    });
    ok('[switch] the listing holding unsaved edits is marked', /Unsaved edits kept/i.test(marked), marked);

    // Come back: the typed value must be there, not the server draft.
    await page.locator('a.swpm-selector[href*="id=201"]').first().click();
    await page.waitForTimeout(1200);
    await openDetailsTab(page);
    ok('[switch] returning restores the unsaved value', (await titleInput(page).inputValue()) === 'Unsaved title typed by the agent', await titleInput(page).inputValue());
    ok('[switch] no page errors', pageErrors.length === 0, pageErrors.join('; '));
  });

  // --- 3. a note can actually be submitted ---------------------------------
  await withAgentPage(browser, async (page, { pageErrors, posts }) => {
    await page.goto(`${BASE}/agent/property-detail?id=201`, { waitUntil: 'networkidle' });
    await page.waitForTimeout(1200);
    await page.locator('button[role="tab"]:has-text("Activity")').first().click();
    await page.waitForTimeout(600);

    const disabledBefore = await addNoteButton(page).first().evaluate((el) => el.classList.contains('is-disabled'));
    ok('[note] Add note starts disabled while empty', disabledBefore);

    await noteInput(page).fill('Landlord confirmed the new rent by phone.');
    await page.waitForTimeout(300);
    const disabledAfter = await addNoteButton(page).first().evaluate((el) => el.classList.contains('is-disabled'));
    ok('[note] typing enables Add note', !disabledAfter);

    await addNoteButton(page).first().click();
    await page.waitForTimeout(900);
    ok('[note] POST carries the typed text', posts.length === 1 && posts[0].note === 'Landlord confirmed the new rent by phone.', JSON.stringify(posts));
    ok('[note] field clears after the server confirms', (await noteInput(page).inputValue()) === '', await noteInput(page).inputValue());
    ok('[note] no page errors', pageErrors.length === 0, pageErrors.join('; '));
  });

  // --- 4. a failed note write is reported, not swallowed -------------------
  await withAgentPage(
    browser,
    async (page, { pageErrors }) => {
      await page.goto(`${BASE}/agent/property-detail?id=201`, { waitUntil: 'networkidle' });
      await page.waitForTimeout(1200);
      await page.locator('button[role="tab"]:has-text("Activity")').first().click();
      await page.waitForTimeout(600);
      await noteInput(page).fill('This write will be refused.');
      await page.waitForTimeout(250);
      await addNoteButton(page).first().click();
      await page.waitForTimeout(900);
      const box = await page.evaluate(() => document.querySelector('.swpm-notebox')?.innerText || '');
      const kept = await noteInput(page).inputValue();
      ok('[note error] failure message shown', /note store rejected the write/i.test(box), box.replace(/\s+/g, ' '));
      ok('[note error] typed text is kept for a retry', kept === 'This write will be refused.', JSON.stringify(kept));
      ok('[note error] no page errors', pageErrors.length === 0, pageErrors.join('; '));
    },
    { noteStatus: 500 },
  );

  // --- 7. agent navigation offers only the approved scope ------------------
  await withAgentPage(browser, async (page, { pageErrors }) => {
    await page.goto(`${BASE}/agent`, { waitUntil: 'networkidle' });
    await page.waitForTimeout(1000);
    const nav = await page.evaluate(() => {
      const links = Array.from(document.querySelectorAll('nav a[href^="/agent"]'));
      return links.map((a) => ({ href: a.getAttribute('href'), text: a.innerText.trim().replace(/\s+/g, ' ') }));
    });
    const hrefs = nav.map((n) => n.href);
    ok('[nav] Dashboard offered', hrefs.includes('/agent'), JSON.stringify(hrefs));
    ok('[nav] Assigned Listings offered', hrefs.includes('/agent/listings'), JSON.stringify(hrefs));
    ok('[nav] Profile offered', hrefs.includes('/agent/profile'), JSON.stringify(hrefs));
    ok('[nav] Enquiries not offered', !hrefs.includes('/agent/enquiries'), JSON.stringify(hrefs));
    ok('[nav] Performance not offered', !hrefs.includes('/agent/performance'), JSON.stringify(hrefs));

    // The retired routes stay registered so old links still resolve.
    await page.goto(`${BASE}/agent/enquiries`, { waitUntil: 'networkidle' });
    await page.waitForTimeout(800);
    const legacy = await page.evaluate(() => document.body.innerText);
    ok('[nav] the retired Enquiries route still resolves', /Enquiries/i.test(legacy), legacy.slice(0, 160));
    ok('[nav] no page errors', pageErrors.length === 0, pageErrors.join('; '));
  });

  // --- 6. administrator queue: notes shown, reason enforced ----------------
  {
    const context = await browser.newContext({ viewport: { width: 1440, height: 1100 } });
    const page = await context.newPage();
    const pageErrors = [];
    const decisions = [];
    page.on('pageerror', (e) => pageErrors.push(e.message));
    await installHarnessSession(page, { role: 'admin' });
    await page.route('**/api/v1/staff/change-requests**', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          requests: [
            {
              change_request_id: 'cr-pending-201',
              listing_id: 201,
              status: 'pending',
              proposed_by: 'harness-agent',
              reason: 'Landlord approved the new rent.',
              changes: { rental_price: { from: 4500, to: 4800 } },
              property: { name: 'Corner shoplot, SS15', address: '201 Test Street', city: 'Petaling Jaya', property_exists: true },
              agent: { agent_name: 'Agent Aina' },
              created_at: T0,
              updated_at: T0,
              activity: [
                { audit_id: 1, action: 'note_added', note: 'Landlord called back.', created_at: T0 },
                { audit_id: 2, action: 'review_requested', note: null, created_at: T0 },
              ],
            },
          ],
          count: 1,
        }),
      }),
    );
    await page.route('**/api/v1/staff/listings/*/change-requests/*/decision', (route) => {
      decisions.push(route.request().postDataJSON() || {});
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' });
    });

    await page.goto(`${BASE}/admin/listings`, { waitUntil: 'networkidle' });
    await page.waitForTimeout(900);
    await page.locator('button:has-text("Agent change requests")').first().click();
    await page.waitForTimeout(900);

    const text = await page.evaluate(() => document.body.innerText);
    ok('[admin] queue renders the request', /Corner shoplot, SS15/.test(text));
    ok('[admin] agent note is visible to the reviewer', /Landlord called back/.test(text));
    ok('[admin] the agent note is labelled', /Agent note/i.test(text));

    await page.getByRole('button', { name: 'Reject', exact: true }).first().click();
    await page.waitForTimeout(500);
    const afterReject = await page.evaluate(() => document.body.innerText);
    ok('[admin] reject without a reason is refused', /Enter a reason before rejecting/i.test(afterReject));
    ok('[admin] no decision request was sent', decisions.length === 0, JSON.stringify(decisions));

    await page.locator('input[aria-label="Review note"]').first().fill('Attach the signed addendum.');
    await page.waitForTimeout(250);
    await page.getByRole('button', { name: 'Reject', exact: true }).first().click();
    await page.waitForTimeout(800);
    ok('[admin] reject with a reason posts the note', decisions.length === 1 && decisions[0].note === 'Attach the signed addendum.', JSON.stringify(decisions));
    ok('[admin] no page errors', pageErrors.length === 0, pageErrors.join('; '));
    await context.close();
  }

  await browser.close();
  const passed = checks.filter((c) => c.pass).length;
  console.log(`\nprobe_agent_workflow: ${passed}/${checks.length} checks passed`);
  const failed = checks.filter((c) => !c.pass);
  if (failed.length) {
    console.log('FAILED:', failed.map((f) => f.name).join(' | '));
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
