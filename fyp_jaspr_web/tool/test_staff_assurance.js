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
// The REAL GoTrue shape: factors carry `factor_type`, not `type`. Regression
// coverage must exercise this shape or the staff gate silently breaks.
const GOTRUE_VERIFIED_FACTOR = [{ id: 'f-gt', factor_type: 'totp', status: 'verified' }];

// Minimal decodable JWT so the bridge's session-state reader (which parses
// the access token's `aal` claim) exercises the same code path as production.
function fakeJwt(aal, methods) {
  const b = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  return (
    'eyJhbGciOiJIUzI1NiJ9.' +
    b({ aal, amr: methods.map((m) => ({ method: m, timestamp: 1794086000 })) }) +
    '.sig'
  );
}

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
  email = 'staff@x.test',
  enrollError = null,
  enrollUri = null,
  verifyError = null,
}) {
  const navigations = [];
  const assurance = { currentLevel: aal, nextLevel: aal === 'aal2' ? 'aal2' : 'aal2' };
  const profile = {
    user_id: 'u-1',
    email,
    full_name: 'Staff Tester',
    role,
    account_status: status,
  };
  const listeners = [];
  const enrollCalls = [];
  const unenrollCalls = [];
  const logs = [];
  const record = (...args) => logs.push(args.map((a) => String(a)).join(' '));
  // Mutable session state: the verify step mutates it the way GoTrue's verify
  // response does (aal2 token + verified factor), and tests may downgrade it
  // to emulate a refresh that loses the aal2 claim.
  const sessionState = { aal, methods: ['password'] };
  const factors_ = factors.map((f) => ({ ...f }));
  const makeSession = () => ({
    access_token: fakeJwt(sessionState.aal, sessionState.methods),
    user: { id: 'u-1', email, factors: factors_ },
  });
  const effectiveEnrollUri =
    enrollUri !== undefined && enrollUri !== null
      ? enrollUri
      : 'otpauth://totp/SiteWise:' + encodeURIComponent(email) +
        '?secret=TOTPSECRET123&issuer=SiteWise&algorithm=SHA1&digits=6&period=30';
  const fakeClient = {
    auth: {
      getSession: async () => ({
        data: { session: sessionPresent ? makeSession() : null },
        error: null,
      }),
      onAuthStateChange: (cb) => {
        listeners.push(cb);
        return { data: { subscription: { unsubscribe() {} } } };
      },
      signInWithPassword: async () => ({ data: { session: makeSession() }, error: null }),
      signOut: async () => ({ error: null }),
      mfa: {
        listFactors: async () => ({ data: { all: factors_ }, error: null }),
        getAuthenticatorAssuranceLevel: async () =>
          assuranceError
            ? { data: null, error: new Error('assurance unavailable') }
            : { data: assurance, error: null },
        challenge: async () => ({ data: { id: 'ch-1' }, error: null }),
        verify: async () => {
          if (verifyError) return { data: null, error: verifyError };
          // Emulate GoTrue's verify: the returned session is saved with an
          // aal2 token and the factor becomes verified.
          sessionState.aal = 'aal2';
          sessionState.methods.push('mfa/mfa');
          if (!factors_.some((f) => (f.type || f.factor_type) === 'totp' && f.status === 'verified')) {
            factors_.push({ id: 'f-new', factor_type: 'totp', status: 'verified' });
          }
          return { data: {}, error: null };
        },
        enroll: async (params) => {
          enrollCalls.push(params);
          if (enrollError) return { data: null, error: enrollError };
          return {
            data: {
              id: 'f-new',
              type: 'totp',
              friendly_name: params.friendlyName,
              totp: {
                qr_code: 'data:image/svg+xml;utf-8,<svg/>',
                secret: 'TOTPSECRET123',
                uri: effectiveEnrollUri,
              },
            },
            error: null,
          };
        },
        unenroll: async (opts) => {
          unenrollCalls.push(opts && opts.factorId);
          return { data: {}, error: null };
        },
      },
    },
  };
  const location = {
    pathname,
    href: 'https://x.test' + pathname,
    protocol: 'https:',
    origin: 'https://x.test',
    // localhost enables the bridge's DEV_CONSOLE diagnostics so the safety of
    // what gets logged can be asserted directly.
    hostname: 'localhost',
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
    atob,
    URL,
    AbortSignal,
    console: { log: record, warn: record, error: record, info: record },
  };
  vm.createContext(sandbox);
  vm.runInContext(SOURCE, sandbox, { filename: 'auth_client.js' });
  await sandbox.window.sitewiseAuth.ready;
  return {
    bridge: sandbox.window.sitewiseAuth,
    navigations,
    listeners,
    assurance,
    sessionState,
    enrollCalls,
    unenrollCalls,
    logs,
  };
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

test('restore: no session leaves routing to the router guard (no JS redirect)', async () => {
  const { navigations } = await boot({
    pathname: '/admin',
    role: 'admin',
    aal: 'aal2',
    sessionPresent: false,
  });
  // enforceStaffAssurance only runs for restored sessions; an anonymous boot
  // is handled by app.dart's guard (anonymous → /login?next=…).
  assert.deepStrictEqual(navigations, []);
});

// --- F2: token refresh re-confirms staff assurance -------------------------

test('refresh: TOKEN_REFRESHED downgrading to aal1 on /admin routes to verify', async () => {
  const { navigations, listeners, sessionState } = await boot({
    pathname: '/admin',
    role: 'admin',
    aal: 'aal2',
  });
  assert.deepStrictEqual(navigations, [], 'aal2 restore must not redirect');
  sessionState.aal = 'aal1'; // the rotated session has not completed MFA
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

// --- TOTP enrollment metadata: issuer + account label (A, B, C, D) ----------

test('enroll (A): forwards issuer=SiteWise, factorType=totp and friendly name', async () => {
  const { bridge, enrollCalls } = await boot({
    pathname: '/staff/mfa',
    role: 'agent',
    aal: 'aal1',
    factors: [],
  });
  await bridge.mfaEnrollStart();
  assert.strictEqual(enrollCalls.length, 1, 'exactly one enroll call');
  assert.strictEqual(enrollCalls[0].factorType, 'totp');
  assert.strictEqual(enrollCalls[0].issuer, 'SiteWise');
  assert.ok(enrollCalls[0].friendlyName, 'friendly name still set');
});

test('enroll (A): correct server metadata keeps the Supabase QR and succeeds', async () => {
  const { bridge } = await boot({
    pathname: '/staff/mfa',
    role: 'agent',
    aal: 'aal1',
    factors: [],
  });
  const result = await bridge.mfaEnrollStart();
  assert.ok(result.qr, 'QR must come from the Supabase enroll response');
  assert.ok(result.secret);
});

test('enroll (B): a verified factor routes to /staff/verify and never enrolls', async () => {
  const { bridge, navigations, enrollCalls } = await boot({
    pathname: '/staff/mfa',
    role: 'agent',
    aal: 'aal1',
  });
  await assert.rejects(() => bridge.mfaEnrollStart(), /already enrolled/i);
  assert.deepStrictEqual(navigations, ['/staff/verify']);
  assert.strictEqual(enrollCalls.length, 0, 'no new factor enrolled');
});

test('enroll (C): wrong account label is rejected, rolled back and never shown', async () => {
  const wrongIdentityUri =
    'otpauth://totp/SiteWise:other.person@x.test?secret=TOTPSECRET123&issuer=SiteWise';
  const { bridge, unenrollCalls, logs } = await boot({
    pathname: '/staff/mfa',
    role: 'agent',
    aal: 'aal1',
    factors: [],
    enrollUri: wrongIdentityUri,
  });
  await assert.rejects(() => bridge.mfaEnrollStart(), /wrong account identity/i);
  assert.deepStrictEqual(unenrollCalls, ['f-new'], 'fresh mislabelled factor rolled back');
  const state = JSON.parse(bridge.snapshot());
  assert.strictEqual(state.mfaEnrollQr, null, 'no QR presented for a mislabelled factor');
  assert.strictEqual(state.mfaEnrollSecret, null, 'no secret retained');
  const everythingLogged = logs.join('\n');
  assert.ok(!everythingLogged.includes('TOTPSECRET123'), 'secret never logged');
  assert.ok(!everythingLogged.includes('otpauth://'), 'provisioning URI never logged');
  assert.ok(!everythingLogged.includes('other.person@x.test'), 'labels/emails never logged');
});

test('enroll (C): a localhost issuer from the server is detected, not silently accepted', async () => {
  const localhostUri =
    'otpauth://totp/localhost:3000:staff%40x.test?secret=TOTPSECRET123&issuer=http%3A%2F%2Flocalhost%3A3000';
  const { bridge, unenrollCalls } = await boot({
    pathname: '/staff/mfa',
    role: 'agent',
    aal: 'aal1',
    factors: [],
    enrollUri: localhostUri,
  });
  await assert.rejects(() => bridge.mfaEnrollStart(), /wrong account identity/i);
  assert.deepStrictEqual(unenrollCalls, ['f-new']);
});

test('enroll (D): the account label follows each authenticated session email', async () => {
  for (const email of ['agent.a@x.test', 'agent.b@x.test']) {
    const { bridge } = await boot({
      pathname: '/staff/mfa',
      role: 'agent',
      aal: 'aal1',
      factors: [],
      email,
    });
    const result = await bridge.mfaEnrollStart();
    assert.ok(result.qr, 'QR generated for ' + email);
  }
  // A URI minted for a different identity must not pass validation.
  const staleIdentityUri =
    'otpauth://totp/SiteWise:agent.a@x.test?secret=TOTPSECRET123&issuer=SiteWise';
  const { bridge, unenrollCalls } = await boot({
    pathname: '/staff/mfa',
    role: 'agent',
    aal: 'aal1',
    factors: [],
    email: 'agent.b@x.test',
    enrollUri: staleIdentityUri,
  });
  await assert.rejects(() => bridge.mfaEnrollStart(), /wrong account identity/i);
  assert.deepStrictEqual(unenrollCalls, ['f-new']);
});

// --- MFA verification lifecycle (E) -----------------------------------------

test('verify (E): correct six-digit code completes the challenge at aal2', async () => {
  const { bridge, navigations } = await boot({
    pathname: '/staff/verify',
    role: 'admin',
    aal: 'aal1',
  });
  assert.strictEqual(await bridge.mfaChallengeStart(), 'challenge');
  assert.strictEqual(await bridge.mfaChallengeVerify('123456'), true);
  assert.deepStrictEqual(navigations, [], 'no auto-redirect; UI routes after success');
});

test('verify (E): incorrect six-digit code preserves the server rejection', async () => {
  const { bridge, navigations } = await boot({
    pathname: '/staff/verify',
    role: 'admin',
    aal: 'aal1',
    verifyError: new Error('Invalid TOTP code detected'),
  });
  await bridge.mfaChallengeStart();
  await assert.rejects(() => bridge.mfaChallengeVerify('000000'), /Invalid TOTP code/i);
  assert.deepStrictEqual(navigations, []);
});

test('verify (E): reusing a completed challenge fails closed (expired challenge)', async () => {
  const { bridge } = await boot({ pathname: '/staff/verify', role: 'admin', aal: 'aal1' });
  await bridge.mfaChallengeStart();
  await bridge.mfaChallengeVerify('123456');
  await assert.rejects(() => bridge.mfaChallengeVerify('123456'), /Challenge expired/i);
});

test('verify (E): missing session fails closed with the session-expired message', async () => {
  const { bridge } = await boot({
    pathname: '/staff/verify',
    role: 'admin',
    aal: 'aal1',
    sessionPresent: false,
  });
  await assert.rejects(() => bridge.mfaChallengeStart(), /session expired/i);
});

// --- Security regression (F) ------------------------------------------------

test('security (F): an entrepreneur on the staff portal is rejected, never routed', async () => {
  const { bridge, navigations } = await boot({
    pathname: '/staff/signin',
    role: 'entrepreneur',
    aal: 'aal1',
  });
  await assert.rejects(
    () => bridge.password('staff@x.test', 'pw', true, '', 'staff'),
    /not a staff account/i,
  );
  assert.deepStrictEqual(navigations, []);
});

test('security (F): an admin on the entrepreneur portal is rejected and directed to staff', async () => {
  const { bridge, navigations } = await boot({ pathname: '/login', role: 'admin', aal: 'aal1' });
  await assert.rejects(
    () => bridge.password('staff@x.test', 'pw', true, '', 'entrepreneur'),
    /Agent & Admin portal/i,
  );
  assert.deepStrictEqual(navigations, []);
});

test('security (F): an unknown role never routes to a workspace', async () => {
  const { bridge, navigations } = await boot({
    pathname: '/login',
    role: 'superuser',
    aal: 'aal2',
  });
  await assert.rejects(
    () => bridge.password('staff@x.test', 'pw', true, '', 'staff'),
    /unsupported account role/i,
  );
  assert.deepStrictEqual(navigations, []);
});

// --- Regression: GoTrue factor shape (factor_type, not type) -----------------

test('regression: GoTrue-shaped verified factor — returning staff routes to verify, no enroll', async () => {
  const { bridge, navigations, enrollCalls } = await boot({
    pathname: '/login',
    role: 'agent',
    aal: 'aal1',
    factors: GOTRUE_VERIFIED_FACTOR,
  });
  await bridge.password('staff@x.test', 'pw', true, '', 'staff');
  assert.deepStrictEqual(navigations, ['/staff/verify']);
  assert.strictEqual(enrollCalls.length, 0);
});

test('regression: GoTrue-shaped verified factor at aal2 — straight to the dashboard', async () => {
  const { bridge, navigations, enrollCalls } = await boot({
    pathname: '/login',
    role: 'agent',
    aal: 'aal2',
    factors: GOTRUE_VERIFIED_FACTOR,
  });
  await bridge.password('staff@x.test', 'pw', true, '', 'staff');
  assert.deepStrictEqual(navigations, ['/agent']);
  assert.strictEqual(enrollCalls.length, 0);
});

test('regression: enroll page with a GoTrue-shaped verified factor never re-enrolls', async () => {
  const { bridge, navigations, enrollCalls } = await boot({
    pathname: '/staff/mfa',
    role: 'agent',
    aal: 'aal1',
    factors: GOTRUE_VERIFIED_FACTOR,
  });
  await assert.rejects(() => bridge.mfaEnrollStart(), /already enrolled/i);
  assert.deepStrictEqual(navigations, ['/staff/verify']);
  assert.strictEqual(enrollCalls.length, 0);
});

// --- Post-verification completion (the reported failure point) ---------------

test('post-verify: enrollVerify then complete routes agent to /agent (no re-enroll)', async () => {
  const { bridge, navigations, enrollCalls, unenrollCalls } = await boot({
    pathname: '/staff/mfa',
    role: 'agent',
    aal: 'aal1',
    factors: [],
  });
  await bridge.mfaEnrollStart();
  assert.strictEqual(await bridge.mfaEnrollVerify('123456'), true);
  await bridge.complete();
  assert.deepStrictEqual(navigations, ['/agent']);
  assert.strictEqual(enrollCalls.length, 1, 'exactly one enrollment');
  assert.deepStrictEqual(unenrollCalls, [], 'nothing rolled back on success');
});

test('post-verify: challengeVerify then complete routes admin to /admin', async () => {
  const { bridge, navigations } = await boot({
    pathname: '/staff/verify',
    role: 'admin',
    aal: 'aal1',
  });
  await bridge.mfaChallengeStart();
  assert.strictEqual(await bridge.mfaChallengeVerify('123456'), true);
  await bridge.complete();
  assert.deepStrictEqual(navigations, ['/admin']);
});

test('post-verify: an already-aal2 session is never sent back to /staff/verify', async () => {
  const { bridge, navigations } = await boot({
    pathname: '/admin',
    role: 'admin',
    aal: 'aal2',
    factors: GOTRUE_VERIFIED_FACTOR,
  });
  await bridge.complete();
  // complete() routes to the account's own home — never back to verification.
  assert.deepStrictEqual(navigations, ['/admin']);
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