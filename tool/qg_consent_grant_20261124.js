// Record the owner's QG processing permission through the application's own
// route, echoing the disclosure the server itself published. Nothing is
// hand-inserted: if the server refuses the echo, no grant exists.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');

const ASSESSMENT = '0f958d15-c629-4df4-90b1-ba444e042612';
const PROPOSAL = '5a6b77a1-45ae-56e8-b6d3-e5f254f000c4';
const CONTEXT = '4a2a8906-f110-5e54-931a-a14fc60260b7';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const pages = ctx.pages().filter(p => p.url().includes('127.0.0.1:8093'));
  if (!pages.length) throw new Error('no page on 8093');
  const page = pages[0];
  await page.bringToFront();
  // The server was just restarted, so the SPA may still be reloading; an
  // evaluate against a navigating context is destroyed mid-flight.
  try { await page.waitForLoadState('domcontentloaded', { timeout: 30000 }); } catch (e) {}
  await page.waitForTimeout(1500);

  const out = await page.evaluate(async ({ assessment, proposal, context }) => {
    let token = null;
    try {
      const raw = localStorage.getItem('sb-lzdpjwmcjbhtkzkqudyt-auth-token');
      if (raw) token = JSON.parse(raw).access_token || null;
    } catch (e) { token = null; }
    const H = { accept: 'application/json', 'content-type': 'application/json' };
    if (token) H.authorization = 'Bearer ' + token;

    const base = `/api/v1/m2/assessments/${assessment}/qg-consents`;
    const get = await fetch(base + '/current?proposal_id=' + proposal,
      { headers: H, credentials: 'same-origin' });
    let current = null;
    try { current = await get.json(); } catch (e) { current = null; }

    const result = { getStatus: get.status, current };
    if (get.status !== 200 || !current) return result;

    const d = current.disclosure || {};
    const body = {
      proposal_id: proposal,
      context_id: context,
      prompt_key: 'QG_FIXED_OPTION',
      granted: true,
      disclosure_version: d.contract_version,
      provider: d.provider,
      purpose: d.purpose,
      endpoint: d.endpoint,
      model: d.model,
    };
    result.echo = body;

    const already = current.consent && current.consent.consent_id;
    if (already) { result.skipped = 'already granted'; return result; }

    const post = await fetch(base, {
      method: 'POST', headers: H, credentials: 'same-origin',
      body: JSON.stringify(body),
    });
    let granted = null;
    try { granted = await post.json(); } catch (e) { granted = null; }
    result.postStatus = post.status;
    result.granted = granted;
    return result;
  }, { assessment: ASSESSMENT, proposal: PROPOSAL, context: CONTEXT });

  console.log(JSON.stringify(out, null, 1));
  await browser.close();
  const ok = (out.postStatus === 201 || out.postStatus === 200)
    && (out.granted && out.granted.granted === true);
  console.log('\nCONSENT GRANT:', ok ? 'RECORDED' : (out.skipped ? 'ALREADY RECORDED' : 'NOT RECORDED'));
  process.exit(ok || out.skipped ? 0 : 1);
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
