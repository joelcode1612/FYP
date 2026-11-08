import { createClient } from '@supabase/supabase-js';

// --- Centralized API configuration -----------------------------------------
// The Jaspr SSR server proxies /api/* to the intended FastAPI backend, so
// browser requests are same-origin by default. NO host or port is baked into
// this bundle: the only override is the `sitewise-api` meta tag emitted by
// lib/main.server.dart before this (deferred) script runs. An empty/absent
// content means "same-origin proxy". Deployments that deliberately host the
// API elsewhere set SITEWISE_PUBLIC_API_BASE on the Jaspr process instead of
// editing generated assets.
const apiMeta = document.querySelector('meta[name="sitewise-api"]');
const api = apiMeta ? apiMeta.content.trim().replace(/\/+$/, '') : '';
// Same-origin public configuration generated from the intended backend's
// .env by tool/gen_auth_config.js. Contains ONLY the project URL and the
// publishable (client-safe) key — never the secret/service-role key. It lets
// the sign-in/sign-up pages initialize Supabase even while the API boots.
// Root-relative on purpose: this bundle also runs on /auth/callback, /login,
// /signup, ... where a relative URL would resolve to /<route>/auth-config.json.
const publicConfigUrl = '/auth-config.json';
let client;
let state = {
  configured: false,
  backendAvailable: false,
  user: null,
  profile: null,
  error: '',
  mfaRequired: false,
  mfaFactorId: null,
  mfaChallengeId: null,
  // Staff enrollment ("Secure Your Staff Account"): populated after a staff
  // sign-in when no verified TOTP factor exists. QR is the Supabase-generated
  // SVG data URI; secret is shown for manual authenticator entry.
  mfaEnrollmentRequired: false,
  mfaEnrollFactorId: null,
  mfaEnrollQr: null,
  mfaEnrollSecret: null,
};
const nextKey = 'sitewise.next';
const rememberKey = 'sitewise.remember';
// Flow context for the new-password page ('invite' | 'recovery') and the
// one-time password-set notice. Session-scoped display state; never carries
// credentials, tokens or invitation tokens.
const PASSWORD_FLOW_KEY = 'sitewise.passwordFlow';
const PASSWORD_NOTICE_KEY = 'sitewise.passwordNotice';
const STAFF_ROLES = ['agent', 'admin', 'administrator'];
// Canonical three-role model — mirrors backend/src/sitewise/domain/rbac.py.
// Legacy aliases are normalised on read; any OTHER value is unsupported and
// must fail closed instead of silently falling back to a least-privileged
// portal (the "admin lands on /entrepreneur" class of bug).
const CANONICAL_ROLES = ['entrepreneur', 'agent', 'admin'];
const ROLE_ALIASES = { administrator: 'admin', property_owner: 'entrepreneur', user: 'entrepreneur' };
const ROLE_HOME = { entrepreneur: '/entrepreneur', agent: '/agent', admin: '/admin' };

function canonicalRole(role) {
  const name = String(role || '').trim().toLowerCase();
  const mapped = Object.prototype.hasOwnProperty.call(ROLE_ALIASES, name) ? ROLE_ALIASES[name] : name;
  return CANONICAL_ROLES.includes(mapped) ? mapped : null;
}

// Explicit destination map. Returns null for an unsupported role — callers
// must treat null as "not authorised", never default to /entrepreneur.
function homeForRole(role) {
  const canonical = canonicalRole(role);
  return canonical ? ROLE_HOME[canonical] : null;
}

// --- MFA diagnostics ---------------------------------------------------------
// Development-only technical logging. NEVER log passwords, JWTs, access
// tokens, TOTP secrets, QR data URIs or recovery codes: only these safe error
// metadata fields are printed, picked explicitly rather than dumping the
// error object (which could carry response payloads).
const DEV_CONSOLE = /^(localhost|127\.0\.0\.1)$/.test(location.hostname);
function diag(scope, error) {
  if (!DEV_CONSOLE || !error) return;
  console.warn('[sitewise-auth]', scope, {
    name: typeof error.name === 'string' ? error.name : undefined,
    message: typeof error.message === 'string' ? error.message : String(error),
    code: error.code,
    status: error.status,
  });
}

// Builds an Error tagged with a stable machine code (the Dart flow maps codes
// / messages to specific UI states) and logs the original cause in dev mode.
function authError(code, message, cause) {
  const error = new Error(message);
  error.code = code;
  if (cause) diag(code, cause);
  return error;
}

// --- Callback URL strategy ---------------------------------------------------
// This application must serve TWO Supabase callback styles:
//   * PKCE code callbacks (Google OAuth, signup confirmation and password
//     recovery links requested by this app): `?code=...` query parameters,
//     handled by the default flowType 'pkce' client.
//   * Implicit token callbacks (server-generated invitation emails): the
//     tokens arrive in the URL FRAGMENT (`#access_token=...`). auth-js throws
//     "Not a valid PKCE flow url." when a 'pkce' client meets them, so these
//     documents must build their client with flowType 'implicit' and let the
//     SDK consume the tokens itself. Application code NEVER parses, stores or
//     reconstructs the tokens.
// The URL is inspected exactly ONCE at document load - before the Supabase SDK
// initialises and strips the fragment/code - because every later decision
// (client flow type, session wait, error mapping) needs the same answer for
// the whole document lifetime. Only booleans and stable error codes are kept;
// never the token values themselves.
const CALLBACK_ERROR_MESSAGES = {
  otp_expired: 'This link has expired. Request a new email link from the sign-in page.',
  access_denied: 'This link was cancelled or is no longer valid. Request a new email link.',
  over_email_send_rate_limit: 'Too many emails were requested. Wait a moment before requesting a new one.',
};
const documentCallback = (() => {
  const params = new URLSearchParams(location.search);
  const hash = location.hash.startsWith('#') ? location.hash.slice(1) : location.hash;
  // Merge fragment parameters behind the query ones (query wins), mirroring
  // how auth-js parses callback URLs where both styles can appear.
  for (const [key, value] of new URLSearchParams(hash)) {
    if (!params.has(key)) params.append(key, value);
  }
  const hasTokens = params.has('access_token') || params.has('refresh_token');
  const hasCode = params.has('code');
  const hasTokenHash = params.has('token_hash');
  const hasError = !!(params.get('error') || params.get('error_code') || params.get('error_description'));
  const errorCode = params.get('error_code') || params.get('error') || null;
  return {
    hasCallbackParams: hasTokens || hasCode || hasTokenHash || hasError,
    isFragmentTokenCallback: hasTokens,
    isCodeCallback: hasCode,
    errorCode,
    // Fixed, user-safe messages keyed by the stable code - the raw URL
    // error_description is never echoed (it could contain link internals).
    errorMessage: hasError
      ? (CALLBACK_ERROR_MESSAGES[errorCode || '']
         || 'This email link could not be completed. Open the most recent link, or sign in from the sign-in page.')
      : null,
  };
})();

