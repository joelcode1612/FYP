// One bounded, separately authorised LIVE TokenHarbour QG execution.
// Exactly one request is sent. No retry, no fallback, no simulated path.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');

const ASSESSMENT = '0f958d15-c629-4df4-90b1-ba444e042612';
const PROPOSAL = '5a6b77a1-45ae-56e8-b6d3-e5f254f000c4';
const CONFIRMATION = 'd5a72e84-c653-4b16-b225-3de857009b45';
const CONTEXT = '4a2a8906-f110-5e54-931a-a14fc60260b7';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const pages = ctx.pages().filter(p => p.url().includes('127.0.0.1:8093'));
  if (!pages.length) throw new Error('no page on 8093');
  const page = pages[0];
  await page.bringToFront();
  try { await page.waitForLoadState('domcontentloaded', { timeout: 30000 }); } catch (e) {}
  await page.waitForTimeout(1000);

  const out = await page.evaluate(async ({ assessment, proposal, confirmation, context }) => {
    let token = null;
    try {
      const raw = localStorage.getItem('sb-lzdpjwmcjbhtkzkqudyt-auth-token');
      if (raw) token = JSON.parse(raw).access_token || null;
    } catch (e) { token = null; }
    const H = { accept: 'application/json', 'content-type': 'application/json' };
    if (token) H.authorization = 'Bearer ' + token;

    const url = `/api/v1/m2/assessments/${assessment}/qg-candidates/generate`;
    const started = Date.now();
    const res = await fetch(url, {
      method: 'POST', headers: H, credentials: 'same-origin',
      body: JSON.stringify({
        confirmation_id: confirmation,
        context_id: context,
        proposal_id: proposal,
        response_format: 'MULTIPLE_CHOICE',
      }),
    });
    const elapsedMs = Date.now() - started;
    let body = null;
    try { body = await res.json(); } catch (e) { body = null; }
    return { status: res.status, elapsedMs, body };
  }, { assessment: ASSESSMENT, proposal: PROPOSAL, confirmation: CONFIRMATION, context: CONTEXT });

  console.log('HTTP', out.status, 'in', out.elapsedMs, 'ms');
  console.log(JSON.stringify(out.body, null, 1).slice(0, 4000));
  await browser.close();
  process.exit(out.status >= 200 && out.status < 300 ? 0 : 1);
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
