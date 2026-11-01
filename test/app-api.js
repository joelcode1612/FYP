"use strict";
const express = require('express');
const cors = require('cors');
const db = require('./db');

function publicConfig(env = process.env) {
  const url = (env.SUPABASE_URL || '').replace(/\/$/, '');
  const key = env.SUPABASE_PUBLISHABLE_KEY || '';
  if (key.startsWith('sb_secret_')) throw new Error('A publishable key is required');
  return { supabaseUrl: url, supabasePublishableKey: key, configured: Boolean(url && key) };
}

function createApp({ query = db.query, verifyUser, env = process.env } = {}) {
  const app = express();
  const config = publicConfig(env);
  const origins = new Set((env.APP_ORIGINS || 'http://localhost:8090,http://127.0.0.1:8090,http://localhost:8091,http://127.0.0.1:8091').split(',').map(s => s.trim()));
  app.use(cors({ origin: (origin, done) => done(null, !origin || origins.has(origin)) }));
  app.use(express.json({ limit: '16kb' }));
  app.get('/api/config', (req, res) => res.json(config));
  app.get('/api/health', async (req, res) => {
    try { await query('SELECT 1'); res.json({ ok: true, database: true, authConfigured: config.configured }); }
    catch { res.status(503).json({ ok: false, error: { message: 'Local PostgreSQL is unavailable.' } }); }
  });
  app.use('/api', async (req, res, next) => {
    if (!config.configured) return res.status(503).json({ error: { message: 'Supabase authentication is not configured.' } });
    const match = /^Bearer (\S+)$/i.exec(req.get('authorization') || '');
    if (!match) return res.status(401).json({ error: { message: 'Sign in to continue.' } });
    try {
      const user = verifyUser ? await verifyUser(match[1]) : await getSupabaseUser(match[1], config);
      if (!user?.id || !user.email) return res.status(401).json({ error: { message: 'Your session is invalid or expired.' } });
      req.authUser = user;
      next();
    } catch (error) {
      res.status(error.authUnavailable ? 503 : 401).json({ error: { message: error.authUnavailable ? 'Authentication service is temporarily unavailable.' : 'Your session is invalid or expired.' } });
    }
  });
  const profile = async (req, res, next) => {
    try {
      const user = req.authUser;
      const preferred = req.method === 'POST' && req.body.role === 'owner' ? 'owner' : 'entrepreneur';
      const name = String(user.user_metadata?.full_name || user.user_metadata?.name || user.email.split('@')[0]).slice(0, 160);
      // The first insert may choose owner/entrepreneur. Existing roles, especially
      // admin, are never changed by OAuth metadata or client-submitted values.
      const result = await query(`INSERT INTO sitewise_app.profiles(user_id,email,display_name,role)
        VALUES($1,$2,$3,$4) ON CONFLICT(user_id) DO UPDATE SET email=EXCLUDED.email
        RETURNING user_id,email,display_name,role`, [user.id,user.email,name,preferred]);
      res.json({ ok: true, data: result.rows[0] });
    } catch (error) { next(error); }
  };
  app.get('/api/me', profile);
  app.post('/api/me', profile);
  const columns = 'id,title,address,city,state,postcode,rental_rm,size_sqft,latitude,longitude,property_type,image_url,source_url,suitability_score,dataset_validation';
  app.get('/api/catalog/properties', async (req, res, next) => {
    try {
      const limit = Math.min(200, Math.max(1, Number(req.query.limit) || 100));
      const offset = Math.max(0, Number(req.query.offset) || 0);
      if (!Number.isInteger(limit) || !Number.isInteger(offset)) return res.status(400).json({ error: { message: 'Pagination must use whole numbers.' } });
      const [rows, count] = await Promise.all([
        query(`SELECT ${columns} FROM sitewise_app.properties ORDER BY id LIMIT $1 OFFSET $2`, [limit,offset]),
        query('SELECT count(*)::int AS total FROM sitewise_app.properties'),
      ]);
      res.json({ ok: true, data: rows.rows, meta: { total: count.rows[0].total, limit, offset } });
    } catch (error) { next(error); }
  });
  app.get('/api/catalog/properties/:id', async (req, res, next) => {
    try {
      const result = await query(`SELECT ${columns} FROM sitewise_app.properties WHERE id=$1`, [req.params.id]);
      res.status(result.rows.length ? 200 : 404).json({ ok: Boolean(result.rows.length), data: result.rows[0] || null });
    } catch (error) { next(error); }
  });
  app.use('/api', (req, res) => res.status(404).json({ error: { message: 'API route not found.' } }));
  app.use((error, req, res, next) => {
    console.error('[app-api]', error.code || error.name || 'Error');
    res.status(500).json({ error: { message: 'The local data service could not complete this request.' } });
  });
  return app;
}

async function getSupabaseUser(token, config) {
  let response;
  try {
    response = await fetch(config.supabaseUrl + '/auth/v1/user', {
      headers: { apikey: config.supabasePublishableKey, Authorization: 'Bearer ' + token },
      signal: AbortSignal.timeout(10000),
    });
  } catch { throw Object.assign(new Error('Auth unavailable'), { authUnavailable: true }); }
  if (!response.ok) throw Object.assign(new Error('Auth rejected'), { authUnavailable: response.status >= 500 || response.status === 429 });
  return response.json();
}
module.exports = { createApp, publicConfig };
