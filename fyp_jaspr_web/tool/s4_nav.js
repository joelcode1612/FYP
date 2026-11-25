const { chromium } = require('playwright-core');

const BASE = 'http://127.0.0.1:8093';
const URL_WS = BASE + '/entrepreneur/assessments?id=EP-02087';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = await ctx.newPage();
  await page.goto(URL_WS, { waitUntil: 'domcontentloaded', timeout: 40000 });
  await page.waitForTimeout(9000);

  const s = await page.evaluate(() => {
    const items = [];
    document.querySelectorAll('button,a,li,[role=button],[role=tab]').forEach((el) => {
      const t = (el.innerText || '').replace(/\s+/g, ' ').trim();
      if (/Question review|Business review and research goals|Questionnaire preview/i.test(t) && t.length < 90) {
        items.push({
          tag: el.tagName,
          text: t.slice(0, 70),
          disabled: el.hasAttribute('disabled') || el.getAttribute('aria-disabled') === 'true',
          cls: (el.className || '').toString().slice(0, 50),
        });
      }
    });
    const heads = Array.from(document.querySelectorAll('h1,h2,h3,h4'))
      .map((h) => h.innerText.replace(/\s+/g, ' ').trim())
      .filter(Boolean);
    const m = document.body.innerText.match(/\d+ \/ 5[^\n]*/);
    return { items, heads, progress: m ? m[0] : '' };
  });

  console.log(JSON.stringify(s, null, 1));
  process.exit(0); // disconnect only — never browser.close()
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
