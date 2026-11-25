// Dump the full text of the AI Execution Status card + the key-fact cards on
// Stage 3 / Stage 4, so the analysis is based on real rendered copy.
const fs = require('fs');
const { chromium } = require('playwright-core');
const BASE = 'http://127.0.0.1:8093';
const ID = 'EP-02638';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = await ctx.newPage();
  await page.setViewportSize({ width: 1440, height: 900 });
  const out = {};
  for (const [name, stage] of [['stage3', 'location_evidence'], ['stage4', 'ai_explanation']]) {
    await page.goto(`${BASE}/entrepreneur/assessments?id=${ID}&stage=${stage}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(7000);
    out[name] = await page.evaluate(() => {
      const all = Array.from(document.querySelectorAll('*'));
      const pick = (re) => {
        const hits = all.filter((e) => re.test((e.innerText || '').trim()) && e.children.length < 60);
        const smallest = hits.sort((a, b) => (a.innerText || '').length - (b.innerText || '').length)[0];
        return smallest ? (smallest.innerText || '').replace(/\n{3,}/g, '\n\n').trim() : null;
      };
      // The AI Execution Status panel: nearest ancestor containing the heading.
      const head = all.find((e) => /^AI execution status$/i.test((e.innerText || '').trim()));
      let aiCard = null;
      if (head) {
        let n = head;
        for (let i = 0; i < 6 && n.parentElement; i++) {
          n = n.parentElement;
          if (/Refresh AI status/i.test(n.innerText || '')) break;
        }
        aiCard = (n.innerText || '').trim();
      }
      return {
        aiExecutionStatus: aiCard,
        whatHappensHere: pick(/^What happens here\?/i),
        researchSafeguard: pick(/^Research safeguard/i),
        sourceCard: pick(/^Source\b/),
        stage4NotReady: pick(/^Stage 4 is not ready yet/i),
        requiredChecks: pick(/^Required checks/i),
        reviewSummary: pick(/^Review summary/i),
        objectiveSources: pick(/^Research objective sources/i),
      };
    });
  }
  console.log(JSON.stringify(out, null, 2));
  fs.writeFileSync('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/backend/var/e2e/shots/stage3_stage4_cards_20261124.json', JSON.stringify(out, null, 2));
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
