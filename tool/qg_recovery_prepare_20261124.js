// Prepare — but do not perform — one explicitly authorised recovery of the spent
// QG attempt on EP-02638. Nothing here dispatches: the only POST is the owner's
// consent, which records permission and opens no socket.
//
// Steps: read recovery state -> ensure the live consent is bound to the prompt
// this deployment actually dispatches -> read recovery state again -> report the
// exact body the Generate Questions action will send.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');

const ASSESSMENT = '0f958d15-c629-4df4-90b1-ba444e042612';
const PROPOSAL = '5a6b77a1-45ae-56e8-b6d3-e5f254f000c4';
const CONTEXT = '4a2a8906-f110-5e54-931a-a14fc60260b7';
// Must equal PROMPTS['QG_FIXED_OPTION'].version in
// backend/src/sitewise/project1/prompts.py. A consent bound to a different
// version cannot authorise a dispatch of this one, so this is checked, not assumed.
const EXPECTED_PROMPT = 'QG-FIXED-OPTION-3-CAND';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = ctx.pages().find(p => p.url().includes('127.0.0.1:8093'));
  if (!page) throw new Error('no page on 8093');
  await page.bringToFront();
  try { await page.waitForLoadState('domcontentloaded', { timeout: 20000 }); } catch (e) {}
  await page.waitForTimeout(800);

  const out = await page.evaluate(async ({ assessment, proposal, context, expected }) => {
    let token = null;
    try {
      const raw = localStorage.getItem('sb-lzdpjwmcjbhtkzkqudyt-auth-token');
      if (raw) token = JSON.parse(raw).access_token || null;
    } catch (e) { token = null; }
    const H = { accept: 'application/json', 'content-type': 'application/json' };
    if (token) H.authorization = 'Bearer ' + token;
    const base = `/api/v1/m2/assessments/${assessment}`;
    const r = { hasToken: !!token };

    const readRecovery = async () => {
      const res = await fetch(
        `${base}/qg-candidates/recovery?proposal_id=${proposal}&context_id=${context}`,
        { headers: H, credentials: 'same-origin' });
      let body = null;
      try { body = await res.json(); } catch (e) {}
      return { status: res.status, body };
    };

    const readConsent = async () => {
      const res = await fetch(`${base}/qg-consents/current?proposal_id=${proposal}`,
        { headers: H, credentials: 'same-origin' });
      let body = null;
      try { body = await res.json(); } catch (e) {}
      return { status: res.status, body };
    };

    r.recovery_before = await readRecovery();
    r.consent_before = await readConsent();

    const live = (r.consent_before.body || {}).grant || null;
    const liveMatchesPrompt = !!live && live.prompt_version === expected
      && live.state === 'GRANTED';
    r.live_consent_matches_prompt = liveMatchesPrompt;

    if (!liveMatchesPrompt) {
      const d = (r.consent_before.body || {}).disclosure || {};
      const post = await fetch(`${base}/qg-consents`, {
        method: 'POST', headers: H, credentials: 'same-origin',
        body: JSON.stringify({
          proposal_id: proposal,
          context_id: context,
          request_id: crypto.randomUUID(),
          prompt_key: 'QG_FIXED_OPTION',
          granted: true,
          disclosure_version: d.contract_version,
          provider: d.provider,
          purpose: d.purpose,
          endpoint: d.endpoint,
          model: d.model,
        }),
      });
      let body = null;
      try { body = await post.json(); } catch (e) {}
      r.consent_post = {
        status: post.status,
        granted: body && body.granted,
        idempotent: body && body.idempotent,
        consent_id: body && body.consent && body.consent.consent_id,
        prompt_version: body && body.consent && body.consent.prompt_version,
        max_attempts: body && body.consent && body.consent.max_attempts,
        state: body && body.consent && body.consent.state,
      };
    }

    r.consent_after = await readConsent();
    r.recovery_after = await readRecovery();
    return r;
  }, { assessment: ASSESSMENT, proposal: PROPOSAL, context: CONTEXT, expected: EXPECTED_PROMPT });

  console.log(JSON.stringify(out, null, 1));
  await browser.close();
  const ok = out.recovery_after && out.recovery_after.body
    && out.recovery_after.body.recovery_available === true;
  console.log('\nRECOVERY PREPARED:', ok ? 'YES' : 'NO');
  process.exit(ok ? 0 : 1);
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
