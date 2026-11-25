// Read-only check: is the 8093 session authenticated, and what does the QG
// recovery endpoint say right now? Creates nothing, dispatches nothing.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');

const ASSESSMENT = '0f958d15-c629-4df4-90b1-ba444e042612';
const PROPOSAL = '5a6b77a1-45ae-56e8-b6d3-e5f254f000c4';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  let page = ctx.pages().find(p => p.url().includes('127.0.0.1:8093'));
  if (!page) throw new Error('no page on 8093');
  await page.bringToFront();
  try { await page.waitForLoadState('domcontentloaded', { timeout: 20000 }); } catch (e) {}
  await page.waitForTimeout(800);

  const out = await page.evaluate(async ({ assessment, proposal }) => {
    let token = null;
    try {
      const raw = localStorage.getItem('sb-lzdpjwmcjbhtkzkqudyt-auth-token');
      if (raw) token = JSON.parse(raw).access_token || null;
    } catch (e) { token = null; }
    const H = { accept: 'application/json' };
    if (token) H.authorization = 'Bearer ' + token;

    const r = { url: location.href, hasToken: !!token };

    const me = await fetch('/api/v1/auth/me', { headers: H, credentials: 'same-origin' });
    r.meStatus = me.status;
    try { const b = await me.json(); r.me = { id: b.user_id || b.id, email: b.email }; } catch (e) {}

    const cur = await fetch(
      `/api/v1/m2/assessments/${assessment}/qg-consents/current?proposal_id=${proposal}`,
      { headers: H, credentials: 'same-origin' });
    r.consentStatus = cur.status;
    try {
      const b = await cur.json();
      const g = b.grant || null;
      r.consent = g ? {
        consent_id: g.consent_id,
        state: g.state,
        prompt_version: g.prompt_version,
        prompt_sha256: (g.prompt_sha256 || '').slice(0, 16),
        max_attempts: g.max_attempts,
        granted_at: g.granted_at,
        expires_at: g.expires_at,
        revoked_at: g.revoked_at,
      } : null;
      r.consentState = b.state || null;
      r.disclosureMaxAttempts = (b.disclosure || {}).max_attempts;
    } catch (e) { r.consentParse = 'failed'; }

    const rec = await fetch(
      `/api/v1/m2/assessments/${assessment}/qg-candidates/recovery?proposal_id=${proposal}`,
      { headers: H, credentials: 'same-origin' });
    r.recoveryStatus = rec.status;
    try { r.recovery = await rec.json(); } catch (e) { r.recoveryParse = 'failed'; }

    return r;
  }, { assessment: ASSESSMENT, proposal: PROPOSAL });

  console.log(JSON.stringify(out, null, 1));
  await browser.close();
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
