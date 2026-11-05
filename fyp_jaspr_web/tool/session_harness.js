// Browser-side stand-in for the Supabase auth bridge, for headless page
// verification only (verify_pages.js, shot.js).
//
// The app's role routes are guarded by `window.sitewiseAuth` and the catalog is
// served by the authenticated API, so a headless browser can render them only
// with a session — and a session needs real credentials. Instead of storing a
// login anywhere, this installs a stand-in bridge inside the test browser and
// answers the API paths from the fixture written by gen_catalog_fixture.js.
//
// Nothing that ships changes: `tool/auth_client.js` / `auth_bundle.js` is not
// loaded into the harness page, and the guard in `lib/app.dart` still admits a
// route only when the bridge itself reports that role.
const fs = require('node:fs');
const path = require('node:path');

const FIXTURE = path.join(
  __dirname,
  '..',
  '..',
  'test',
  '.data',
  'jaspr_catalog_fixture.json',
);

// Same-origin: the Jaspr server proxies /api/* to the FastAPI backend. All of
// those calls are intercepted below, so no live service is contacted.
const API_ORIGIN = '';

// Mirrors the shape of GET /api/v1/auth/me (FYP/backend).
const PROFILES = {
  entrepreneur: { user_id: 'harness-entrepreneur', email: 'sarah@nasihouse.my', display_name: 'Sarah Lim', role: 'entrepreneur' },
  owner: { user_id: 'harness-owner', email: 'owner@nasihouse.my', display_name: 'Owner Demo', role: 'owner' },
  admin: { user_id: 'harness-admin', email: 'admin@jaspr.local', display_name: 'Harness Administrator', role: 'admin' },
  agent: { user_id: 'harness-agent', email: 'aina@jaspr.local', display_name: 'Agent Aina', role: 'agent' },
};

function loadRows() {
  if (!fs.existsSync(FIXTURE)) {
    throw new Error(`Missing fixture at ${FIXTURE}. Run: node tool/gen_catalog_fixture.js`);
  }
  return JSON.parse(fs.readFileSync(FIXTURE, 'utf8')).rows;
}

/**
 * @param {import('playwright-core').Page} page
 * @param {{role?: string}} options role, or `auto` to follow the URL prefix
 */
async function installHarnessSession(page, { role = 'auto' } = {}) {
  const rows = loadRows();

  await page.addInitScript(({ role, profiles, apiOrigin }) => {
    const profileFor = () => {
      const name =
        role !== 'auto'
          ? role
          : (/^\/(entrepreneur|owner|admin|agent)(\/|$)/.exec(location.pathname) || [])[1] ||
            'entrepreneur';
      return profiles[name] || profiles.entrepreneur;
    };
    const bridge = {
      ready: Promise.resolve(),
      snapshot: () =>
        JSON.stringify({
          configured: true,
          user: { id: profileFor().user_id, email: profileFor().email },
          profile: profileFor(),
          error: '',
        }),
      request: async (path) => (await fetch(`${apiOrigin}${path}`)).text(),
      google: async () => {
        throw new Error('Harness session: sign-in is not available in headless verification.');
      },
      password: async () => {
        throw new Error('Harness session: sign-in is not available in headless verification.');
      },
      signup: async () => {
        throw new Error('Harness session: sign-in is not available in headless verification.');
      },
      complete: async () => {},
      signout: async () => {},
    };
    Object.defineProperty(window, 'sitewiseAuth', {
      configurable: true,
      get: () => bridge,
      set: () => {},
    });
  }, { role, profiles: PROFILES, apiOrigin: API_ORIGIN });

  // The real bundle is deliberately not loaded: it would open a Supabase client
  // with live credentials for a page that has no business holding one.
  await page.route('**/auth_bundle.js', (route) =>
    route.fulfill({ status: 200, contentType: 'application/javascript', body: '/* harness: auth bundle not loaded */' }),
  );

  await page.route('**/api/**', (route) => {
    const url = new URL(route.request().url());
    const json = (body) =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        headers: { 'Access-Control-Allow-Origin': route.request().headers()['origin'] || '*' },
        body: JSON.stringify(body),
      });
    if (url.pathname === '/api/v1/catalog/properties') {
      const limit = Math.min(200, Math.max(1, Number(url.searchParams.get('limit')) || 100));
      const offset = Math.max(0, Number(url.searchParams.get('offset')) || 0);
      return json({ ok: true, data: rows.slice(offset, offset + limit), meta: { total: rows.length, limit, offset } });
    }
    const detail = /^\/api\/v1\/catalog\/properties\/(.+)$/.exec(url.pathname);
    if (detail) {
      const row = rows.find((r) => r.id === decodeURIComponent(detail[1])) || null;
      return json({ ok: Boolean(row), data: row });
    }
    return route.fulfill({
      status: 404,
      contentType: 'application/json',
      body: JSON.stringify({ error: { message: `Harness does not serve ${url.pathname}.` } }),
    });
  });
}

module.exports = { installHarnessSession, PROFILES, FIXTURE };
