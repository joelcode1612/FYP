// Unit regression for the Supabase callback strategy and the invitation
// password-setup flow (task: "Fix and Complete SiteWise Agent Invitation
// Acceptance and Password Setup Flow").
//
// Loads the REAL tool/auth_client.js source into a node:vm sandbox with a
// mocked Supabase client, DOM, fetch and storage - no browser, no live
// credentials, no network, no real invitations.
//
// Covered:
//   * callback URL strategy: fragment (implicit) vs PKCE code vs plain pages
//   * error-carrying callback URLs (otp_expired / access_denied) fail fast
//     with user-safe messages - never the swallowed "Not a valid PKCE flow
//     url." / "No authenticated session was returned." errors
//   * session wait: a late callback session is awaited, not misreported
//   * one completion per document
//   * updatePassword: invite flow ends the LOCAL session, leaves the account
//     pending, leaves a one-time notice and redirects to /staff/signin;
//     recovery flow keeps the normal sign-in completion; failed updates
//     neither redirect nor lose the flow context
//
// Run: npm run test-callbacks --prefix tool   (or: node tool/test_callback_flows.js)
'use strict';

const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert');

// Strip the ESM import; createClient is injected as a sandbox global instead.
const SOURCE = fs
  .readFileSync(path.join(__dirname, 'auth_client.js'), 'utf8')
  .replace(/^import .*$/m, '');

function fakeJwt(aal) {
  const b = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  return 'eyJhbGciOiJIUzI1NiJ9.' + b({ aal }) + '.sig';
}

