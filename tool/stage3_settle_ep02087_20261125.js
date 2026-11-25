// Decides the Stage 3 question properly: navigate, wait for the governed BDJ
// panel to reach a TERMINAL state (cards, empty state, stale state or error),
// then dump what it actually shows. No fixed sleep decides the verdict.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');
const fs = require('fs');

const BASE = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02087&stage=location_evidence';
const DIR = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/deliverables/screenshots/20261124_stage34';
fs.mkdirSync(DIR, { recursive: true });

function findPage(browser) {
  for (const ctx of browser.contexts()) for (const p of ctx.pages()) if (p.url().includes('127.0.0.1:8093')) return p;
  return null;
}

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  let page = findPage(browser);
  if (!page) { const ctx = browser.contexts()[0] || await browser.newContext(); page = await ctx.newPage(); }
  await page.bringToFront();
  await page.setViewportSize({ width: 1440, height: 1200 });

  await page.goto('http://127.0.0.1:8093/', { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(4000);

  const started = Date.now();
  await page.goto(BASE, { waitUntil: 'domcontentloaded', timeout: 60000 });

  let terminal = null;
  try {
    await page.waitForFunction(() => {
      const t = document.body.innerText || '';
      if (/Research objectives could not be read/i.test(t)) return 'error';
      if (/The confirmed source is not current/i.test(t)) return 'stale';
      if (/No research objectives yet/i.test(t)) return 'empty';
      if (/proposal:[0-9a-f-]{36}/.test(t)) return 'cards';
      if (/Reading persisted research objectives/i.test(t)) return false;
      return false;
    }, null, { timeout: 90000, polling: 500 });
  } catch (e) { terminal = 'TIMEOUT'; }
  const settleMs = Date.now() - started;

  // waitForFunction returning a truthy string still resolves; read it back.
  const state = await page.evaluate(() => {
    const t = document.body.innerText || '';
    return {
      cards: (t.match(/proposal:[0-9a-f-]{36}/g) || []).length,
      loading: /Reading persisted research objectives/i.test(t),
      empty: /No research objectives yet/.test(t),
      stale: /The confirmed source is not current/.test(t),
      error: (t.match(/Research objectives could not be read[\s\S]{0,200}/i) || [])[0] || null,
      proposalsLine: (t.match(/\d+ proposals? · [^\n]*/i) || [])[0] || null,
      approved: (t.match(/Objectives approved[^\n]*/i) || [])[0] || null,
      live: /Execution mode LIVE/i.test(t),
      model: (t.match(/deepseek[-\w.]+/i) || [])[0] || null,
      provenance: (t.match(/Prompt [^\n]{0,60}/i) || [])[0] || null,
    };
  });

  const panel = await page.evaluate(() => {
    const el = Array.from(document.querySelectorAll('section.panel'))
      .find(n => /Research objectives/i.test(n.innerText || ''));
    return el ? (el.innerText || '').slice(0, 2200) : null;
  });

  await page.evaluate(() => {
    const el = Array.from(document.querySelectorAll('*'))
      .find(n => n.children.length === 0 && /Research objectives/i.test(n.textContent || ''));
    if (el) el.scrollIntoView({ block: 'center' });
  });
  await page.waitForTimeout(1200);
  await page.screenshot({ path: `${DIR}/stage3_ep02087.png` });

  console.log(JSON.stringify({ terminal: terminal || 'reached', settleMs, state, panel }, null, 1));
  await browser.close();
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
