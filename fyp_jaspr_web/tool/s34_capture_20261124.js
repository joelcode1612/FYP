// Capture the CURRENT Stage 3 and Stage 4 screens of the authorized test
// environment on :8093 (real session, real backend) and dump the actionable
// controls each stage exposes. Read-only: navigation + screenshots only.
const fs = require('fs');
const { chromium } = require('playwright-core');

const BASE = 'http://127.0.0.1:8093';
const ID = 'EP-02638';
const OUT = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/backend/var/e2e/shots';

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = await ctx.newPage();
  await page.setViewportSize({ width: 1440, height: 900 });

  const report = {};
  for (const [name, stage] of [
    ['stage3', 'location_evidence'],
    ['stage4', 'ai_explanation'],
  ]) {
    const url = `${BASE}/entrepreneur/assessments?id=${ID}&stage=${stage}`;
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(5000);
    // let late panels mount
    await page.waitForTimeout(2500);

    const file = `${OUT}/${name}_${ID}_20261124.png`;
    await page.screenshot({ path: file, fullPage: false, timeout: 60000 });

    const dump = await page.evaluate(() => {
      const vis = (el) => {
        const r = el.getBoundingClientRect();
        const s = getComputedStyle(el);
        return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
      };
      const btns = Array.from(document.querySelectorAll('button, a[role="button"], [role="button"]'))
        .filter(vis)
        .map((b) => ({
          text: (b.innerText || b.getAttribute('aria-label') || '').trim().replace(/\s+/g, ' ').slice(0, 120),
          disabled: b.hasAttribute('disabled') || b.getAttribute('aria-disabled') === 'true',
        }))
        .filter((b) => b.text);
      const cards = Array.from(document.querySelectorAll('.p1-card, .sw-assessment-stage, section'))
        .filter(vis)
        .map((c) => (c.innerText || '').trim().split('\n')[0].slice(0, 110))
        .filter(Boolean);
      const headings = Array.from(document.querySelectorAll('h1,h2,h3,h4'))
        .filter(vis)
        .map((h) => (h.innerText || '').trim().replace(/\s+/g, ' ').slice(0, 120))
        .filter(Boolean);
      return {
        url: location.href,
        title: document.title,
        headings,
        cards: Array.from(new Set(cards)).slice(0, 40),
        buttons: btns.slice(0, 60),
        bodyStart: (document.body.innerText || '').replace(/\s+/g, ' ').slice(0, 700),
      };
    });
    report[name] = { file, ...dump };
    console.log(`\n=== ${name} (${stage}) ===`);
    console.log('url:', dump.url);
    console.log('headings:', JSON.stringify(dump.headings));
    console.log('cards:', JSON.stringify(dump.cards.slice(0, 15)));
    console.log('buttons:', JSON.stringify(dump.buttons));
    console.log('bodyStart:', dump.bodyStart.slice(0, 400));
  }

  fs.writeFileSync(`${OUT}/stage3_stage4_dom_20261124.json`, JSON.stringify(report, null, 2));
  console.log('\nsaved screenshots + dom dump to', OUT);
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