function makeStorage(seed) {
  const m = new Map(Object.entries(seed || {}));
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: (k) => m.delete(k),
    _map: m,
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Splits a full URL into the parts the sandbox `location` object needs.
function splitUrl(url) {
  const u = new URL(url);
  return {
    origin: u.origin,
    pathname: u.pathname,
    search: u.search,
    hash: u.hash,
    href: url,
  };
}

// Boot a fresh module instance. `url` is the full document URL (including
// search + fragment) so the load-time callback detection sees exactly what a
// real browser document would see at script start.
async function boot({
  url = 'https://x.test/login',
  role = 'agent',
  status = 'active',
  sessionPresent = true,
  sessionAfter = 0, // getSession calls that return null before the session
  updateUserError = null,
  createClientError = null,
} = {}) {
  const parts = splitUrl(url);
  const navigations = [];
  const createClientCalls = [];
  const updateUserCalls = [];
  const signOutCalls = [];
  const logs = [];
  const record = (...args) => logs.push(args.map((a) => String(a)).join(' '));
  const profile = {
    user_id: 'u-1',
    email: 'agent@x.test',
    full_name: 'Agent Tester',
    role,
    account_status: status,
  };
  const listeners = [];
  const session = {
    access_token: fakeJwt('aal1'),
    user: { id: 'u-1', email: 'agent@x.test', factors: [] },
  };
  let sessionReads = 0;
  const fakeClient = {
    auth: {
      getSession: async () => {
        sessionReads++;
        if (sessionAfter > 0 && sessionReads <= sessionAfter) {
          return { data: { session: null }, error: null };
        }
        return { data: { session: sessionPresent ? session : null }, error: null };
      },
      onAuthStateChange: (cb) => {
        listeners.push(cb);
        return { data: { subscription: { unsubscribe() {} } } };
      },
      updateUser: async (payload) => {
        updateUserCalls.push(payload);
        if (updateUserError) return { data: null, error: updateUserError };
        return { data: { user: session.user }, error: null };
      },
      signOut: async (options) => {
        signOutCalls.push(options || {});
        return { error: null };
      },
      signInWithPassword: async () => ({ data: { session }, error: null }),
    },
  };
  const location = {
    ...parts,
    protocol: 'https:',
    hostname: 'localhost', // enables DEV_CONSOLE diagnostics for log assertions
    replace: (target) => navigations.push(String(target)),
    assign: (target) => navigations.push(String(target)),
  };
  const document = { cookie: '', querySelector: () => null, querySelectorAll: () => [] };
  const window = { dispatchEvent: () => {}, sitewiseAuth: null, location };
  const fetch = async (target) => {
    const u = String(target);
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
  const sessionStorage = makeStorage();
  const localStorage = makeStorage();
  const sandbox = {
    createClient: (projectUrl, key, opts) => {
      createClientCalls.push(opts);
      if (createClientError) throw createClientError;
      return fakeClient;
    },
    document,
    location,
    window,
    fetch,
    sessionStorage,
    localStorage,
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
    atob,
    URL,
    URLSearchParams,
    AbortSignal,
    console: { log: record, warn: record, error: record, info: record },
  };
  vm.createContext(sandbox);
  vm.runInContext(SOURCE, sandbox, { filename: 'auth_client.js' });
  await sandbox.window.sitewiseAuth.ready;
  return {
    bridge: sandbox.window.sitewiseAuth,
    navigations,
    createClientCalls,
    updateUserCalls,
    signOutCalls,
    listeners,
    sessionStorage,
    logs,
  };
}

const CALLBACK = 'https://x.test/auth/callback';
const TOKENS = '#access_token=AT-VALUE&refresh_token=RT-VALUE&expires_in=3600&token_type=bearer';

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

// --- Callback URL strategy: client flow type ---------------------------------

test('strategy: a fragment-token document builds an IMPLICIT client', async () => {
  const { createClientCalls } = await boot({ url: CALLBACK + '?next=/reset-password' + TOKENS });
  assert.strictEqual(createClientCalls[0].auth.flowType, 'implicit');
});

test('strategy: a PKCE code document keeps the PKCE client', async () => {
  const { createClientCalls } = await boot({ url: CALLBACK + '?next=/reset-password&code=pkce-code' });
  assert.strictEqual(createClientCalls[0].auth.flowType, 'pkce');
});

test('strategy: a plain page keeps the PKCE client', async () => {
  const { createClientCalls } = await boot({ url: 'https://x.test/login' });
  assert.strictEqual(createClientCalls[0].auth.flowType, 'pkce');
});

// --- Valid callbacks route to the password screen with the right context -----

test('invite: valid fragment callback routes to /reset-password with invite context', async () => {
  const { bridge, navigations, sessionStorage } = await boot({
    url: CALLBACK + '?next=/reset-password' + TOKENS,
  });
  await bridge.complete('/reset-password');
  assert.deepStrictEqual(navigations, ['/reset-password']);
  assert.strictEqual(sessionStorage.getItem('sitewise.passwordFlow'), 'invite');
});

test('recovery: valid PKCE callback routes to /reset-password with recovery context', async () => {
  const { bridge, navigations, sessionStorage } = await boot({
    url: CALLBACK + '?next=/reset-password&code=pkce-code',
  });
  await bridge.complete('/reset-password');
  assert.deepStrictEqual(navigations, ['/reset-password']);
  assert.strictEqual(sessionStorage.getItem('sitewise.passwordFlow'), 'recovery');
});

test('recovery: Supabase PASSWORD_RECOVERY event is authoritative over the URL shape', async () => {
  const { bridge, navigations, listeners, sessionStorage } = await boot({
    url: CALLBACK + '?next=/reset-password&code=pkce-code',
  });
  listeners.forEach((cb) => cb('PASSWORD_RECOVERY'));
  await bridge.complete('/reset-password');
  assert.deepStrictEqual(navigations, ['/reset-password']);
  assert.strictEqual(sessionStorage.getItem('sitewise.passwordFlow'), 'recovery');
});

// --- Error-carrying callback URLs fail fast with user-safe messages ----------

test('expired invite (otp_expired): clear message, no navigation, no raw description', async () => {
  const { bridge, navigations, logs } = await boot({
    url:
      CALLBACK +
      '?next=/reset-password&error=access_denied&error_code=otp_expired' +
      '&error_description=Email%20link%20is%20invalid%20or%20has%20expired',
    sessionPresent: false,
  });
  await assert.rejects(() => bridge.complete('/reset-password'), /link has expired/i);
  assert.deepStrictEqual(navigations, [], 'an expired link must not navigate');
  const everythingLogged = logs.join('\n');
  assert.ok(
    !everythingLogged.includes('Email link is invalid'),
    'raw URL error_description must never be logged',
  );
});

test('cancelled link (access_denied): clear message and no navigation', async () => {
  const { bridge, navigations } = await boot({
    url: CALLBACK + '?error=access_denied&error_code=access_denied&error_description=Signups%20not%20allowed',
    sessionPresent: false,
  });
  await assert.rejects(() => bridge.complete(), /cancelled or is no longer valid/i);
  assert.deepStrictEqual(navigations, []);
});

test('unknown callback error: generic actionable message, no internals echoed', async () => {
  const { bridge } = await boot({
    url: CALLBACK + '?error=server_error&error_code=unexpected&error_description=internal%20detail%20XYZ',
    sessionPresent: false,
  });
  await assert.rejects(() => bridge.complete(), /could not be completed/i);
});

// --- Session wait + one completion -------------------------------------------

test('late session: currentSession waits for the callback exchange', async () => {
  const { bridge, navigations, sessionStorage } = await boot({
    url: CALLBACK + '?next=/reset-password&code=pkce-code',
    sessionAfter: 3,
  });
  await bridge.complete('/reset-password');
  assert.deepStrictEqual(navigations, ['/reset-password']);
  assert.strictEqual(sessionStorage.getItem('sitewise.passwordFlow'), 'recovery');
});

test('no session at all: actionable message, never the old misleading error', async () => {
  const { bridge, navigations } = await boot({
    url: CALLBACK + '?next=/reset-password&code=pkce-code',
    sessionPresent: false,
  });
  await assert.rejects(() => bridge.complete('/reset-password'), /No authenticated session was created/i);
  assert.deepStrictEqual(navigations, []);
});

test('one completion: concurrent complete() calls navigate exactly once', async () => {
  const { bridge, navigations } = await boot({
    url: CALLBACK + '?next=/reset-password' + TOKENS,
  });
  await Promise.all([bridge.complete('/reset-password'), bridge.complete('/reset-password')]);
  assert.strictEqual(navigations.filter((n) => n === '/reset-password').length, 1);
});

// --- updatePassword: invitation flow (Issue C) --------------------------------

test('invite update: sets password, signs out LOCALLY, leaves notice, routes to /staff/signin', async () => {
  const { bridge, navigations, updateUserCalls, signOutCalls, sessionStorage } = await boot({
    url: 'https://x.test/reset-password',
    role: 'agent',
    status: 'pending',
  });
  sessionStorage.setItem('sitewise.passwordFlow', 'invite');
  await bridge.updatePassword('Sup3rSecret!x');
  assert.strictEqual(updateUserCalls.length, 1, 'exactly one credential update');
  assert.strictEqual(updateUserCalls[0].password, 'Sup3rSecret!x');
  assert.strictEqual(signOutCalls.length, 1, 'exactly one sign-out');
  assert.strictEqual(signOutCalls[0].scope, 'local', 'LOCAL sign-out only');
  assert.deepStrictEqual(navigations, ['/staff/signin']);
  assert.strictEqual(
    sessionStorage.getItem('sitewise.passwordFlow'),
    null,
    'flow context cleared after success',
  );
  const raw = sessionStorage.getItem('sitewise.passwordNotice');
  assert.ok(raw, 'one-time success notice left for the sign-in page');
  const notice = JSON.parse(raw);
  assert.strictEqual(notice.title, 'Password successfully created!');
  assert.match(notice.body, /awaiting administrator activation/);
});

test('invite update: the notice never carries credentials or tokens', async () => {
  const { bridge, sessionStorage } = await boot({ url: 'https://x.test/reset-password' });
  sessionStorage.setItem('sitewise.passwordFlow', 'invite');
  await bridge.updatePassword('Sup3rSecret!x');
  const raw = sessionStorage.getItem('sitewise.passwordNotice') || '';
  assert.ok(!raw.includes('Sup3rSecret!x'), 'password never in state');
  assert.ok(!raw.includes('AT-VALUE'), 'access token never in state');
  assert.ok(!raw.includes('RT-VALUE'), 'refresh token never in state');
});

test('invite update: a failed update stays on the page and keeps the flow context', async () => {
  const { bridge, navigations, signOutCalls, sessionStorage } = await boot({
    url: 'https://x.test/reset-password',
    updateUserError: new Error('Password should be at least 8 characters.'),
  });
  sessionStorage.setItem('sitewise.passwordFlow', 'invite');
  await assert.rejects(() => bridge.updatePassword('weak'), /at least 8 characters/);
  assert.deepStrictEqual(navigations, [], 'failed update must not redirect');
  assert.deepStrictEqual(signOutCalls, [], 'failed update must not sign out');
  assert.strictEqual(
    sessionStorage.getItem('sitewise.passwordFlow'),
    'invite',
    'flow context survives for the retry',
  );
  assert.strictEqual(sessionStorage.getItem('sitewise.passwordNotice'), null);
});

test('invite update: consumePasswordNotice is one-shot', async () => {
  const { bridge, sessionStorage } = await boot({ url: 'https://x.test/reset-password' });
  sessionStorage.setItem('sitewise.passwordFlow', 'invite');
  await bridge.updatePassword('Sup3rSecret!x');
  const first = JSON.parse(bridge.consumePasswordNotice());
  assert.strictEqual(first.title, 'Password successfully created!');
  assert.strictEqual(bridge.consumePasswordNotice(), null, 'second read consumes nothing');
});

// --- updatePassword: recovery flow (regression: entrepreneur reset) -----------

test('recovery update: an ACTIVE account continues the normal sign-in completion', async () => {
  const { bridge, navigations, signOutCalls, sessionStorage } = await boot({
    url: 'https://x.test/reset-password',
    role: 'entrepreneur',
    status: 'active',
  });
  sessionStorage.setItem('sitewise.passwordFlow', 'recovery');
  await bridge.updatePassword('Sup3rSecret!x');
  assert.deepStrictEqual(navigations, ['/entrepreneur'], 'recovery signs in as usual');
  assert.deepStrictEqual(signOutCalls, [], 'recovery must NOT be signed out');
  assert.strictEqual(
    sessionStorage.getItem('sitewise.passwordNotice'),
    null,
    'no staff notice for the recovery flow',
  );
});

test('legacy reset page without a stashed context keeps the recovery completion', async () => {
  const { bridge, navigations } = await boot({
    url: 'https://x.test/reset-password',
    role: 'entrepreneur',
    status: 'active',
  });
  await bridge.updatePassword('Sup3rSecret!x');
  assert.deepStrictEqual(navigations, ['/entrepreneur']);
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
  console.log(`\n${tests.length - failed}/${tests.length} callback flow tests passed`);
  process.exit(failed ? 1 : 0);
})();
