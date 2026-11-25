// Traces Stage 3 network + console so we can tell WHY the governed BDJ panel
// stays on "Reading persisted research objectives…" while the list endpoint
// answers 200. Records every /api/v1/project1-workflow request with its status,
// every console message, and every page error.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');

const BASE = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638&stage=location_evidence';

function findPage(browser) {
  for (const ctx of browser.contexts()) {
    for (const p of ctx.pages()) if (p.url().includes('127.0.0.1:8093')) return p;
  }
  return null;
}

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  let page = findPage(browser);
  if (!page) {
    const ctx = browser.contexts()[0] || await browser.newContext();
    page = await ctx.newPage();
  }
  await page.bringToFront();
  await page.setViewportSize({ width: 1440, height: 1100 });

  const reqs = [];
  const pending = new Map();
  const consoleMsgs = [];
  const pageErrors = [];

  page.on('request', r => {
    const u = r.url();
    if (!u.includes('/api/v1/')) return;
    pending.set(r, { url: u.replace('http://127.0.0.1:8093', ''), method: r.method(), t: Date.now() });
  });
  page.on('response', async r => {
    const rec = pending.get(r.request());
    if (!rec) return;
    pending.delete(r.request());
    rec.status = r.status();
    rec.ms = Date.now() - rec.t;
    try {
      const b = await r.json();
      rec.bodyKeys = b && typeof b === 'object' ? Object.keys(b).slice(0, 12) : null;
      rec.count = typeof b?.proposal_count === 'number' ? b.proposal_count : undefined;
    } catch (_) {}
    reqs.push(rec);
  });
  page.on('requestfailed', r => {
    const rec = pending.get(r);
    if (!rec) return;
    pending.delete(r);
    rec.failed = r.failure()?.errorText || 'unknown';
    reqs.push(rec);
  });
  page.on('console', m => {
    const t = m.text();
    if (/error|exception|unhandled|TypeError|failed/i.test(t)) consoleMsgs.push(`[${m.type()}] ${t}`.slice(0, 400));
  });
  page.on('pageerror', e => pageErrors.push(String(e.message || e).slice(0, 400)));

  await page.goto('http://127.0.0.1:8093/', { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(4000);
  await page.goto(BASE, { waitUntil: 'domcontentloaded', timeout: 60000 });

  // Wait until the Stage 3 surface itself exists before judging the panel:
  // "no loader" is meaningless while the stage has not rendered at all.
  let stageReadyAt = null;
  for (let i = 0; i < 30; i++) {
    await page.waitForTimeout(1000);
    const ready = await page.evaluate(() => /Business review and research goals/i.test(document.body.innerText || ''));
    if (ready) { stageReadyAt = i + 1; break; }
  }

  // Then poll the governed panel for 45 s so a late settle is still observed.
  const timeline = [];
  for (let i = 0; i < 15; i++) {
    await page.waitForTimeout(3000);
    const snap = await page.evaluate(() => {
      const t = document.body.innerText || '';
      return {
        loading: /Reading persisted research objectives/i.test(t),
        cards: (t.match(/proposal:[0-9a-f-]{36}/g) || []).length,
        proposalsLine: (t.match(/\d+ proposals? · [^\n]*/i) || [])[0] || null,
        approved: (t.match(/Objectives approved[^\n]*/i) || [])[0] || null,
        err: (t.match(/Research objectives could not be read[\s\S]{0,160}/i) || [])[0] || null,
        stale: (t.match(/The confirmed source is not current[\s\S]{0,160}/i) || [])[0] || null,
      };
    });
    timeline.push({ at: (i + 1) * 3, ...snap });
    if (!snap.loading) break;
  }
  console.log(JSON.stringify({
    stageReadyAfterSeconds: stageReadyAt,
    timeline,
    requests: reqs.sort((a, b) => a.t - b.t).map(r => `${r.method} ${r.url} -> ${r.status ?? r.failed ?? 'PENDING'} (${r.ms ?? '?'}ms) ${r.count !== undefined ? 'count=' + r.count : ''}`),
    stillPending: [...pending.values()].map(r => `${r.method} ${r.url}`),
    consoleErrors: consoleMsgs.slice(0, 20),
    pageErrors: pageErrors.slice(0, 10),
  }, null, 1));

  await browser.close();
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
