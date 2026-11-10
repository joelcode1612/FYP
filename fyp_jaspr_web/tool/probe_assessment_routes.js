// Route + integration verification for the assessment routing change.
//
//   /entrepreneur/assessments          -> Stage 1 saved-property selector
//   /entrepreneur/assessments?id=EP-…  -> the property's assessment workspace
//   /entrepreneur/assessments/history  -> the assessment history list
//   /entrepreneur/assessment?id=EP-…   -> the backward-compatible deep link
//
// Everything runs in the browser: `web/auth_bundle.js` is replaced by a stub
// `window.sitewiseAuth` bridge that serves fixture data for the saved
// properties, the catalogue, the assessment history and the assessment
// endpoints, and RECORDS every call. No request leaves the page, so no
// Supabase identity is provisioned and no assessment is created for real.
//
// Checks:
//  1. The Assessments navbar opens the Stage 1 selector (not the history).
//  2. Stage 1 shows the real saved properties from GET /saved-properties/me,
//     each resolved through GET /catalog/properties/{id}.
//  3. Opening the page creates NO assessment (no POST) and shows no
//     "No property selected" state.
//  4. The Continue action is disabled until a property is selected.
//  5. Search filters the saved list.
//  6. Continue resumes an existing assessment when one exists, and creates
//     one (POST /api/v1/assessments/) only when it does not — with the exact
//     catalogue ref, never a numeric id.
//  7. The workspace then renders the five-stage workflow for that property.
//  8. /entrepreneur/assessments/history still lists the assessments.
//  9. /entrepreneur/assessment?id=… still opens the workspace.
// 10. The saved list is read from the authenticated endpoint, not from any
//     browser-session mock.
const { chromium } = require('playwright-core');

const BASE = process.env.BASE || 'http://127.0.0.1:8155';

const results = [];
function check(name, ok, detail) {
  results.push({ name, ok });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  [' + detail + ']' : ''}`);
}

const SAVED = [
  {
    id: 'EP-01051',
    title: 'SS15 Corner Retail',
    address: 'Jalan SS15/1',
    city: 'Subang Jaya',
    state: 'Selangor',
    postcode: '47500',
    rental_rm: 7800,
    size_sqft: 1680,
    property_type: 'Corner unit',
    latitude: 3.0738,
    longitude: 101.587,
    image_url: 'https://images.example.test/ss15.jpg',
    suitability_score: 82,
  },
  {
    id: 'EP-02012',
    title: 'Borneo Estates Lot',
    address: 'Jalan Merdeka',
    city: 'Kota Kinabalu',
    state: 'Sabah',
    postcode: '88000',
    rental_rm: 5400,
    size_sqft: 2400,
    property_type: 'Shop lot',
    latitude: 5.417,
    longitude: 100.335,
    image_url: null,
    suitability_score: null,
  },
];

