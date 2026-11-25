const { chromium } = require('playwright-core');

const URL_WS = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02087';

const SNAP = () => {
  const txt = document.body.innerText;
  const cards = Array.from(document.querySelectorAll('.p1-card'));
  const A = cards.find((c) => /Section A · Fixed core questionnaire/.test(c.innerText));
  const B = cards.find((c) => /Section B · Additional question candidates/.test(c.innerText));
  const ids = A ? Array.from(A.querySelectorAll('.p1-qid')).map((e) => e.innerText.trim()) : [];
  return {
    questionCount: ids.length,
    firstLast: ids.length ? [ids[0], ids[ids.length - 1]] : [],
    sectionAButtons: A ? Array.from(A.querySelectorAll('button')).map((b) => b.innerText.trim()) : null,
    sectionBButtons: B ? Array.from(B.querySelectorAll('button')).map((b) => b.innerText.replace(/\s+/g, ' ').trim()) : null,
    sectionBText: B ? B.innerText.replace(/\s+/g, ' ').slice(0, 600) : '',
    summary: A ? (A.innerText.match(/\d+ questions[^\n]*/) || [''])[0] : '',
    progress: (txt.match(/\d+ \/ 5[^\n]*/) || [''])[0],
  };
};

async function gotoStage4(page) {
  await page.goto(URL_WS, { waitUntil: 'domcontentloaded', timeout: 45000 });
  const btn = page.getByRole('button', { name: /View Stage 4: Question review/i });
  try {
    await btn.first().waitFor({ state: 'visible', timeout: 45000 });
  } catch (e) {
    const b = await page.evaluate(() => document.body.innerText.replace(/\s+/g, ' ').slice(0, 500));
    return { ok: false, reason: 'View Stage 4 control never appeared', body: b };
  }
  await btn.first().click();
  // Wait until Section A actually exists rather than guessing a duration.
  await page.waitForFunction(
    () => Array.from(document.querySelectorAll('.p1-card')).some((c) => /Section A · Fixed core/.test(c.innerText)),
    null, { timeout: 45000 },
  );
  await page.waitForTimeout(1500);
  return { ok: true };
}

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];

  // Close only the app tabs I created; leave the owner's other tabs alone.
  for (const p of ctx.pages()) {
    if ((p.url() || '').includes('127.0.0.1:8093')) { try { await p.close(); } catch (e) {} }
  }

  const page = await ctx.newPage();
  const r1 = await gotoStage4(page);
  if (!r1.ok) { console.log('FIRST LOAD FAILED:', JSON.stringify(r1, null, 1)); process.exit(0); }
  const first = await page.evaluate(SNAP);

  await page.reload({ waitUntil: 'domcontentloaded', timeout: 45000 });
  const r2 = await gotoStage4(page);
  if (!r2.ok) { console.log('RELOAD FAILED:', JSON.stringify(r2, null, 1)); process.exit(0); }
  const second = await page.evaluate(SNAP);

  console.log('=== FIRST LOAD ===');
  console.log(JSON.stringify(first, null, 1));
  console.log('=== AFTER FULL RELOAD ===');
  console.log(JSON.stringify(second, null, 1));
  console.log('=== PERSISTENCE ===');
  console.log('questionCount:', first.questionCount, '->', second.questionCount, '| equal:', first.questionCount === second.questionCount);
  console.log('summary equal :', first.summary === second.summary);
  console.log('progress equal:', first.progress === second.progress);
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