// Inspects the NON-SECRET metadata of an otpauth://totp provisioning URI:
// the issuer (query parameter and label prefix) and the account label. The
// URI itself and its secret parameter are never returned, logged or stored —
// only these booleans leave this function.
function inspectTotpUri(uri, expectedEmail) {
  if (!uri || !/^otpauth:\/\/totp\//i.test(uri)) {
    return { present: false, parseable: false, issuerOk: false, accountOk: false };
  }
  let label = '';
  let issuerParam = '';
  try {
    const parsed = new URL(uri);
    label = decodeURIComponent((parsed.pathname || '').replace(/^\/+/, ''));
    issuerParam = (parsed.searchParams.get('issuer') || '').trim();
  } catch (_) {
    return { present: true, parseable: false, issuerOk: false, accountOk: false };
  }
  // Standard key-URI format: otpauth://totp/<issuer>:<account>?...&issuer=...
  let labelIssuer = '';
  let labelAccount = label;
  const split = label.indexOf(':');
  if (split >= 0) {
    labelIssuer = label.slice(0, split).trim();
    labelAccount = label.slice(split + 1).trim();
  }
  const issuerOk = /^sitewise$/i.test(issuerParam) || /^sitewise$/i.test(labelIssuer);
  const accountOk =
    !!expectedEmail && labelAccount.toLowerCase() === String(expectedEmail).toLowerCase();
  return { present: true, parseable: true, issuerOk, accountOk };
}
// Staff workspaces that require a completed-MFA (aal2) session to view. The
// MFA routes themselves (/staff/*) are deliberately excluded so the verify and
// enrollment screens never redirect to themselves.
const STAFF_WORKSPACE = /^\/(admin|agent)(\/|$)/;
const storage = {
  getItem: key => sessionStorage.getItem(key) ?? localStorage.getItem(key),
  setItem(key, value) {
    const remember = localStorage.getItem(rememberKey) !== 'false';
    const target = remember ? localStorage : sessionStorage;
    const other = remember ? sessionStorage : localStorage;
    target.setItem(key, value);
    other.removeItem(key);
  },
  removeItem(key) { sessionStorage.removeItem(key); localStorage.removeItem(key); },
};

