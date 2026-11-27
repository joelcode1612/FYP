// Provisions fyp_mobile_app/assets/config/sitewise_dev.json when it is missing.
//
// Why this exists: pubspec.yaml declares that exact asset, and the file is
// git-ignored because it is a per-machine override point. A fresh clone, a new
// `git worktree`, or a branch switch therefore leaves the asset absent and
// `flutter run` / `flutter build` fail with "unable to find asset" before any
// Dart code executes. Reconstructing it by hand was the only remedy.
//
// What it does — and deliberately does not do:
//
//   * A file that is present and complete is left byte-for-byte untouched. The
//     script reports "present" and exits 0. A developer's local override (LAN
//     origin, a different emulator host, an auth-bypass experiment) is never
//     clobbered.
//   * A file that exists but is unparseable or incomplete is repaired by
//     filling ONLY the missing or empty keys, after copying the original to
//     `<name>.invalid-<timestamp>.bak`. Non-empty values survive.
//   * Supabase values come from backend/.env first (the same source the web
//     generator `fyp_jaspr_web/tool/gen_auth_config.js` reads), so the mobile
//     client stays in step with the backend it is pointed at. Only the two
//     public-by-design fields are read: SUPABASE_URL and
//     SUPABASE_PUBLISHABLE_KEY.
//   * When backend/.env is absent or empty, the committed
//     config/sitewise_dev.defaults.json supplies the authorised public values,
//     so a bare worktree still builds.
//   * Database passwords, service-role/secret keys and every other backend
//     secret are never read into the asset. The publishable key is validated
//     against the `sb_publishable_` shape, and any candidate value that looks
//     like a server secret aborts the run instead of being written.
//
// Usage:
//   node fyp_mobile_app/tool/ensure_sitewise_dev_config.js
//   node fyp_mobile_app/tool/ensure_sitewise_dev_config.js --check   (exit 1 if absent)
//
// Exit codes: 0 = the asset is present and usable (created or already valid),
// 1 = it could not be produced, 2 = a guard refused to write.

'use strict';

const fs = require('fs');
const path = require('path');

const mobileDir = path.resolve(__dirname, '..');
const repoRoot = path.resolve(mobileDir, '..');
const targetPath = path.join(mobileDir, 'assets', 'config', 'sitewise_dev.json');
const defaultsPath = path.join(mobileDir, 'config', 'sitewise_dev.defaults.json');
const backendEnvPath = process.env.SITEWISE_BACKEND_ENV
  ? path.resolve(process.env.SITEWISE_BACKEND_ENV)
  : path.join(repoRoot, 'backend', '.env');

//: Key order of the asset. Fixed so a regenerated file diffs predictably.
const KEY_ORDER = [
  'SUPABASE_URL',
  'SUPABASE_PUBLISHABLE_KEY',
  'API_HOST_MODE',
  'API_BASE_URL',
  'WEB_BASE_URL',
  'GOOGLE_WEB_CLIENT_ID',
  'GOOGLE_IOS_CLIENT_ID',
  'SITEWISE_DEV_AUTH_BYPASS',
];

//: Keys without which the app cannot authenticate or reach the API. A file
//: missing any of these is treated as incomplete rather than valid.
const REQUIRED_KEYS = [
  'SUPABASE_URL',
  'SUPABASE_PUBLISHABLE_KEY',
  'API_HOST_MODE',
  'API_BASE_URL',
  'WEB_BASE_URL',
];

//: The USB/loopback development origin written into a NEWLY created asset.
//:
//: The launchers export SITEWISE_DEV_ORIGIN with the port they are about to
//: bind, so the first write is already correct. Without the override this file
//: would create an asset pointing at 8090 while the server listened on 8093,
//: and the launchers would have to rewrite it immediately afterwards.
//:
//: The literal is only the fallback for a hand-run. It cannot be the authority:
//: a COMPLETE asset is never rewritten here (a per-machine override is the
//: whole point of a git-ignored file), so the alignment lives in the launchers,
//: which know the real port.
const DEV_ORIGIN_DEFAULT = 'http://127.0.0.1:8090';

/** The origin to write, honouring SITEWISE_DEV_ORIGIN when it is valid. */
function resolveDevOrigin() {
  const override = (process.env.SITEWISE_DEV_ORIGIN || '').trim();
  if (!override) return DEV_ORIGIN_DEFAULT;
  if (!/^https?:\/\/[^/\s]+:\d+$/i.test(override)) {
    throw new Error(
      `SITEWISE_DEV_ORIGIN must be an absolute http(s) URL with an explicit port (got "${override}")`,
    );
  }
  return override;
}

const checkOnly = process.argv.includes('--check');

