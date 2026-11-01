"use strict";
const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const { createApp, publicConfig } = require('./app-api');
const env = { SUPABASE_URL: 'https://example.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_test', SUPABASE_SECRET_KEY: 'do-not-return-this' };

async function withServer(options, callback) {
  const server = createApp({ env, ...options }).listen(0, '127.0.0.1');
  await once(server, 'listening');
  try { await callback('http://127.0.0.1:' + server.address().port); }
  finally { await new Promise(resolve => server.close(resolve)); }
}
const headers = { Authorization: 'Bearer valid-test-token' };
const user = { id: 'a1000000-0000-0000-0000-000000000001', email: 'user@example.com', user_metadata: { full_name: 'Test User', role: 'admin' } };

test('browser configuration exposes only public connection values', () => {
  const config = publicConfig(env);
  assert.deepEqual(Object.keys(config).sort(), ['configured','supabasePublishableKey','supabaseUrl']);
  assert.ok(!JSON.stringify(config).includes('do-not-return-this'));
  assert.throws(() => publicConfig({ ...env, SUPABASE_PUBLISHABLE_KEY: 'sb_secret_bad' }));
});
test('property data rejects missing and invalid authentication', async () => {
  await withServer({ verifyUser: async () => { throw new Error('invalid'); }, query: async () => { throw new Error('Database should not be reached'); } }, async base => {
    assert.equal((await fetch(base + '/api/catalog/properties')).status, 401);
    assert.equal((await fetch(base + '/api/catalog/properties', { headers })).status, 401);
  });
});
test('authentication outage is distinguished from invalid credentials', async () => {
  await withServer({ verifyUser: async () => { throw Object.assign(new Error(), { authUnavailable: true }); } }, async base => {
    assert.equal((await fetch(base + '/api/catalog/properties', { headers })).status, 503);
  });
});
test('client role or user metadata cannot grant administrator access', async () => {
  let assigned;
  await withServer({ verifyUser: async () => user, query: async (sql, params) => {
    assigned = params[3];
    assert.match(sql, /ON CONFLICT\(user_id\) DO UPDATE SET email=EXCLUDED.email/);
    return { rows: [{ user_id: user.id, email: user.email, role: assigned }] };
  } }, async base => {
    const response = await fetch(base + '/api/me', { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({ role: 'admin' }) });
    assert.equal(response.status, 200);
    assert.equal(assigned, 'entrepreneur');
  });
});
test('properties use bounded pagination and parameterized identifiers', async () => {
  const calls = [];
  await withServer({ verifyUser: async () => user, query: async (sql, params) => {
    calls.push([sql,params]);
    return { rows: sql.includes('count(*)') ? [{ total: 2126 }] : [{ id: 'EP-1' }] };
  } }, async base => {
    const response = await fetch(base + '/api/catalog/properties?limit=10000&offset=200', { headers });
    const body = await response.json();
    assert.equal(body.meta.limit, 200);
    assert.equal(body.meta.total, 2126);
    assert.ok(calls.some(([sql,p]) => sql.includes('LIMIT $1 OFFSET $2') && p[0] === 200 && p[1] === 200));
    await fetch(base + '/api/catalog/properties/' + encodeURIComponent("EP-1' OR 1=1--"), { headers });
    assert.ok(calls.some(([sql,p]) => sql.includes('WHERE id=$1') && p[0] === "EP-1' OR 1=1--"));
    assert.equal((await fetch(base + '/api/catalog/properties?limit=1.5', { headers })).status, 400);
  });
});