async function apiRequest(path, method = 'GET', body) {
  if (!path.startsWith('/api/')) throw new Error('Invalid API route.');
  const { data, error } = await client.auth.getSession();
  if (error || !data.session) throw new Error('Sign in to continue.');
  const response = await fetch(api + path, {
    method,
    credentials: 'same-origin',
    headers: { Authorization: 'Bearer ' + data.session.access_token, 'Content-Type': 'application/json' },
    body: body == null ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(15000),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    // FastAPI error shape: {detail: string} or {detail: {code, message}}.
    const detail = payload.detail;
    const message = typeof detail === 'string'
      ? detail
      : detail?.message || 'The data service could not complete this request.';
    const err = new Error(message);
    err.code = typeof detail === 'object' ? detail?.code : undefined;
    err.status = response.status;
    throw err;
  }
  return payload;
}

// The authoritative profile lives server-side: GET /api/v1/auth/me verifies
// the bearer token against Supabase, provisions the profile on first sign-in
// and returns the SERVER-assigned role. No client-submitted role is ever sent.
async function profile() {
  const { data: before, error: sessionError } = await client.auth.getSession();
  const identityId = before?.session?.user?.id;
  if (sessionError || !identityId) throw new Error('Sign in to continue.');
  // On account switching, discard the old role and its SSR mirror immediately.
  if (state.profile?.user_id && state.profile.user_id !== identityId) {
    state.profile = null;
    clearSessionCookies();
  }
  const response = await apiRequest('/api/v1/auth/me', 'GET');
  const { data: after } = await client.auth.getSession();
  if (response.user_id !== identityId || after?.session?.user?.id !== identityId) {
    state.profile = null;
    clearSessionCookies();
    throw new Error('The authenticated identity changed. Please sign in again.');
  }
  try {
    assertActiveAccount(response);
  } catch (error) {
    state.profile = null;
    clearSessionCookies();
    throw error;
  }
  state.user = { id: identityId, email: after.session.user.email };
  state.profile = response;
  state.backendAvailable = true;
  state.error = '';
  await syncSessionCookies();
}

// The backend's /auth/me is authoritative for role AND account_status. A
// pending or suspended identity must never be routed into a workspace, and a
// missing role must never silently fall back to the least-privileged one.
function assertActiveAccount(profile) {
  const status = String(profile?.account_status || '').toLowerCase();
  if (status !== 'active') {
    const error = new Error(
      status === 'pending'
        ? 'Your account is pending approval. An administrator must activate it before you can continue.'
        : status === 'suspended'
          ? 'Your account is suspended. Please contact a Sitewise administrator.'
          : 'Account status could not be verified. Please contact support.',
    );
    error.code = 'account_' + status;
    throw error;
  }
  if (!profile?.role) {
    throw new Error('The server did not return an authorized role. Please sign in again.');
  }
}

function isStaffRole(role) {
  return STAFF_ROLES.includes(role);
}

// GoTrue returns TOTP factors with a `factor_type` field; some SDK shapes use
// `type`. Reading only `.type` made every staff gate treat a verified factor
// as missing — the post-verification "Verification Unavailable" bug.
function factorType(factor) {
  return String((factor && (factor.type || factor.factor_type)) || '').toLowerCase();
}

// Reads the staff-factor and assurance state from the PERSISTED session
// itself: `session.user.factors` (populated by Supabase) and the access
// token's `aal` claim. No extra network round-trips, so every document sees
// the SAME answer — routing decisions can never flip between /staff/mfa and
// /staff/verify. This is the same token the FastAPI backend enforces.
async function sessionStaffState() {
  try {
    const { data, error } = await client.auth.getSession();
    if (error || !data?.session) return { factor: null, aal: null };
    const factors = data.session.user?.factors || [];
    const factor = factors.find(f => factorType(f) === 'totp' && f.status === 'verified') || null;
    let aal = null;
    try {
      const payload = JSON.parse(atob(data.session.access_token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
      aal = payload.aal || null;
    } catch (_) { /* opaque or unreadable token: treat as aal-unknown */ }
    return { factor, aal };
  } catch (_) {
    return { factor: null, aal: null };
  }
}

async function hasVerifiedTotpFactor() {
  const { factor } = await sessionStaffState();
  return !!factor;
}

// Staff rule: agents/administrators MUST have a verified TOTP factor. A staff
// session without one is routed to the enrollment screen instead of a
// workspace. Entrepreneurs keep MFA optional — never forced here. (The gate
// itself lives in ensureStaffAssurance(), which reads the persisted session.)

// --- SSR session mirror -------------------------------------------------------
// The server renders every route before the browser bundle runs, so it cannot
// read localStorage. Mirror the minimum the server needs (who you are + the
// access token) into cookies the SSR pass reads back in `installServerSession`.
// Only the public profile fields go into the session cookie - the token cookie
// is the same bearer token the browser already sends on every API call.
const SESSION_COOKIE = 'sitewise_session';
const TOKEN_COOKIE = 'sitewise_token';

function writeCookie(name, value) {
  const secure = location.protocol === 'https:' ? '; Secure' : '';
  // 8h: long enough for a working session, short enough not to linger.
  document.cookie = `${name}=${value}; Path=/; SameSite=Lax; Max-Age=28800${secure}`;
}

function clearCookie(name) {
  document.cookie = `${name}=; Path=/; SameSite=Lax; Max-Age=0`;
}

function encodeSession(profile) {
  const json = JSON.stringify({
    user_id: profile.user_id || state.user?.id || null,
    role: profile.role || null,
    name: profile.full_name || null,
    email: profile.email || state.user?.email || null,
  });
  const bytes = new TextEncoder().encode(json);
  let binary = '';
  bytes.forEach(b => { binary += String.fromCharCode(b); });
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function syncSessionCookies() {
  const { data } = await client.auth.getSession();
  if (!data.session) return clearSessionCookies();
  writeCookie(TOKEN_COOKIE, data.session.access_token);
  if (state.profile) writeCookie(SESSION_COOKIE, encodeSession(state.profile));
}

function clearSessionCookies() {
  clearCookie(SESSION_COOKIE);
  clearCookie(TOKEN_COOKIE);
}

// A single document must issue at most ONE auth-driven navigation. Overlapping
// async paths (OAuth callback completion, a SIGNED_OUT event, a re-mounted
// @client widget calling complete() again) each used to call location.assign,
// which made the browser start two document loads — the "page runs twice"
// symptom. replace() also keeps transient /login and /auth/callback documents
// out of history, so Back cannot re-execute the sign-in flow automatically.
let navigationStarted = false;
function navigate(url, reason) {
  if (navigationStarted) return;
  navigationStarted = true;
  // Development-only breadcrumb: which gate decided to navigate, and where.
  // URLs only — never tokens, codes or profile contents.
  diag('navigate', { name: 'Navigation', message: (reason || 'unspecified') + ' -> ' + url });
  location.replace(url);
}

function rememberNext() {
  const next = new URL(location.href).searchParams.get('next');
  if (next?.startsWith('/') && !next.startsWith('//')) sessionStorage.setItem(nextKey, next);
}

function goHome() {
  // Never invent a role. The profile is always the backend-verified response
  // from /api/v1/auth/me, and the destination map is explicit per role.
  const home = homeForRole(state.profile?.role);
  if (!home) {
    // Fail closed: an unsupported/missing role must never fall back to the
    // entrepreneur workspace. Drop the stale mirror and surface the error.
    state.profile = null;
    clearSessionCookies();
    throw new Error('The server returned an unsupported account role. Please contact a Sitewise administrator.');
  }
  const next = sessionStorage.getItem(nextKey);
  sessionStorage.removeItem(nextKey);
  // Never allow a return URL to bypass the user's server-assigned role.
  navigate(next && (next === home || next.startsWith(home + '/') || next.startsWith(home + '?')) ? next : home, 'role-home:' + home);
}

// Portal context passed by the sign-in forms ('entrepreneur' | 'staff'). It is
// a VALIDATION context only: it can reject an account whose backend-assigned
// role does not belong to the portal, and can never grant or change a role.
function assertPortalRole(expectedPortal) {
  if (expectedPortal !== 'entrepreneur' && expectedPortal !== 'staff') return;
  const role = canonicalRole(state.profile?.role);
  if (!role) {
    state.profile = null;
    clearSessionCookies();
    throw new Error('The server returned an unsupported account role. Please contact a Sitewise administrator.');
  }
  if (expectedPortal === 'staff' && role === 'entrepreneur') {
    state.profile = null;
    clearSessionCookies();
    throw new Error('This is not a staff account. Please sign in through the Entrepreneur portal.');
  }
  if (expectedPortal === 'entrepreneur' && role !== 'entrepreneur') {
    // Agents and administrators sign in through the Agent & Admin portal,
    // where the mandatory TOTP MFA gate is enforced. They are never routed
    // into the entrepreneur workspace from the public portal.
    state.profile = null;
    clearSessionCookies();
    throw new Error('Staff accounts sign in through the Agent & Admin portal.');
  }
}

// Single source of truth for the staff MFA gate, reused by sign-in, session
// restore and token refresh. Decides ONLY from the persisted session: the
// token's `aal` claim (what the backend enforces) plus the session's own
// verified-factor list. Returns 'ok' (non-staff, or staff at aal2), 'enroll'
// (no verified TOTP factor yet) or 'verify' (factor present, challenge owed).
async function ensureStaffAssurance() {
  if (!state.profile || !isStaffRole(state.profile.role)) return 'ok';
  const { factor, aal } = await sessionStaffState();
  if (aal === 'aal2') return 'ok'; // verified session — never bounce back here
  if (!factor) return 'enroll'; // no verified TOTP factor on the account yet
  return 'verify'; // factor verified, but this session still owes a challenge
}

// A restored or refreshed session must not leave a staff workspace rendered at
// aal1. The server guard is the authoritative backstop; this routes the client
// to re-verify (or enroll) so a stale staff page is never shown. Only staff
// workspaces are enforced - /staff/*, /login and /entrepreneur are left alone.
async function enforceStaffAssurance() {
  if (!STAFF_WORKSPACE.test(location.pathname)) return;
  if (!state.profile || !isStaffRole(state.profile.role)) return;
  let status;
  try {
    status = await ensureStaffAssurance();
  } catch (_) {
    status = 'verify'; // fail closed when assurance cannot be confirmed
  }
  if (status === 'enroll') navigate('/staff/mfa', 'enforceStaffAssurance:enroll');
  else if (status === 'verify') navigate('/staff/verify', 'enforceStaffAssurance:verify');
}

// Route after any successful sign-in: ALWAYS validate the authoritative
// server profile first, then (when the calling portal is known) reject
// portal/role mismatches, then staff-without-a-factor go to enrollment, staff
// without aal2 go to verification, and everyone else to their role's workspace.
async function finishSignIn(expectedPortal) {
  // Never choose a workspace using a previously authenticated account's
  // profile. The backend resolves the role from the current signed JWT.
  await profile();
  assertActiveAccount(state.profile);
  // Portal/role cross-check BEFORE any MFA step or workspace routing, so a
  // mismatched account stops here with a clear message instead of being sent
  // through the wrong portal's flow.
  assertPortalRole(expectedPortal);
  const status = await ensureStaffAssurance();
  if (status === 'enroll') {
    state.mfaEnrollmentRequired = true;
    navigate('/staff/mfa', 'finishSignIn:enroll');
    return;
  }
  if (status === 'verify') {
    navigate('/staff/verify', 'finishSignIn:verify');
    return;
  }
  goHome();
}

// Initialize from the local API's public configuration.
//
// The API is a separate local process. If it is started *after* this page was
// loaded, the one-shot probe used to leave `configured=false` forever and the
// Google buttons stayed disabled until a manual refresh. `initialize()` is
// now reusable: the initial `ready` promise retries a few times, and a
// background poller keeps trying while the API is down, then re-enables the
// rendered buttons in place (no refresh needed).
// Load the public Supabase configuration. It is served by the Jaspr server
// itself, so it is available even when the FastAPI backend is still starting.
// The old code probed `api + '/health'` here and then ignored the result;
// readiness is now reported separately by probeBackend() below.
async function loadConfig() {
  const response = await fetch(publicConfigUrl, {
    cache: 'no-store',
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new Error('The authentication configuration is unavailable.');
  const config = await response.json();
  if (!config.configured || !config.supabaseUrl || !config.supabasePublishableKey) {
    throw new Error('The authentication configuration is incomplete. Run npm run gen-auth-config.');
  }
  return config;
}

// Non-blocking liveness probe against the same-origin proxy. Exposed through
// snapshot() so the launcher/verification tools can confirm which backend the
// browser is actually talking to. Never gates Supabase initialization.
async function probeBackend() {
  try {
    const response = await fetch(api + '/health', {
      cache: 'no-store',
      signal: AbortSignal.timeout(3000),
    });
    state.backendAvailable = response.ok;
  } catch (_) {
    state.backendAvailable = false;
  }
}

// Profile loading is optional when merely restoring an existing session on a
// page load. Sign-in / callback flows use the strict profile() instead so an
// unreachable backend or a non-active account is reported, not papered over.
async function tryProfile() {
  try {
    await profile();
  } catch (error) {
    state.profile = null;
    // No SSR session is usable when the backend cannot revalidate identity,
    // regardless of whether the cause is account status or network failure.
    clearSessionCookies();
    state.error = error?.message || 'Could not verify the account.';
  }
}

// Reads the Supabase session, briefly waiting on OAuth/invite/recovery
// callbacks while `detectSessionInUrl` exchanges the PKCE authorization code
// or consumes the invitation fragment tokens. Without this the /auth/callback
// page can observe a null session before the exchange finishes and report
// "no authenticated session was returned".
async function currentSession() {
  // Callback presence is captured ONCE at document load (see documentCallback):
  // the SDK strips the fragment and the PKCE code during init, so re-reading
  // location.href here races the very exchange this loop must wait for.
  let lastError = null;
  for (let attempt = 0; attempt < 10; attempt++) {
    const { data, error } = await client.auth.getSession();
    if (data?.session) return data.session;
    if (error) lastError = error;
    if (!documentCallback.hasCallbackParams) break;
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  if (lastError) throw lastError;
  return null;
}

// Single-flight init: the retry loop AND the background recovery poller can
// call initialize() in the same tick. Without this lock two Supabase clients
// and two onAuthStateChange subscriptions could be created, duplicating every
// session event (and therefore every redirect) on the page.
let initInFlight = null;

// Set by the SDK's PASSWORD_RECOVERY event on the callback document, BEFORE
// doComplete stashes the flow context for the next document (/reset-password).
let passwordFlowContext = null;
function initialize() {
  if (!initInFlight) {
    initInFlight = doInitialize().catch(error => {
      initInFlight = null; // allow a later retry after a genuine failure
      throw error;
    });
  }
  return initInFlight;
}

async function doInitialize() {
  const config = await loadConfig();
  if (client) { await probeBackend(); return; }   // already recovered; never create a second client
  client = createClient(config.supabaseUrl, config.supabasePublishableKey, {
    auth: {
      // 'implicit' ONLY on documents whose URL carries fragment tokens (the
      // server-generated invitation-link style); every other document keeps
      // the PKCE flow, so OAuth / signup / recovery code exchanges are
      // unchanged. See the callback-strategy note at the top of this file.
      flowType: documentCallback.isFragmentTokenCallback ? 'implicit' : 'pkce',
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
      storage,
    },
  });
  state.configured = true;
  state.error = '';
  announceReady();

  // Subscribe BEFORE reading the session: the PKCE code exchange on
  // /auth/callback emits SIGNED_IN asynchronously during client init.
  client.auth.onAuthStateChange((event, session) => {
    // A recovery link recognised by Supabase emits PASSWORD_RECOVERY; the
    // callback completion stashes the reset page's flow context from it.
    if (event === 'PASSWORD_RECOVERY') passwordFlowContext = 'recovery';
    if (event === 'SIGNED_OUT') {
      state.user = null;
      state.profile = null;
      clearSessionCookies();
      if (/^\/(admin|agent|entrepreneur|staff|owner)(\/|$)/.test(location.pathname))
        navigate(location.pathname.startsWith('/staff/') ? '/staff/signin' : '/login');
    } else if (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') {
      if (session?.user?.id && state.profile?.user_id !== session.user.id) {
        state.profile = null;
        clearSessionCookies();
      }
      // Supabase recommends deferring auth-client calls outside this callback.
      // The API fetch revalidates the current signed identity before a cookie
      // mirror is issued, including when the token refreshes.
      setTimeout(() => {
        profile()
          .then(() => enforceStaffAssurance())
          .catch(() => { state.profile = null; clearSessionCookies(); });
      }, 0);
    }
  });

  const session = await currentSession();
  if (session) {
    state.user = { id: session.user.id, email: session.user.email };
    await tryProfile(); // Backend verifies the token with Supabase, never trusts decoded claims.
    // A restored staff session on a workspace must re-confirm aal2 before the
    // page is allowed to stay; routes to /staff/verify or /staff/mfa otherwise.
    await enforceStaffAssurance();
  }
  void probeBackend();
  announceReady();
}

// The DOM refresh below is idempotent and must stay re-runnable (the config
// can recover late), but the readiness *event* must fire exactly once per
// document. It was previously dispatched twice on every normal page load —
// once right after client creation and once after the session read — which
// made every listener run twice ("the page runs two times").
let readyAnnounced = false;

// Update the server-rendered `lp-*` auth card after a late recovery: remove
// the disabled state from social buttons and replace the "not configured"
// note. The Dart widgets render once, so the DOM is updated directly.
function announceReady() {
  const isSignup = location.pathname.startsWith('/signup');
  const label = isSignup ? 'Google sign-up is managed by Supabase.'
                         : 'Google sign-in is managed by Supabase. Apple sign-in is not configured.';
  // Re-enable ONLY the Google social button once the auth config is loaded.
  // Apple (data-provider="apple") is permanently disabled and must keep its own
  // aria-label — a prior blanket `.lp-social` selector wrongly removed
  // `disabled` from and relabelled every social control, leaking
  // "Continue with Google" onto the disabled Apple button.
  document.querySelectorAll('.lp-social[data-provider="google"]').forEach(button => {
    button.removeAttribute('disabled');
  });
  document.querySelectorAll('.lp-social-note').forEach(note => { note.textContent = label; });
  document.querySelectorAll('.lp-alert.err').forEach(alert => {
    if (/Failed to fetch|not configured|unavailable/i.test(alert.textContent || '')) {
      alert.classList.add('is-hidden');
    }
  });
  if (!readyAnnounced) {
    readyAnnounced = true;
    window.dispatchEvent(new CustomEvent('sitewise:auth-ready'));
  }
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

const ready = (async () => {
  let lastError;
  // Short burst of retries covers a slow first load of the static public
  // config. Supabase initialization itself does NOT depend on the backend.
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      await initialize();
      return;
    } catch (error) {
      lastError = error;
      if (attempt < 3) await sleep(600);
    }
  }
  state.error = lastError?.message || 'Authentication initialization failed.';
  state.user = null;
  state.profile = null;

  // Keep polling while the API is down. One request every 3 seconds on
  // localhost is negligible and stops as soon as recovery succeeds.
  let polling = false;
  const poll = setInterval(async () => {
    if (polling || state.configured) { clearInterval(poll); return; }
    polling = true;
    try {
      await initialize();
      clearInterval(poll);
    } catch (_) {
      state.error = 'The Sitewise API is unavailable. Start FYP/backend (uvicorn on port 8000); sign-in will enable automatically once it is up.';
    } finally {
      polling = false;
    }
  }, 3000);
})();

// One callback completion per document. A rejected completion clears the slot
// so the user can genuinely retry instead of being stuck with a cached error.
let completionInFlight = null;
async function doComplete(next) {
  await ready;
  // Error-carrying callback URLs (expired invitation, cancelled flow, invalid
  // link) are swallowed inside the SDK's initialization - it would otherwise
  // surface much later as a misleading "no session" error. Fail fast with the
  // mapped, user-safe message: only the stable error code and fixed text are
  // used, never the raw URL description.
  if (documentCallback.errorMessage) {
    throw authError(
      'callback_' + (documentCallback.errorCode || 'invalid'),
      documentCallback.errorMessage,
      { name: 'CallbackUrlError', message: 'code=' + (documentCallback.errorCode || 'unspecified') },
    );
  }
  // /auth/callback is a full SSR document load. detectSessionInUrl exchanges
  // the PKCE code (or consumes the invitation fragment tokens) during client
  // initialization; currentSession() waits for that to finish before we
  // decide anything.
  const session = await currentSession();
  if (!session) {
    throw new Error('No authenticated session was created. Open the most recent email link, or sign in again.');
  }
  state.user = { id: session.user.id, email: session.user.email };

  // Password links (invitation and recovery) go to the new-password screen.
  // The flow context decides what happens AFTER the password is set, so it is
  // recorded here while the callback type is still known: recovery links are
  // PKCE code callbacks (requested from this app), invitation links are the
  // server-generated implicit-fragment kind, and Supabase's own
  // PASSWORD_RECOVERY event is authoritative when it fires.
  if (next === '/reset-password') {
    const context = passwordFlowContext
      || (documentCallback.isCodeCallback ? 'recovery' : 'invite');
    sessionStorage.setItem(PASSWORD_FLOW_KEY, context);
    navigate('/reset-password');
    return;
  }

  // Strict profile validation: the backend verifies the bearer token and
  // returns the authoritative role + account_status. The old code invented
  // an entrepreneur profile when the API was down, which hid the outage and
  // skipped the pending/suspended checks. Never grant access implicitly.
  await profile();
  await finishSignIn();
}

window.sitewiseAuth = {
  ready,
  snapshot: () => JSON.stringify(state),
  async google(remember = true) {
    await ready;
    if (!client) throw new Error(state.error || 'Authentication is not configured.');
    rememberNext();
    localStorage.setItem(rememberKey, String(remember));
    // Role is NEVER requested here: Google sign-ups are provisioned as
    // entrepreneurs server-side (auth.users trigger + backend /auth/me).
    const { error } = await client.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: location.origin + '/auth/callback' } });
    if (error) throw error;
  },
  async password(email, password, remember = true, mfaCode = '', expectedPortal = '') {
    await ready;
    if (!client) throw new Error(state.error || 'Authentication is not configured.');
    rememberNext();
    localStorage.setItem(rememberKey, String(remember));
    if (!mfaCode) {
      const { data, error } = await client.auth.signInWithPassword({ email, password });
      if (error) throw error;
      if (data.session) {
        state.user = { id: data.session.user.id, email: data.session.user.email };
        state.profile = null; // Never inherit a prior user's role.
        clearSessionCookies();
        // finishSignIn validates the authoritative profile against the
        // selected portal, requires staff AAL2 and routes AAL1 staff accounts
        // to /staff/verify. No challenge input remains on /login.
        await finishSignIn(expectedPortal);
        return;
      }
      // No session returned: either a TOTP MFA challenge is pending or the
      // account still needs email confirmation. Distinguish by listing factors.
      const { data: factorsData } = await client.auth.mfa.listFactors().catch(() => ({ data: null }));
      const totp = factorsData?.all?.find(f => f.type === 'totp' && f.status === 'verified');
      if (totp) throw new Error('The sign-in session could not be established. Please sign in again.');
      throw new Error('Check your email to confirm your account, then sign in.');
    }
    // The second factor is completed only on /staff/verify. The login form
    // never accepts a one-time code and must not reuse a password to retry it.
    throw new Error('Complete verification on the staff verification page.');
  },
  // New explicit second-step challenge: the earlier JS state is lost when
  // navigating from the password document to /staff/verify, so always obtain
  // a new factor/challenge using the valid Supabase AAL1 session.
  async mfaChallengeStart() {
    await ready;
    const { data: sessionResult, error: sessionError } = await client.auth.getSession();
    if (sessionError || !sessionResult?.session) {
      throw authError('mfa_session', 'Your sign-in session expired. Please sign in again.', sessionError);
    }
    try {
      await profile();
    } catch (error) {
      // profile() failures are already specific (backend unreachable, account
      // status, identity change). Preserve the message, tag the stage.
      throw authError('mfa_profile:' + (error?.code || 'error'), error?.message || 'Could not verify the account.', error);
    }
    if (!isStaffRole(state.profile?.role)) {
      throw authError('mfa_role', 'Staff role is required.', null);
    }
    // Session-derived state only: the token's aal claim and the session's
    // verified factor — no per-document network snapshots.
    const { factor, aal } = await sessionStaffState();
    if (aal === 'aal2') return 'verified';
    if (!factor) {
      navigate('/staff/mfa', 'challengeStart:no-verified-factor');
      return 'enroll';
    }
    const challenge = await client.auth.mfa.challenge({ factorId: factor.id });
    if (challenge.error || !challenge.data?.id) {
      throw authError('mfa_challenge', 'Could not start MFA challenge.', challenge.error);
    }
    state.mfaFactorId = factor.id;
    state.mfaChallengeId = challenge.data.id;
    state.mfaRequired = true;
    return 'challenge';
  },
  async mfaChallengeVerify(code) {
    await ready;
    if (!/^\d{6}$/.test(code)) throw new Error('Enter a valid six-digit code.');
    if (!state.mfaFactorId || !state.mfaChallengeId) throw new Error('Challenge expired. Restart verification.');
    const { error } = await client.auth.mfa.verify({
      factorId: state.mfaFactorId,
      challengeId: state.mfaChallengeId,
      code,
    });
    if (error) {
      // Supabase's own message ("Invalid TOTP code detected", etc.) is
      // preserved — it contains no secret material.
      throw authError('mfa_challenge_verify', error?.message || 'Code verification failed.', error);
    }
    // Confirm the upgraded session straight from the persisted token claim.
    const { aal: confirmedAal } = await sessionStaffState();
    if (confirmedAal !== 'aal2') {
      throw authError('mfa_assurance', 'MFA verification was not confirmed.', {
        name: 'AssuranceMismatch',
        message: 'session aal=' + confirmedAal,
      });
    }
    // Do not redirect here; the UI first displays the provider-backed success state.
    state.mfaRequired = false;
    state.mfaFactorId = null;
    state.mfaChallengeId = null;
    await profile();
    return true;
  },
  // --- Staff TOTP enrollment ("Secure Your Staff Account") -----------------
  // Native Supabase enrollment: the QR + secret come from Supabase, the
  // factor is only usable after a verified challenge. No custom storage.
  async mfaEnrollStart() {
    await ready;
    if (!client) throw authError('mfa_config', state.error || 'Authentication is not configured.', null);
    const { data: session, error: sessionError } = await client.auth.getSession();
    if (sessionError || !session?.session) {
      throw authError('mfa_session', 'Your sign-in session expired. Please sign in again.', sessionError);
    }
    try {
      await profile();
    } catch (error) {
      throw authError('mfa_profile:' + (error?.code || 'error'), error?.message || 'Could not verify the account.', error);
    }
    if (!isStaffRole(state.profile?.role)) {
      throw authError('mfa_role', 'Staff role is required.', null);
    }
    if (await hasVerifiedTotpFactor()) {
      // Returning user: NEVER generate a second QR code and NEVER delete or
      // replace the verified factor. Send them to the challenge screen.
      navigate('/staff/verify', 'enrollStart:already-verified-factor');
      throw authError('mfa_already_enrolled', 'Authenticator already enrolled.', null);
    }
    // Housekeeping: an abandoned earlier enrollment leaves an UNVERIFIED
    // factor behind, which would stack duplicate factors on every visit to
    // this screen. Remove unverified TOTP factors only — VERIFIED factors are
    // never deleted here; losing an authenticator is handled exclusively by
    // the administrator-authorized MFA recovery endpoint.
    const { data: existingFactors, error: listError } = await client.auth.mfa.listFactors();
    if (listError) throw authError('mfa_factors', 'Authenticator factors unavailable.', listError);
    for (const stale of existingFactors?.all || []) {
      if (factorType(stale) === 'totp' && stale.status !== 'verified') {
        const { error: staleError } = await client.auth.mfa.unenroll({ factorId: stale.id });
        if (staleError) diag('mfaEnrollStart/stale-unverified', staleError); // non-fatal
      }
    }
    const { data, error } = await client.auth.mfa.enroll({
      factorType: 'totp',
      // The authenticator must display "SiteWise" as the issuer and the
      // authenticated email as the account. auth-js >= 2.x forwards `issuer`
      // in the POST /factors body; when the server honours it the
      // provisioning URI carries otpauth://totp/SiteWise:<email>. When it
      // does not, GoTrue falls back to the project's Site URL — the
      // "localhost" label bug — which the metadata validation below detects.
      issuer: 'SiteWise',
      friendlyName: 'Sitewise Staff',
    });
    if (error) {
      // A pre-existing factor collides on the friendly name (422). If the
      // account already has a verified factor, recover to the challenge
      // screen instead of failing the setup.
      if (await hasVerifiedTotpFactor().catch(() => false)) {
        navigate('/staff/verify', 'enrollStart:self-heal-422');
        throw authError('mfa_already_enrolled', 'Authenticator already enrolled.', error);
      }
      throw authError('mfa_enroll', 'Could not start the authenticator setup. Please try again.', error);
    }
    state.mfaEnrollFactorId = data.id;
    state.mfaEnrollQr = data.totp?.qr_code || null;
    state.mfaEnrollSecret = data.totp?.secret || null;
    // Validate the non-secret metadata of the returned provisioning URI
    // against the authenticated session email. Only booleans are logged —
    // never the URI, its secret parameter, the QR data or the email itself.
    const sessionEmail = state.user?.email || state.profile?.email || null;
    const meta = inspectTotpUri(data.totp?.uri, sessionEmail);
    diag('mfaEnrollStart/uri-metadata', {
      name: 'TotpUriMetadata',
      message:
        'hasUri=' + meta.present +
        ' parseable=' + meta.parseable +
        ' issuerOk=' + meta.issuerOk +
        ' accountOk=' + meta.accountOk,
    });
    if (meta.present && meta.parseable && (!meta.issuerOk || !meta.accountOk)) {
      // The server generated a wrong issuer/account label (e.g. the project
      // Site URL leaking in as "localhost"). Roll back the just-created
      // UNVERIFIED factor so nothing stale or mislabelled remains — verified
      // factors are never touched here — and fail with an actionable error.
      // Codes from such a factor would still verify, but the acceptance
      // criterion is that the authenticator shows SiteWise + the right email.
      await client.auth.mfa
        .unenroll({ factorId: data.id })
        .catch((unenrollError) => diag('mfaEnrollStart/rollback', unenrollError));
      state.mfaEnrollFactorId = null;
      state.mfaEnrollQr = null;
      state.mfaEnrollSecret = null;
      throw authError(
        'mfa_enroll_metadata',
        'The authenticator setup was created with the wrong account identity, so it was not saved. ' +
          'An administrator must check the Supabase Auth "Site URL" configuration, then retry enrollment.',
        null,
      );
    }
    return { qr: state.mfaEnrollQr, secret: state.mfaEnrollSecret };
  },
  async mfaEnrollVerify(code) {
    await ready;
    if (!client) throw authError('mfa_config', state.error || 'Authentication is not configured.', null);
    if (!state.mfaEnrollFactorId) throw new Error('Start the enrollment again.');
    const challenge = await client.auth.mfa.challenge({ factorId: state.mfaEnrollFactorId });
    if (challenge.error) throw authError('mfa_enroll_challenge', 'Could not verify the enrollment code.', challenge.error);
    const verify = await client.auth.mfa.verify({
      factorId: state.mfaEnrollFactorId,
      challengeId: challenge.data.id,
      code,
    });
    if (verify.error) {
      throw authError('mfa_enroll_verify', verify.error?.message || 'Code verification failed.', verify.error);
    }
    // Only a verified factor satisfies the staff MFA requirement.
    state.mfaEnrollmentRequired = false;
    state.mfaEnrollFactorId = null;
    state.mfaEnrollQr = null;
    state.mfaEnrollSecret = null;
    // Confirm the upgraded session straight from the persisted token claim.
    const { aal: confirmedAal } = await sessionStaffState();
    if (confirmedAal !== 'aal2') {
      throw authError('mfa_assurance', 'MFA enrollment was not confirmed.', {
        name: 'AssuranceMismatch',
        message: 'session aal=' + confirmedAal,
      });
    }
    await profile();
    // UI displays verified success, then invokes complete() to route.
    return true;
  },
  // --- Password recovery (both portals) -------------------------------------
  // Native Supabase recovery email; the link lands on /auth/callback with a
  // recovery session and the app routes to /reset-password. No custom token.
  async resetPassword(email) {
    await ready;
    if (!client) throw new Error(state.error || 'Authentication is not configured.');
    localStorage.setItem(rememberKey, 'true');
    const { error } = await client.auth.resetPasswordForEmail(email, {
      redirectTo: location.origin + '/auth/callback?next=/reset-password',
    });
    if (error) throw error;
    return 'Check your email for the password reset link.';
  },
  async updatePassword(password) {
    await ready;
    if (!client) throw new Error(state.error || 'Authentication is not configured.');
    // Context is PEEKED, never cleared up front: a failed server-side update
    // must leave the flow in place so a retry stays in the same flow.
    const context = sessionStorage.getItem(PASSWORD_FLOW_KEY);
    // Supabase enforces the server-side password policy; the page's checklist
    // is a UX aid only and never replaces this validation.
    const { error } = await client.auth.updateUser({ password });
    if (error) throw error;
    if (context === 'invite') {
      // Invitation flow (Issue C): the password is set and the account
      // REMAINS PENDING until an administrator activates it. The invitation
      // session must not continue as a signed-in session: end THIS device's
      // session only (never a global sign-out of every device), clear the
      // SSR mirror, and return the agent to the Staff Sign-in page.
      sessionStorage.removeItem(PASSWORD_FLOW_KEY);
      await client.auth.signOut({ scope: 'local' });
      clearSessionCookies();
      // One-time display notice consumed by the Staff Sign-in page. Fixed
      // strings only - no credentials, tokens or account identifiers.
      sessionStorage.setItem(PASSWORD_NOTICE_KEY, JSON.stringify({
        title: 'Password successfully created!',
        body: 'Your SiteWise password has been set successfully. Your account is currently awaiting administrator activation. You can sign in once your account has been activated.',
      }));
      navigate('/staff/signin', 'password-set:invite');
      return;
    }
    // Recovery flow (default): an existing ACTIVE account signs straight in
    // through the normal completion, which revalidates role/status server-side.
    await finishSignIn();
  },
  async signup(email, password, name) {
    await ready;
    if (!client) throw new Error(state.error || 'Authentication is not configured.');
    localStorage.setItem(rememberKey, 'true');
    // No role is submitted: public registration always provisions the
    // permitted public-account role (entrepreneur) on the server.
    const { data, error } = await client.auth.signUp({ email, password, options: {
      data: { full_name: name }, emailRedirectTo: location.origin + '/auth/callback',
    } });
    if (error) throw error;
    if (data.session) await finishSignIn();
    return 'Check your email to confirm your account, then sign in.';
  },
  async complete(next) {
    // AuthCallbackPage (and StaffMfaPage, when the factor already exists) both
    // reach this method. Hydration can also re-mount a @client widget. Memoize
    // the first call so the PKCE exchange, profile fetch and final redirect run
    // exactly once per document instead of twice.
    if (!completionInFlight) {
      completionInFlight = doComplete(next).catch(error => {
        completionInFlight = null; // allow a genuine retry after a failure
        throw error;
      });
    }
    return completionInFlight;
  },
  async signout() {
    await ready;
    if (client) {
      const { error } = await client.auth.signOut();
      if (error) throw error;
    }
    state.user = null;
    state.profile = null;
    state.error = '';
    clearSessionCookies();
    navigate(location.pathname.startsWith('/staff/') ? '/staff/signin' : '/login');
  },
  // One-time consumption of the password-set success notice by the Staff
  // Sign-in page. Fixed display text only - never credentials or tokens.
  consumePasswordNotice() {
    const raw = sessionStorage.getItem(PASSWORD_NOTICE_KEY);
    if (!raw) return null;
    sessionStorage.removeItem(PASSWORD_NOTICE_KEY);
    try {
      const notice = JSON.parse(raw);
      return notice && typeof notice.title === 'string' && typeof notice.body === 'string'
        ? JSON.stringify({ title: notice.title, body: notice.body })
        : null;
    } catch (_) {
      return null;
    }
  },
  async request(path, method, body) {
    await ready;
    if (!client) throw new Error(state.error || 'The Sitewise API is unavailable.');
    return JSON.stringify(await apiRequest(path, method, body ? JSON.parse(body) : null));
  },
};


