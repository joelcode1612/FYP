import { createClient } from '@supabase/supabase-js';

const api = document.querySelector('meta[name="sitewise-api"]')?.content || 'http://localhost:3001';
let client;
let state = { configured: false, user: null, profile: null, error: '' };
const pendingRoleKey = 'sitewise.pendingRole';
const nextKey = 'sitewise.next';
const rememberKey = 'sitewise.remember';
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
    headers: { Authorization: 'Bearer ' + data.session.access_token, 'Content-Type': 'application/json' },
    body: body == null ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(15000),
  });
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error?.message || 'The data service could not complete this request.');
  return payload;
}

async function profile() {
  const pending = sessionStorage.getItem(pendingRoleKey);
  const response = await apiRequest('/api/me', 'POST', { role: pending === 'owner' ? 'owner' : 'entrepreneur' });
  sessionStorage.removeItem(pendingRoleKey);
  state.profile = response.data;
}

function rememberNext() {
  const next = new URL(location.href).searchParams.get('next');
  if (next?.startsWith('/') && !next.startsWith('//')) sessionStorage.setItem(nextKey, next);
}

function goHome() {
  const role = state.profile?.role || 'entrepreneur';
  const home = '/' + role;
  const next = sessionStorage.getItem(nextKey);
  sessionStorage.removeItem(nextKey);
  // Never allow a return URL to bypass the user's server-assigned role.
  location.assign(next && (next === home || next.startsWith(home + '/') || next.startsWith(home + '?')) ? next : home);
}

// Initialize from the local API's public configuration.
//
// The API is a separate local process. If it is started *after* this page was
// loaded, the one-shot probe used to leave `configured=false` forever and the
// Google buttons stayed disabled until a manual refresh. `initialize()` is
// now reusable: the initial `ready` promise retries a few times, and a
// background poller keeps trying while the API is down, then re-enables the
// rendered buttons in place (no refresh needed).
async function initialize() {
  const response = await fetch(api + '/api/config', { signal: AbortSignal.timeout(5000) });
  if (!response.ok) throw new Error('The local authentication configuration is unavailable.');
  const config = await response.json();
  if (!config.configured) throw new Error('Set the Supabase URL and publishable key in the local backend configuration.');
  if (client) return;                       // already recovered; do not create a second client
  client = createClient(config.supabaseUrl, config.supabasePublishableKey, {
    auth: { flowType: 'pkce', persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, storage },
  });
  state.configured = true;
  state.error = '';
  const { data, error } = await client.auth.getSession();
  if (error) throw error;
  if (data.session) {
    state.user = { id: data.session.user.id, email: data.session.user.email };
    await profile(); // Backend verifies the token with Supabase, never trusts decoded claims.
  }
  client.auth.onAuthStateChange(event => {
    if (event === 'SIGNED_OUT') {
      state.user = null;
      state.profile = null;
      if (/^\/(admin|owner|entrepreneur)(\/|$)/.test(location.pathname)) location.assign('/login');
    }
  });
  announceReady();
}

// Update the server-rendered `lp-*` auth card after a late recovery: remove
// the disabled state from social buttons and replace the "not configured"
// note. The Dart widgets render once, so the DOM is updated directly.
function announceReady() {
  const isSignup = location.pathname.startsWith('/signup');
  const label = isSignup ? 'Google sign-up is managed by Supabase.'
                         : 'Google sign-in is managed by Supabase. Apple sign-in is not configured.';
  document.querySelectorAll('.lp-social').forEach(button => {
    button.removeAttribute('disabled');
    button.setAttribute('aria-label', 'Continue with Google');
  });
  document.querySelectorAll('.lp-social-note').forEach(note => { note.textContent = label; });
  document.querySelectorAll('.lp-alert.err').forEach(alert => {
    if (/Failed to fetch|not configured|unavailable/i.test(alert.textContent || '')) {
      alert.classList.add('is-hidden');
    }
  });
  window.dispatchEvent(new CustomEvent('sitewise:auth-ready'));
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

const ready = (async () => {
  let lastError;
  // Short burst of retries covers the common case: the API is still booting.
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
      state.error = 'The local API is unavailable. Start it, then this page will enable sign-in automatically.';
    } finally {
      polling = false;
    }
  }, 3000);
})();

window.sitewiseAuth = {
  ready,
  snapshot: () => JSON.stringify(state),
  async google(role = 'entrepreneur', remember = true) {
    await ready;
    if (!client) throw new Error(state.error || 'Authentication is not configured.');
    rememberNext();
    localStorage.setItem(rememberKey, String(remember));
    sessionStorage.setItem(pendingRoleKey, role === 'owner' ? 'owner' : 'entrepreneur');
    const { error } = await client.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: location.origin + '/auth/callback' } });
    if (error) throw error;
  },
  async password(email, password, remember = true) {
    await ready;
    if (!client) throw new Error(state.error || 'Authentication is not configured.');
    rememberNext();
    localStorage.setItem(rememberKey, String(remember));
    const { data, error } = await client.auth.signInWithPassword({ email, password });
    if (error) throw error;
    state.user = { id: data.user.id, email: data.user.email };
    await profile();
    goHome();
  },
  async signup(email, password, name, role) {
    await ready;
    if (!client) throw new Error(state.error || 'Authentication is not configured.');
    localStorage.setItem(rememberKey, 'true');
    sessionStorage.setItem(pendingRoleKey, role === 'owner' ? 'owner' : 'entrepreneur');
    const { data, error } = await client.auth.signUp({ email, password, options: {
      data: { full_name: name }, emailRedirectTo: location.origin + '/auth/callback',
    } });
    if (error) throw error;
    if (data.session) { await profile(); goHome(); }
    return 'Check your email to confirm your account, then sign in.';
  },
  async complete() {
    await ready;
    if (!state.profile) throw new Error(state.error || 'No authenticated session was returned. Try signing in again.');
    goHome();
  },
  async signout() {
    await ready;
    if (client) {
      const { error } = await client.auth.signOut();
      if (error) throw error;
    }
    location.assign('/login');
  },
  async request(path, method, body) {
    await ready;
    if (!client) throw new Error(state.error || 'The local API is unavailable.');
    return JSON.stringify(await apiRequest(path, method, body ? JSON.parse(body) : null));
  },
};