function readJson(file) {
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

/** Minimal KEY=VALUE reader: never evaluates the file, never expands anything. */
function readEnvFile(file) {
  const values = {};
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch {
    return values;
  }
  for (const line of raw.split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!match) continue;
    values[match[1]] = match[2].replace(/^["']|["']$/g, '').trim();
  }
  return values;
}

function isFilled(value) {
  if (value === undefined || value === null) return false;
  if (typeof value === 'boolean') return true;
  return String(value).trim() !== '';
}

function isComplete(config) {
  return REQUIRED_KEYS.every((key) => isFilled(config[key]));
}

/** Refuses anything that must never reach a client asset. */
function assertNoSecret(key, value) {
  const text = String(value ?? '');
  if (/sb_secret_/i.test(text)) {
    throw new Error(`${key} contains a Supabase secret key; it must stay in backend/.env`);
  }
  if (/(?:postgres(?:ql)?(?:\+[a-z0-9_]+)?|rediss?):\/\/[^/@\s:'"]+:[^/@\s'"<>]+@/i.test(text)) {
    throw new Error(`${key} contains a database URL with a password; it must stay in backend/.env`);
  }
  if (/^service_role$/i.test(text) || /service[_-]?role[_-]?key/i.test(text)) {
    throw new Error(`${key} looks like a service-role credential; it must stay in backend/.env`);
  }
}

function validate(config) {
  const publishable = String(config.SUPABASE_PUBLISHABLE_KEY ?? '').trim();
  if (publishable && !/^sb_publishable_[A-Za-z0-9_-]+$/.test(publishable)) {
    throw new Error(
      'SUPABASE_PUBLISHABLE_KEY is not a Supabase publishable key (expected sb_publishable_...). ' +
        'Refusing to write a value that may be a server secret.',
    );
  }
  const url = String(config.SUPABASE_URL ?? '').trim();
  if (url && !/^https?:\/\//i.test(url)) {
    throw new Error('SUPABASE_URL must be an absolute http(s) URL.');
  }
  const api = String(config.API_BASE_URL ?? '').trim();
  if (api && !/^https?:\/\/[^/\s]+:\d+/i.test(api)) {
    throw new Error('API_BASE_URL must be an absolute http(s) URL with an explicit port.');
  }
}

function serialise(config) {
  const ordered = {};
  for (const key of KEY_ORDER) {
    if (config[key] !== undefined) ordered[key] = config[key];
  }
  for (const key of Object.keys(config)) {
    if (!(key in ordered)) ordered[key] = config[key];
  }
  return `${JSON.stringify(ordered, null, 2)}\n`;
}

function main() {
  // Resolved inside main so an invalid override fails through the exit-code
  // handler at the bottom of this file instead of as an uncaught module error.
  const DEV_ORIGIN = resolveDevOrigin();

  const existingRaw = (() => {
    try {
      return fs.readFileSync(targetPath, 'utf8');
    } catch {
      return null;
    }
  })();

  if (existingRaw !== null) {
    const existing = readJson(targetPath);
    if (existing && isComplete(existing)) {
      // Present and usable: leave it exactly as it is, even if it differs from
      // the defaults. A per-machine override is the whole point of the file.
      console.log(`sitewise_dev.json: present and complete (${targetPath}) — unchanged.`);
      return 0;
    }
    if (checkOnly) {
      console.error('sitewise_dev.json: present but incomplete or unparseable.');
      return 1;
    }
  } else if (checkOnly) {
    console.error(`sitewise_dev.json: missing (${targetPath}).`);
    return 1;
  }

  const defaults = readJson(defaultsPath);
  if (!defaults) {
    console.error(`Cannot provision: ${defaultsPath} is missing or unreadable.`);
    return 1;
  }

  // backend/.env first (keeps the client aligned with the running backend),
  // then the committed public defaults.
  const backendEnv = readEnvFile(backendEnvPath);
  const supabaseUrl = (backendEnv.SUPABASE_URL || '').trim() || defaults.SUPABASE_URL;
  const publishableKey =
    (backendEnv.SUPABASE_PUBLISHABLE_KEY || '').trim() || defaults.SUPABASE_PUBLISHABLE_KEY;

  const baseline = {
    SUPABASE_URL: supabaseUrl,
    SUPABASE_PUBLISHABLE_KEY: publishableKey,
    API_HOST_MODE: 'adb-reverse',
    API_BASE_URL: DEV_ORIGIN,
    WEB_BASE_URL: DEV_ORIGIN,
    GOOGLE_WEB_CLIENT_ID: defaults.GOOGLE_WEB_CLIENT_ID ?? '',
    GOOGLE_IOS_CLIENT_ID: defaults.GOOGLE_IOS_CLIENT_ID ?? '',
    SITEWISE_DEV_AUTH_BYPASS: false,
  };

  // A partial file keeps every value it already has; only the gaps are filled.
  const partial = existingRaw !== null ? readJson(targetPath) : null;
  const merged = { ...baseline };
  const preserved = [];
  if (partial) {
    for (const key of Object.keys(partial)) {
      if (isFilled(partial[key])) {
        merged[key] = partial[key];
        if (String(partial[key]) !== String(baseline[key] ?? '')) preserved.push(key);
      }
    }
  }

  try {
    for (const [key, value] of Object.entries(merged)) assertNoSecret(key, value);
    validate(merged);
  } catch (error) {
    console.error(`Refusing to write sitewise_dev.json: ${error.message}`);
    return 2;
  }

  if (existingRaw !== null) {
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const backup = `${targetPath}.invalid-${stamp}.bak`;
    fs.writeFileSync(backup, existingRaw, 'utf8');
    console.log(`sitewise_dev.json: previous file preserved at ${path.basename(backup)}`);
  }

  fs.mkdirSync(path.dirname(targetPath), { recursive: true });
  fs.writeFileSync(targetPath, serialise(merged), 'utf8');

  const filled = KEY_ORDER.filter((key) => !isFilled(partial?.[key]));
  console.log(`sitewise_dev.json: written to ${targetPath}`);
  console.log(`  filled: ${filled.join(', ') || '(none)'}`);
  if (preserved.length) console.log(`  kept from the previous file: ${preserved.join(', ')}`);
  console.log('  contains public client values only (no secret or service-role key).');
  return 0;
}

try {
  process.exitCode = main();
} catch (error) {
  console.error(`sitewise_dev.json provisioning failed: ${error.message}`);
  process.exitCode = 1;
}
