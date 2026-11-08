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
const STAFF_ROLES = ['agent', 'admin', 'administrator'];
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

async function hasVerifiedTotpFactor() {
  const { data, error } = await client.auth.mfa.listFactors();
  if (error || !data) throw error || new Error('Could not check authenticator factors.');
  return !!data.all?.find(f => f.type === 'totp' && f.status === 'verified');
}

// Staff rule: agents/administrators MUST have a verified TOTP factor. A staff
// session without one is routed to the enrollment screen instead of a
// workspace. Entrepreneurs keep MFA optional — never forced here.
async function staffNeedsEnrollment() {
  if (!state.profile || !isStaffRole(state.profile.role)) return false;
  return !(await hasVerifiedTotpFactor());
}

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
function navigate(url) {
  if (navigationStarted) return;
  navigationStarted = true;
  location.replace(url);
}

function rememberNext() {
  const next = new URL(location.href).searchParams.get('next');
  if (next?.startsWith('/') && !next.startsWith('//')) sessionStorage.setItem(nextKey, next);
}

function goHome() {
  // Never invent a role. The profile is always the backend-verified response
  // from /api/v1/auth/me; without one there is no authorized destination.
  const role = state.profile?.role;
  if (!role) throw new Error('No authorized profile was returned by the server.');
  const home = (role === 'admin' || role === 'administrator') ? '/admin' : role === 'agent' ? '/agent' : '/entrepreneur';
  const next = sessionStorage.getItem(nextKey);
  sessionStorage.removeItem(nextKey);
  // Never allow a return URL to bypass the user's server-assigned role.
  navigate(next && (next === home || next.startsWith(home + '/') || next.startsWith(home + '?')) ? next : home);
}

// Single source of truth for the staff MFA gate, reused by sign-in, session
// restore and token refresh. Returns 'ok' (non-staff, or staff at aal2),
// 'enroll' (staff without a verified TOTP factor) or 'verify' (staff factor
// present but this session has not completed the challenge). Fail closed: an
// assurance check that errors throws rather than being treated as 'ok'.
async function ensureStaffAssurance() {
  if (!state.profile || !isStaffRole(state.profile.role)) return 'ok';
  if (await staffNeedsEnrollment()) return 'enroll';
  const { data: assurance, error } = await client.auth.mfa.getAuthenticatorAssuranceLevel();
  if (error || !assurance) throw error || new Error('MFA assurance could not be checked.');
  return assurance.currentLevel === 'aal2' ? 'ok' : 'verify';
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
  if (status === 'enroll') navigate('/staff/mfa');
  else if (status === 'verify') navigate('/staff/verify');
}

