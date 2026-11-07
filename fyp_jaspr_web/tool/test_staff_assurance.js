// Unit regression for the staff MFA lifecycle (F2 / F3).
//
// Loads the REAL tool/auth_client.js source into a node:vm sandbox with a mocked
// Supabase client, DOM, fetch and storage - no browser, no live credentials, no
// network. It drives the three entry points that must all enforce the same
// staff aal2 gate:
//   * session restore   (doInitialize -> tryProfile -> enforceStaffAssurance)
//   * token refresh     (onAuthStateChange TOKEN_REFRESHED -> enforceStaffAssurance)
//   * sign-in           (password -> finishSignIn -> ensureStaffAssurance)
//
// Run: npm run test-auth --prefix tool   (or: node tool/test_staff_assurance.js)
'use strict';

const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert');

// Strip the ESM import; createClient is injected as a sandbox global instead.
const SOURCE = fs
  .readFileSync(path.join(__dirname, 'auth_client.js'), 'utf8')
  .replace(/^import .*$/m, '');

const VERIFIED_FACTOR = [{ id: 'f-1', type: 'totp', status: 'verified' }];

function makeStorage() {
  const m = new Map();
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: (k) => m.delete(k),
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Boot a fresh module instance (the navigation latch is per-document, so each
// case gets its own sandbox). Returns the bridge plus the captured navigation
// log, auth listeners and the mutable assurance object.
async function boot({
  pathname,
  role,
  aal,
  factors = VERIFIED_FACTOR,
  status = 'active',
  sessionPresent = true,
  assuranceError = false,
}) {
  const navigations = [];
  const assurance = { currentLevel: aal, nextLevel: 'aal2' };
  const session = sessionPresent
    ? { access_token: 'test-token', user: { id: 'u-1', email: 'staff@x.test' } }
    : null;
  const profile = {
    user_id: 'u-1',
    email: 'staff@x.test',
    full_name: 'Staff Tester',
    role,
    account_status: status,
  };
  const listeners = [];
  const fakeClient = {
    auth: {
      getSession: async () => ({ data: { session }, error: null }),
      onAuthStateChange: (cb) => {
        listeners.push(cb);
        return { data: { subscription: { unsubscribe() {} } } };
      },
      signInWithPassword: async () => ({ data: { session }, error: null }),
      signOut: async () => ({ error: null }),
      mfa: {
        listFactors: async () => ({ data: { all: factors }, error: null }),
        getAuthenticatorAssuranceLevel: async () =>
          assuranceError
            ? { data: null, error: new Error('assurance unavailable') }
            : { data: assurance, error: null },
        challenge: async () => ({ data: { id: 'ch-1' }, error: null }),
        verify: async () => ({ data: {}, error: null }),
      },
    },
  };
  const location = {
    pathname,
    href: 'https://x.test' + pathname,
    protocol: 'https:',
    origin: 'https://x.test',
    replace: (url) => navigations.push(url),
    assign: (url) => navigations.push(url),
  };
  const document = { cookie: '', querySelector: () => null, querySelectorAll: () => [] };
  const window = { dispatchEvent: () => {}, sitewiseAuth: null };
  const fetch = async (url) => {
    const u = String(url);
    const json = (body, ok = true, statusCode = 200) => ({
      ok,
      status: statusCode,
      json: async () => body,
    });
    if (u.endsWith('/auth-config.json'))
      return json({ configured: true, supabaseUrl: 'https://x.supabase.co', supabasePublishableKey: 'pub' });
    if (u.endsWith('/health')) return json({ status: 'ok' });
    if (u.endsWith('/api/v1/auth/me')) return json(profile);
    return json({ detail: 'not found' }, false, 404);
  };
  const sandbox = {
    createClient: () => fakeClient,
    document,
    location,
    window,
    fetch,
    sessionStorage: makeStorage(),
    localStorage: makeStorage(),
    CustomEvent: class {
      constructor(type, opts) {
        this.type = type;
        Object.assign(this, opts);
      }
    },
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    queueMicrotask,
    TextEncoder,
    btoa,
    URL,
    AbortSignal,
    console,
  };
  vm.createContext(sandbox);
  vm.runInContext(SOURCE, sandbox, { filename: 'auth_client.js' });
  await sandbox.window.sitewiseAuth.ready;
  return { bridge: sandbox.window.sitewiseAuth, navigations, listeners, assurance };
}

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

// --- F2: session restore re-confirms staff assurance -----------------------

test('restore: staff aal1 on /admin is routed to /staff/verify', async () => {
  const { navigations } = await boot({ pathname: '/admin', role: 'admin', aal: 'aal1' });
  assert.deepStrictEqual(navigations, ['/staff/verify']);
});

test('restore: staff aal2 on /admin stays (no redirect)', async () => {
  const { navigations } = await boot({ pathname: '/admin', role: 'admin', aal: 'aal2' });
  assert.deepStrictEqual(navigations, []);
});

test('restore: staff without a verified factor on /agent is routed to enroll', async () => {
  const { navigations } = await boot({ pathname: '/agent', role: 'agent', aal: 'aal1', factors: [] });
  assert.deepStrictEqual(navigations, ['/staff/mfa']);
});

test('restore: entrepreneur on /entrepreneur is never forced through MFA', async () => {
  const { navigations } = await boot({ pathname: '/entrepreneur', role: 'entrepreneur', aal: 'aal1' });
  assert.deepStrictEqual(navigations, []);
});

test('restore: the /staff/verify screen does not redirect to itself', async () => {
  const { navigations } = await boot({ pathname: '/staff/verify', role: 'admin', aal: 'aal1' });
  assert.deepStrictEqual(navigations, []);
});

test('restore: an assurance check that errors fails closed to /staff/verify', async () => {
  const { navigations } = await boot({
    pathname: '/admin',
    role: 'admin',
    aal: 'aal2',
    assuranceError: true,
  });
  assert.deepStrictEqual(navigations, ['/staff/verify']);
});

// --- F2: token refresh re-confirms staff assurance -------------------------

test('refresh: TOKEN_REFRESHED downgrading to aal1 on /admin routes to verify', async () => {
  const { navigations, listeners, assurance } = await boot({
    pathname: '/admin',
    role: 'admin',
    aal: 'aal2',
  });
  assert.deepStrictEqual(navigations, [], 'aal2 restore must not redirect');
  assurance.currentLevel = 'aal1'; // the rotated session has not completed MFA
  listeners.forEach((cb) => cb('TOKEN_REFRESHED'));
  await sleep(30); // let syncSessionCookies().then(enforceStaffAssurance) settle
  assert.deepStrictEqual(navigations, ['/staff/verify']);
});

test('refresh: TOKEN_REFRESHED still aal2 on /admin does not redirect', async () => {
  const { navigations, listeners } = await boot({ pathname: '/admin', role: 'admin', aal: 'aal2' });
  listeners.forEach((cb) => cb('TOKEN_REFRESHED'));
  await sleep(30);
  assert.deepStrictEqual(navigations, []);
});

// --- F3: sign-in routes through the same gate ------------------------------

test('sign-in: staff aal1 with a factor goes to /staff/verify (not a workspace)', async () => {
  const { bridge, navigations } = await boot({ pathname: '/login', role: 'admin', aal: 'aal1' });
  await bridge.password('staff@x.test', 'pw');
  assert.deepStrictEqual(navigations, ['/staff/verify']);
});

test('sign-in: staff aal2 with a factor goes home to /admin', async () => {
  const { bridge, navigations } = await boot({ pathname: '/login', role: 'admin', aal: 'aal2' });
  await bridge.password('staff@x.test', 'pw');
  assert.deepStrictEqual(navigations, ['/admin']);
});

test('sign-in: staff without a factor goes to enrollment', async () => {
  const { bridge, navigations } = await boot({ pathname: '/login', role: 'agent', aal: 'aal1', factors: [] });
  await bridge.password('staff@x.test', 'pw');
  assert.deepStrictEqual(navigations, ['/staff/mfa']);
});

test('sign-in: entrepreneur goes home to /entrepreneur', async () => {
  const { bridge, navigations } = await boot({ pathname: '/login', role: 'entrepreneur', aal: 'aal1' });
  await bridge.password('staff@x.test', 'pw');
  assert.deepStrictEqual(navigations, ['/entrepreneur']);
});

test('sign-in: a suspended staff account is rejected before any routing', async () => {
  const { bridge, navigations } = await boot({
    pathname: '/login',
    role: 'admin',
    aal: 'aal2',
    status: 'suspended',
  });
  await assert.rejects(() => bridge.password('staff@x.test', 'pw'), /suspended/i);
  assert.deepStrictEqual(navigations, []);
});

(async () => {
  let failed = 0;
  for (const { name, fn } of tests) {
    try {
      await fn();
      console.log('  ok  - ' + name);
    } catch (err) {
      failed++;
      console.error('FAIL  - ' + name);
      console.error('        ' + (err && err.message ? err.message : err));
    }
  }
  console.log(`\n${tests.length - failed}/${tests.length} staff assurance tests passed`);
  process.exit(failed ? 1 : 0);
})();