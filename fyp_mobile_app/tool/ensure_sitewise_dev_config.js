// Synchronize the ignored Flutter runtime asset from backend/.env.
// Only explicitly allowlisted public client settings cross this boundary.
'use strict';

const fs = require('fs');
const path = require('path');
const { readBackendEnv } = require('../../tooling/backend_env');

const mobileDir = path.resolve(__dirname, '..');
const repoRoot = path.resolve(mobileDir, '..');
const targetPath = path.join(mobileDir, 'assets', 'config', 'sitewise_dev.json');
const defaultsPath = path.join(mobileDir, 'config', 'sitewise_dev.defaults.json');
const envPath = process.env.SITEWISE_BACKEND_ENV
  ? path.resolve(process.env.SITEWISE_BACKEND_ENV)
  : path.join(repoRoot, 'backend', '.env');
const checkOnly = process.argv.includes('--check');

const AUTH_KEYS = [
  'SUPABASE_URL',
  'SUPABASE_PUBLISHABLE_KEY',
  'GOOGLE_WEB_CLIENT_ID',
  'GOOGLE_IOS_CLIENT_ID',
];
const DEVICE_KEYS = [
  'API_HOST_MODE',
  'API_BASE_URL',
  'WEB_BASE_URL',
  'SITEWISE_DEV_AUTH_BYPASS',
];
const KEY_ORDER = [...AUTH_KEYS, ...DEVICE_KEYS];

function readJson(file) {
  try {
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

function filled(value) {
  return value !== undefined && value !== null && String(value).trim() !== '';
}

function serialise(config) {
  const ordered = {};
  for (const key of KEY_ORDER) if (key in config) ordered[key] = config[key];
  for (const [key, value] of Object.entries(config)) {
    if (!(key in ordered)) ordered[key] = value;
  }
  return `${JSON.stringify(ordered, null, 2)}\n`;
}

function validatePublicValues(config) {
  const url = String(config.SUPABASE_URL || '').trim();
  const key = String(config.SUPABASE_PUBLISHABLE_KEY || '').trim();
  let parsed;
  try { parsed = new URL(url); } catch { parsed = null; }
  if (!parsed || parsed.protocol !== 'https:' || !parsed.hostname || parsed.username ||
      parsed.password || parsed.search || parsed.hash || /\s/.test(url)) {
    throw new Error('SUPABASE_URL must be an HTTPS project URL in backend/.env.');
  }
  if (!/^sb_publishable_[A-Za-z0-9_-]+$/.test(key)) {
    throw new Error('SUPABASE_PUBLISHABLE_KEY must be a Supabase publishable key in backend/.env.');
  }
  for (const name of ['GOOGLE_WEB_CLIENT_ID', 'GOOGLE_IOS_CLIENT_ID']) {
    const value = String(config[name] || '').trim();
    if (value && !/^[A-Za-z0-9._-]+\.apps\.googleusercontent\.com$/.test(value)) {
      throw new Error(`${name} must be a public Google OAuth client ID (never a client secret).`);
    }
  }
}

function atomicWrite(file, content) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.${Date.now()}.tmp`;
  try {
    fs.writeFileSync(temp, content, { encoding: 'utf8', flag: 'wx' });
    fs.renameSync(temp, file);
  } finally {
    if (fs.existsSync(temp)) fs.unlinkSync(temp);
  }
}

function main() {
  let env;
  try {
    env = readBackendEnv(envPath);
  } catch {
    console.error(`Missing backend configuration file: ${envPath}`);
    console.error('Copy backend/.env.example to backend/.env, then fill the required local values.');
    return 1;
  }

  const missing = [
    'SUPABASE_URL',
    'SUPABASE_PUBLISHABLE_KEY',
    'GOOGLE_WEB_CLIENT_ID',
  ].filter((key) => !filled(env[key]));
  if (missing.length) {
    console.error(`Missing required configuration in backend/.env: ${missing.join(', ')}`);
    console.error('Set these values in backend/.env. Start from backend/.env.example; do not put private keys in frontend config.');
    return 1;
  }

  const existingRaw = fs.existsSync(targetPath) ? fs.readFileSync(targetPath, 'utf8') : null;
  const existing = existingRaw === null ? {} : readJson(targetPath) || {};
  const deviceDefaults = readJson(defaultsPath) || {};
  // Rebuild from the known public/device allowlist so unknown or private keys
  // in an old manual config cannot be bundled into the application.
  const next = {};

  // The backend environment is authoritative for every shared public auth value.
  for (const key of AUTH_KEYS) next[key] = String(env[key] || '').trim();

  // Preserve valid per-device networking and local dev switches; defaults only
  // fill missing settings. Auth values in the old defaults file are ignored.
  next.API_HOST_MODE = filled(existing.API_HOST_MODE)
    ? existing.API_HOST_MODE : (deviceDefaults.API_HOST_MODE || 'adb-reverse');
  next.API_BASE_URL = filled(existing.API_BASE_URL)
    ? existing.API_BASE_URL : (deviceDefaults.API_BASE_URL || 'http://127.0.0.1:8090');
  next.WEB_BASE_URL = filled(existing.WEB_BASE_URL)
    ? existing.WEB_BASE_URL : (deviceDefaults.WEB_BASE_URL || 'http://127.0.0.1:8090');
  next.SITEWISE_DEV_AUTH_BYPASS = existing.SITEWISE_DEV_AUTH_BYPASS ?? false;

  for (const key of ['API_BASE_URL', 'WEB_BASE_URL']) {
    let parsed;
    try { parsed = new URL(String(next[key] || '')); } catch { parsed = null; }
    if (!parsed || !['http:', 'https:'].includes(parsed.protocol) || !parsed.hostname ||
        parsed.username || parsed.password) {
      console.error(`Cannot synchronize Flutter configuration: ${key} must be a public HTTP(S) URL without embedded credentials.`);
      return 1;
    }
  }

  try {
    validatePublicValues(next);
  } catch (error) {
    console.error(`Cannot synchronize Flutter configuration: ${error.message}`);
    return 1;
  }

  const content = serialise(next);
  if (existingRaw === content) {
    console.log('Flutter config is current; no file rewrite needed.');
    return 0;
  }
  if (checkOnly) {
    console.error('Flutter config is missing or differs from backend/.env. Run the SiteWise launcher to synchronize it.');
    return 1;
  }

  const changed = KEY_ORDER.filter((key) => String(existing[key] ?? '') !== String(next[key] ?? ''));
  try {
    atomicWrite(targetPath, content);
  } catch (error) {
    console.error(`Could not safely write Flutter config: ${error.code || 'file error'}`);
    return 1;
  }
  console.log(`Flutter public config synchronized: ${changed.join(', ') || 'format only'}`);
  console.log(`Device networking preserved: ${DEVICE_KEYS.slice(0, 3).join(', ')}`);
  return 0;
}

process.exitCode = main();
