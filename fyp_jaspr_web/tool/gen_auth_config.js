// Generate the browser-safe runtime auth config from backend/.env.
// Local development has one source of truth; deployments may explicitly set
// SITEWISE_SUPABASE_ENV to their protected environment file.
'use strict';

const fs = require('fs');
const path = require('path');
const { readBackendEnv } = require('../../tooling/backend_env');

const envPath = process.env.SITEWISE_SUPABASE_ENV
  ? path.resolve(process.env.SITEWISE_SUPABASE_ENV)
  : path.resolve(__dirname, '..', '..', 'backend', '.env');
const outPath = path.resolve(__dirname, '..', 'web', 'auth-config.json');

let env;
try {
  env = readBackendEnv(envPath);
} catch {
  console.error(`gen_auth_config: missing configuration file ${envPath}`);
  console.error('Copy backend/.env.example to backend/.env and configure the required values.');
  process.exit(1);
}

const supabaseUrl = String(env.SUPABASE_URL || '').trim().replace(/\/+$/, '');
const publishable = String(env.SUPABASE_PUBLISHABLE_KEY || '').trim();
const missing = [
  !supabaseUrl ? 'SUPABASE_URL' : null,
  !publishable ? 'SUPABASE_PUBLISHABLE_KEY' : null,
].filter(Boolean);

if (missing.length) {
  console.error(`gen_auth_config: missing required variables in backend/.env: ${missing.join(', ')}`);
  console.error('Set these values in backend/.env using the matching public Supabase project.');
  process.exit(1);
}
if (!/^sb_publishable_[A-Za-z0-9_-]+$/.test(publishable)) {
  console.error('gen_auth_config: SUPABASE_PUBLISHABLE_KEY must be a Supabase publishable key.');
  process.exit(1);
}

let projectUrl;
try {
  projectUrl = new URL(supabaseUrl);
} catch {
  console.error('gen_auth_config: SUPABASE_URL must be an HTTPS project URL.');
  process.exit(1);
}
if (projectUrl.protocol !== 'https:' || projectUrl.username || projectUrl.password ||
    projectUrl.search || projectUrl.hash) {
  console.error('gen_auth_config: SUPABASE_URL must be a public HTTPS project URL.');
  process.exit(1);
}

const output = JSON.stringify({
  configured: true,
  supabaseUrl,
  supabasePublishableKey: publishable,
  _note: 'Generated from backend/.env. Public client values only.',
}, null, 2) + '\n';
fs.mkdirSync(path.dirname(outPath), { recursive: true });
const tempPath = `${outPath}.${process.pid}.${Date.now()}.tmp`;
try {
  fs.writeFileSync(tempPath, output, { encoding: 'utf8', flag: 'wx' });
  fs.renameSync(tempPath, outPath);
} finally {
  if (fs.existsSync(tempPath)) fs.unlinkSync(tempPath);
}
console.log('gen_auth_config: synchronized Supabase public settings to web/auth-config.json');
