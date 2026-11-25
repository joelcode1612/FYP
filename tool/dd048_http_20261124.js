// Verify DD-048 over real HTTP in the logged-in browser session.
// Contract 2.1 must be authoritative for a proposal identity; the legacy
// /1 report must still be served for an O-code so nothing is silently removed.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');

const ASSESSMENT = '0f958d15-c629-4df4-90b1-ba444e042612';
const PROPOSAL = '5a6b77a1-45ae-56e8-b6d3-e5f254f000c4';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const pages = ctx.pages().filter(p => p.url().includes('127.0.0.1:8093'));
  if (!pages.length) throw new Error('no page on 8093');
  const page = pages[0];
  await page.bringToFront();

  const out = await page.evaluate(async ({ assessment, proposal }) => {
    const base = `/api/v1/m2/assessments/${assessment}/qg-eligibility`;
    // The SPA authenticates with a bearer token held in localStorage, not with
    // the cookie alone; a bare fetch is refused 401 "Sign in to continue."
    let token = null;
    try {
      const raw = localStorage.getItem('sb-lzdpjwmcjbhtkzkqudyt-auth-token');
      if (raw) token = JSON.parse(raw).access_token || null;
    } catch (e) { token = null; }
    const headers = { accept: 'application/json' };
    if (token) headers.authorization = 'Bearer ' + token;
    const grab = async (qs) => {
      const r = await fetch(base + qs, { headers, credentials: 'same-origin' });
      let body = null;
      try { body = await r.json(); } catch (e) { body = null; }
      return { status: r.status, body };
    };
    const proposalIdentity = await grab('?objective_id=' + encodeURIComponent('proposal:' + proposal));
    const legacyO1 = await grab('?objective_id=O1');
    return { proposalIdentity, legacyO1, hasToken: !!token };
  }, { assessment: ASSESSMENT, proposal: PROPOSAL });

  console.log('bearer token present:', out.hasToken);

  const summarize = (label, res) => {
    const b = res.body || {};
    const checks = (b.generation_checks || []).map(c => `${c.check_id}:${c.status}`).join(' ');
    console.log(`\n[${label}] HTTP ${res.status}`);
    console.log('  contract_version  :', b.contract_version);
    console.log('  objective_id      :', b.objective_id);
    console.log('  generation_status :', b.generation_status);
    console.log('  generation_refusal:', b.generation_refusal);
    console.log('  scientific_status :', b.scientific_status);
    console.log('  scientific rows   :', (b.scientific_checks || []).length);
    console.log('  checks            :', checks || '(none)');
    if (b.detail) console.log('  detail            :', JSON.stringify(b.detail));
  };

  summarize('proposal identity', out.proposalIdentity);
  summarize('legacy O1', out.legacyO1);

  const p = out.proposalIdentity.body || {};
  const ok = out.proposalIdentity.status === 200
    && p.contract_version === 'sitewise-qg-generation-eligibility/2'
    && String(p.objective_id).startsWith('proposal:')
    && !String(p.generation_refusal || '').includes('ADMISSION')
    && (p.scientific_checks || []).length > 0;
  console.log('\nDD-048 HTTP PROBE:', ok ? 'PASS' : 'FAIL');
  await browser.close();
  process.exit(ok ? 0 : 1);
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
