const { chromium } = require('playwright-core');

const URL_WS = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02087';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = await ctx.newPage();
  await page.goto(URL_WS, { waitUntil: 'domcontentloaded', timeout: 40000 });
  await page.waitForTimeout(8000);

  // Enter Stage 4 through the UI control, not by guessing a URL.
  await page.getByRole('button', { name: /View Stage 4: Question review/i }).click();
  await page.waitForTimeout(20000);

  const s = await page.evaluate(() => {
    const txt = document.body.innerText;
    const cards = Array.from(document.querySelectorAll('.p1-card'));
    const sectionA = cards.find((c) => /Section A · Fixed core questionnaire/.test(c.innerText));
    const sectionB = cards.find((c) => /Section B · Additional question candidates/.test(c.innerText));

    const ids = sectionA
      ? Array.from(sectionA.querySelectorAll('.p1-qid')).map((e) => e.innerText.trim())
      : [];

    // Every button inside Section A: the fixed core must offer none.
    const sectionAButtons = sectionA
      ? Array.from(sectionA.querySelectorAll('button')).map((b) => b.innerText.replace(/\s+/g, ' ').trim())
      : [];

    const stems = sectionA
      ? Array.from(sectionA.querySelectorAll('.p1-qtitle')).map((e) => e.innerText.replace(/\s+/g, ' ').trim())
      : [];

    return {
      heading: (document.querySelector('.sw-assessment-journey__step[aria-current], .sw-assessment-journey__step') || {}).innerText || '',
      hasSectionA: !!sectionA,
      hasSectionB: !!sectionB,
      sectionAHead: sectionA ? sectionA.querySelector('.p1-card__title').innerText.trim() : '',
      sectionBHead: sectionB ? sectionB.querySelector('.p1-card__title').innerText.trim() : '',
      questionIds: ids,
      questionCount: ids.length,
      sectionAButtons,
      unresolvedVisible: stems.filter((x) => x.includes('[named area]')).length,
      stemsWithBracket: stems.filter((x) => /\[[^\]]+\]/.test(x)),
      summaryLine: sectionA ? (sectionA.innerText.match(/\d+ questions[^\n]*/) || [''])[0] : '',
      progress: (txt.match(/\d+ \/ 5[^\n]*/) || [''])[0],
      bodyLen: txt.length,
    };
  });

  console.log(JSON.stringify(s, null, 1));
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