// Route after any successful sign-in: ALWAYS validate the authoritative
// server profile first, then staff-without-a-factor go to enrollment, staff
// without aal2 go to verification, and everyone else to their role's workspace.
async function finishSignIn() {
  // Never choose a workspace using a previously authenticated account's
  // profile. The backend resolves the role from the current signed JWT.
  await profile();
  assertActiveAccount(state.profile);
  const status = await ensureStaffAssurance();
  if (status === 'enroll') {
    state.mfaEnrollmentRequired = true;
    navigate('/staff/mfa');
    return;
  }
  if (status === 'verify') {
    navigate('/staff/verify');
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
// callbacks while `detectSessionInUrl` exchanges the PKCE authorization code.
// Without this the /auth/callback page can observe a null session before the
// exchange finishes and report "no authenticated session was returned".
async function currentSession() {
  const hasCallbackParams = /[?&](code|access_token|refresh_token|token_hash)=/.test(location.href);
  let lastError = null;
  for (let attempt = 0; attempt < 10; attempt++) {
    const { data, error } = await client.auth.getSession();
    if (data?.session) return data.session;
    if (error) lastError = error;
    if (!hasCallbackParams) break;
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
    auth: { flowType: 'pkce', persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, storage },
  });
  state.configured = true;
  state.error = '';
  announceReady();

  // Subscribe BEFORE reading the session: the PKCE code exchange on
  // /auth/callback emits SIGNED_IN asynchronously during client init.
  client.auth.onAuthStateChange((event, session) => {
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
  // /auth/callback is a full SSR document load. detectSessionInUrl exchanges
  // the PKCE code during client initialization; currentSession() waits for
  // that exchange before we decide anything.
  const session = await currentSession();
  if (!session) {
    throw new Error('No authenticated session was returned. Try signing in again.');
  }
  state.user = { id: session.user.id, email: session.user.email };

  // Recovery / invite links go to the new-password screen first.
  if (next === '/reset-password') {
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
  async password(email, password, remember = true, mfaCode = '') {
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
        // First factor complete: finishSignIn() requires staff AAL2 and routes
        // AAL1 accounts to /staff/verify. No challenge input remains on /login.
        await finishSignIn();
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
    if (sessionError || !sessionResult?.session) throw new Error('Your sign-in session expired. Please sign in again.');
    await profile();
    if (!isStaffRole(state.profile?.role)) throw new Error('Staff role is required.');
    const { data: levels, error: levelsError } = await client.auth.mfa.getAuthenticatorAssuranceLevel();
    if (levelsError || !levels) throw levelsError || new Error('MFA assurance check unavailable.');
    if (levels.currentLevel === 'aal2') return 'verified';
    const { data: factors, error: factorsError } = await client.auth.mfa.listFactors();
    if (factorsError || !factors) throw factorsError || new Error('Authenticator factors unavailable.');
    const factor = factors.all?.find(f => f.type === 'totp' && f.status === 'verified');
    if (!factor) { navigate('/staff/mfa'); return 'enroll'; }
    const challenge = await client.auth.mfa.challenge({ factorId: factor.id });
    if (challenge.error || !challenge.data?.id) throw challenge.error || new Error('Could not start MFA challenge.');
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
    if (error) throw error;
    const { data: assurance, error: aalError } = await client.auth.mfa.getAuthenticatorAssuranceLevel();
    if (aalError || assurance?.currentLevel !== 'aal2') throw aalError || new Error('MFA verification was not confirmed.');
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
    if (!client) throw new Error(state.error || 'Authentication is not configured.');
    const { data: session, error: sessionError } = await client.auth.getSession();
    if (sessionError || !session?.session) throw new Error('Your sign-in session expired. Please sign in again.');
    await profile();
    if (!isStaffRole(state.profile?.role)) throw new Error('Staff role is required.');
    if (await hasVerifiedTotpFactor()) { navigate('/staff/verify'); throw new Error('Authenticator already enrolled.'); }
    const { data, error } = await client.auth.mfa.enroll({
      factorType: 'totp',
      friendlyName: 'Sitewise Staff',
    });
    if (error) throw error;
    state.mfaEnrollFactorId = data.id;
    state.mfaEnrollQr = data.totp?.qr_code || null;
    state.mfaEnrollSecret = data.totp?.secret || null;
    return { qr: state.mfaEnrollQr, secret: state.mfaEnrollSecret };
  },
  async mfaEnrollVerify(code) {
    await ready;
    if (!client) throw new Error(state.error || 'Authentication is not configured.');
    if (!state.mfaEnrollFactorId) throw new Error('Start the enrollment again.');
    const challenge = await client.auth.mfa.challenge({ factorId: state.mfaEnrollFactorId });
    if (challenge.error) throw challenge.error;
    const verify = await client.auth.mfa.verify({
      factorId: state.mfaEnrollFactorId,
      challengeId: challenge.data.id,
      code,
    });
    if (verify.error) throw verify.error;
    // Only a verified factor satisfies the staff MFA requirement.
    state.mfaEnrollmentRequired = false;
    state.mfaEnrollFactorId = null;
    state.mfaEnrollQr = null;
    state.mfaEnrollSecret = null;
    const { data: assurance, error: aalError } = await client.auth.mfa.getAuthenticatorAssuranceLevel();
    if (aalError || assurance?.currentLevel !== 'aal2') throw aalError || new Error('MFA enrollment was not confirmed.');
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
    const { error } = await client.auth.updateUser({ password });
    if (error) throw error;
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
  async request(path, method, body) {
    await ready;
    if (!client) throw new Error(state.error || 'The Sitewise API is unavailable.');
    return JSON.stringify(await apiRequest(path, method, body ? JSON.parse(body) : null));
  },
};