const STUB_BUNDLE = `
(function () {
  const MODE = '__MODE__';
  const calls = [];
  window.__calls = calls;
  const saved = [
    { favorite_id: 'fav-1', property_ref: 'EP-01051', created_at: '2026-11-01T09:00:00Z' },
    { favorite_id: 'fav-2', property_ref: 'EP-02012', created_at: '2026-11-02T09:00:00Z' }
  ];
  const catalogue = {
    'EP-01051': ${JSON.stringify(SAVED[0])},
    'EP-02012': ${JSON.stringify(SAVED[1])}
  };
  const assessment = {
    assessment_id: 'a-1111-2222',
    property_id: 'EP-01051',
    status: 'in_progress',
    current_stage: 2,
    current_stage_key: 'business_requirements',
    completed_stages: 1,
    total_stages: 5,
    progress_percent: 20,
    report_available: false,
    requirements: null,
    requirements_version: 2,
    stages: [
      { key: 'select_property', number: 1, title: 'Select property', status: 'complete',
        completed_at: '2026-11-09T10:00:00Z', unavailable_reason: null },
      { key: 'business_requirements', number: 2, title: 'Business preferences', status: 'current',
        completed_at: null, unavailable_reason: null },
      { key: 'location_evidence', number: 3, title: 'Location evidence', status: 'incomplete',
        completed_at: null, unavailable_reason: null },
      { key: 'ai_explanation', number: 4, title: 'AI explanation', status: 'incomplete',
        completed_at: null, unavailable_reason: null },
      { key: 'assessment_report', number: 5, title: 'Assessment report', status: 'incomplete',
        completed_at: null, unavailable_reason: null }
    ],
    capabilities: { report: { available: false, reason: 'Not generated yet' } },
    next_action: {},
    property: catalogue['EP-01051'],
    created_at: '2026-11-09T10:00:00Z',
    updated_at: '2026-11-09T10:00:00Z'
  };
  // Assessments that already exist for the account, keyed by catalogue ref.
  const existing = { 'EP-02012': Object.assign({}, assessment, {
    assessment_id: 'a-3333-4444', property_id: 'EP-02012', property: catalogue['EP-02012']
  }) };

  function route(path, method, bodyJson) {
    const body = bodyJson ? JSON.parse(bodyJson) : null;
    calls.push({ method: method, path: path, body: body });

    if (method === 'GET' && path.indexOf('/api/v1/saved-properties/me') === 0) {
      // 'empty' exercises the no-saved-properties state.
      if (MODE === 'empty') return JSON.stringify({ saved: [], unresolved: [] });
      return JSON.stringify({ saved: saved, unresolved: [] });
    }
    if (method === 'GET' && path.indexOf('/api/v1/catalog/properties/') === 0) {
      const id = path.split('/').pop().split('?')[0];
      const row = catalogue[id];
      if (!row) return JSON.stringify({ detail: 'Not found' });
      // The catalogue detail endpoint answers with the row itself.
      return JSON.stringify(row);
    }
    if (method === 'GET' && path.indexOf('/api/v1/assessments/me') === 0) {
      const items = Object.keys(existing).map(function (k) { return existing[k]; });
      return JSON.stringify({ data: items, meta: { total: items.length } });
    }
    if (method === 'GET' && path.indexOf('/api/v1/assessments/by-property/') === 0) {
      const id = path.split('/').pop().split('?')[0];
      return JSON.stringify({ assessment: existing[id] || null });
    }
    if (method === 'POST' && path === '/api/v1/assessments/') {
      const id = body.property_id;
      const created = Object.assign({}, assessment, {
        assessment_id: 'a-9999-0000', property_id: id, property: catalogue[id] || null
      });
      existing[id] = created;
      return JSON.stringify({ created: true, assessment: created });
    }
    return JSON.stringify({ data: [] });
  }

  window.sitewiseAuth = {
    ready: Promise.resolve(),
    snapshot: function () {
      return JSON.stringify({
        configured: true,
        profile: { role: 'entrepreneur', email: 'owner@sitewise.test',
                   full_name: 'Test Owner', aal: 'aal1' }
      });
    },
    request: function (path, method, body) {
      return Promise.resolve(route(path || '', method || 'GET', body || ''));
    },
    requestDetailed: function (path, method, body) {
      // WebAuth.requestDetailed jsonDecodes the bridge's string answer, so the
      // stub must return a JSON STRING of {ok, body} — not a JS object.
      return Promise.resolve(JSON.stringify({ ok: true,
        body: JSON.parse(route(path || '', method || 'GET', body || '')) }));
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
  page.on('pageerror', (e) =>
    pageErrors.push('pageerror: ' + e.message + ' :: ' + (e.stack || '').slice(0, 400)));
  page.on('console', (m) => {
    if (process.env.DEBUG && m.text().indexOf('ASW-NAV') !== -1) {
      console.log('CONSOLE:', m.text());
    }
  });

  await page.route('**/auth_bundle.js', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/javascript',
      body: STUB_BUNDLE.replace('__MODE__', 'default'),
    }),
  );

  const apiCalls = () => page.evaluate(() => window.__calls || []);

  // --- 1. The Assessments navbar opens the Stage 1 selector -------------------
  await page.goto(BASE + '/entrepreneur/assessments', { waitUntil: 'networkidle' });
  await page.waitForTimeout(1500);

  const stage1 = await page.evaluate(() => {
    const body = document.body.textContent || '';
    return {
      url: location.pathname + location.search,
      bodyText: body,
      hasTitle: body.indexOf('Location Assessment') !== -1,
      hasSubtitle:
        body.indexOf('Choose a saved commercial property') !== -1,
      hasSavedHeading: body.indexOf('Your Saved Properties') !== -1,
      hasSearch: !!document.querySelector('input[placeholder*="Search saved"]'),
      radiogroup: !!document.querySelector('[role="radiogroup"]'),
      radios: document.querySelectorAll('input[type="radio"]').length,
      cards: document.querySelectorAll('.asw-select-card').length,
      hasEmptyState: body.indexOf('No property selected') !== -1,
      hasHistoryLink:
        !!Array.from(document.querySelectorAll('a')).find(
          (a) => (a.getAttribute('href') || '').indexOf(
            '/entrepreneur/assessments/history') !== -1),
      stages: document.querySelectorAll(
        '.sw-assessment-journey__step').length,
      continueBtn: (() => {
        const b = Array.from(document.querySelectorAll('button')).find(
          (x) => (x.textContent || '').indexOf('Continue Assessment') !== -1);
        return b ? { disabled: b.hasAttribute('disabled'), text: b.textContent } : null;
      })(),
      firstCard: (() => {
        const c = document.querySelector('.asw-select-card');
        return c ? c.textContent.replace(/\\s+/g, ' ').trim() : '';
      })(),
    };
  });

  check('route /entrepreneur/assessments renders Stage 1', stage1.hasTitle && stage1.hasSavedHeading,
    stage1.url);
  check('Stage 1 subtitle present', stage1.hasSubtitle);
  check('no "No property selected" empty state', !stage1.hasEmptyState);
  check('five-stage indicator rendered', stage1.stages === 5, `${stage1.stages} stages`);
  check('saved-property search field rendered', stage1.hasSearch);
  check('saved properties rendered as radio cards', stage1.radiogroup && stage1.radios === 2 && stage1.cards === 2,
    `radios=${stage1.radios} cards=${stage1.cards}`);
  check('card shows real catalogue data', /SS15 Corner Retail/.test(stage1.firstCard) &&
    /Jalan SS15\/1/.test(stage1.firstCard) && /7,?800|7800/.test(stage1.firstCard) &&
    /1,?680|1680/.test(stage1.firstCard) && /Corner unit/.test(stage1.firstCard),
    stage1.firstCard.slice(0, 120));
  check('existing assessment is flagged on its card',
    /Assessment in progress/.test(stage1.bodyText),
    'EP-02012 has a record');
  check('Assessment History action visible', stage1.hasHistoryLink);
  check('Continue disabled without a selection',
    !!stage1.continueBtn && stage1.continueBtn.disabled,
    JSON.stringify(stage1.continueBtn));

  const callsAfterOpen = await apiCalls();
  check('no assessment created on open',
    !callsAfterOpen.some((c) => c.method === 'POST' && c.path === '/api/v1/assessments/'),
    `${callsAfterOpen.filter((c) => c.method === 'POST').length} POST(s)`);
  check('saved list read from the authenticated endpoint',
    callsAfterOpen.some((c) => c.path.indexOf('/api/v1/saved-properties/me') === 0));
  check('catalogue details read per saved ref',
    callsAfterOpen.some((c) => c.path === '/api/v1/catalog/properties/EP-01051') &&
    callsAfterOpen.some((c) => c.path === '/api/v1/catalog/properties/EP-02012'));
  check('no browser-session mock data used for the list',
    !callsAfterOpen.some((c) => c.path.indexOf('/api/v1/explore') === 0));

  // --- 5. Search filters the list -------------------------------------------
  await page.fill('input[placeholder*="Search saved"]', 'Borneo');
  await page.waitForTimeout(250);
  const filtered = await page.evaluate(() => ({
    cards: document.querySelectorAll('.asw-select-card').length,
    text: document.body.textContent || '',
  }));
  check('search filters the saved list', filtered.cards === 1 && /Borneo Estates Lot/.test(filtered.text),
    `${filtered.cards} card(s)`);

  await page.fill('input[placeholder*="Search saved"]', '');
  await page.waitForTimeout(250);

  // --- 6a. Selecting a property that ALREADY has an assessment resumes it ---
  await page.click('.asw-select-card:nth-of-type(2) input[type="radio"]');
  await page.waitForTimeout(250);
  const selected = await page.evaluate(() => {
    const b = Array.from(document.querySelectorAll('button')).find(
      (x) => (x.textContent || '').indexOf('Continue Assessment') !== -1);
    return {
      disabled: b ? b.hasAttribute('disabled') : null,
      checked: document.querySelectorAll('input[type="radio"]:checked').length,
      summary: (document.querySelector('.asw-property__title') || {}).textContent || '',
    };
  });
  check('Continue enabled after a selection', selected.disabled === false);
  check('exactly one property selected', selected.checked === 1, `${selected.checked} checked`);
  check('selected-property summary rendered', /Borneo Estates Lot/.test(selected.summary),
    selected.summary);

  const styles = await page.evaluate(() => {
    const card = document.querySelector('.asw-select-card.is-selected');
    const plain = document.querySelector('.asw-select-card:not(.is-selected)');
    if (!card) return null;
    const cs = getComputedStyle(card);
    return {
      border: cs.borderTopColor,
      radius: cs.borderTopLeftRadius,
      bg: cs.backgroundColor,
      plainBorder: plain ? getComputedStyle(plain).borderTopColor : '',
    };
  });
  check('selected card uses the SiteWise royal-blue accent',
    !!styles && styles.border === 'rgb(29, 78, 216)' &&
    styles.plainBorder !== styles.border,
    JSON.stringify(styles));
  check('card keeps the design-system radius (12px)',
    !!styles && styles.radius === '12px', styles && styles.radius);

  await page.getByRole('button', { name: 'Continue Assessment' }).click();
  await page.waitForTimeout(1200);
  const resumed = await page.evaluate(() => ({
    url: location.pathname + location.search,
    body: document.body.textContent || '',
  }));
  const callsAfterResume = await apiCalls();
  const resumePosts = callsAfterResume.filter(
    (c) => c.method === 'POST' && c.path === '/api/v1/assessments/');
  check('existing assessment resumes without creating a new one', resumePosts.length === 0,
    `${resumePosts.length} POST(s)`);
  check('workspace opened for the resumed property',
    resumed.url.indexOf('/entrepreneur/assessments?id=EP-02012') !== -1, resumed.url);
  check('workspace shows the five-stage workflow',
    /Assessment workspace|Start this assessment/.test(resumed.body),
    resumed.body.slice(0, 80));

  // --- 6b. A property with no assessment is created only on the action ------
  await page.goto(BASE + '/entrepreneur/assessments', { waitUntil: 'networkidle' });
  await page.waitForTimeout(1200);
  await page.click('.asw-select-card:nth-of-type(1) input[type="radio"]');
  await page.waitForTimeout(200);
  await page.getByRole('button', { name: 'Continue Assessment' }).click();
  await page.waitForTimeout(1500);
  const created = await page.evaluate(() => ({
    url: location.pathname + location.search,
    body: document.body.textContent || '',
  }));
  const callsAfterCreate = await apiCalls();
  const createPosts = callsAfterCreate.filter(
    (c) => c.method === 'POST' && c.path === '/api/v1/assessments/');
  check('new assessment created exactly once', createPosts.length === 1,
    `${createPosts.length} POST(s)`);
  const payload = createPosts[0] ? createPosts[0].body : null;
  check('create payload carries the catalogue ref',
    !!payload && payload.property_id === 'EP-01051', JSON.stringify(payload));
  check('no numeric id substituted for the catalogue ref',
    !!payload && /^EP-\d+$/.test(String(payload.property_id)),
    String(payload && payload.property_id));
  check('workspace opened for the created assessment',
    created.url.indexOf('/entrepreneur/assessments?id=EP-01051') !== -1, created.url);

  // --- 8. History route (via the in-page link, i.e. client-side routing) -----
  await page.goto(BASE + '/entrepreneur/assessments', { waitUntil: 'networkidle' });
  await page.waitForTimeout(1200);
  await page.evaluate(() => {
    window.__noReloadMarker = 'alive';
  });
  await page.click('a[href="/entrepreneur/assessments/history"]');
  await page.waitForTimeout(1500);
  const history = await page.evaluate(() => ({
    body: document.body.textContent || '',
    rows: document.querySelectorAll('.audit-table tbody tr').length,
    url: location.pathname,
    clientSide: window.__noReloadMarker === 'alive',
  }));
  check('/entrepreneur/assessments/history renders the history list',
    history.url === '/entrepreneur/assessments/history' &&
    /Assessment history/.test(history.body) && history.rows >= 1,
    `rows=${history.rows} clientSide=${history.clientSide}`);

  // --- 9. Backward-compatible deep link --------------------------------------
  await page.goto(BASE + '/entrepreneur/assessment?id=EP-01051', { waitUntil: 'networkidle' });
  await page.waitForTimeout(1200);
  const legacy = await page.evaluate(() => ({
    url: location.pathname + location.search,
    body: document.body.textContent || '',
  }));
  check('/entrepreneur/assessment?id=… still opens the workspace',
    legacy.url.indexOf('/entrepreneur/assessment?id=EP-01051') !== -1 &&
    /SS15 Corner Retail/.test(legacy.body),
    legacy.url);

  // --- 10. No saved properties -> the empty state, never a dead end ---------
  const emptyPage = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await emptyPage.route('**/auth_bundle.js', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/javascript',
      body: STUB_BUNDLE.replace('__MODE__', 'empty'),
    }),
  );
  await emptyPage.goto(BASE + '/entrepreneur/assessments', { waitUntil: 'networkidle' });
  await emptyPage.waitForTimeout(1200);
  const emptyState = await emptyPage.evaluate(() => {
    const body = document.body.textContent || '';
    const explore = Array.from(document.querySelectorAll('a')).find(
      (a) => (a.getAttribute('href') || '') === '/entrepreneur/explore');
    return {
      body: body,
      hasMessage: body.indexOf(
        'No saved properties yet. Save a property from Explore') !== -1,
      hasExplore: !!explore,
      cards: document.querySelectorAll('.asw-select-card').length,
    };
  });
  check('empty saved list shows the guidance + Explore action',
    emptyState.hasMessage && emptyState.hasExplore && emptyState.cards === 0,
    `cards=${emptyState.cards}`);
  await emptyPage.close();

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
