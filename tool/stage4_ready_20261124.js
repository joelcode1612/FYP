// Stage 4 readiness capture on the freshly deployed bundle: Section A/B,
// the two execution rails, and the exact state of the Generate action.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');
const fs = require('fs');

const URL = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638&stage=ai_explanation';
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
  await page.setViewportSize({ width: 1440, height: 1400 });

  await page.goto('http://127.0.0.1:8093/', { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(4000);
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60000 });

  try {
    await page.waitForFunction(() => document.body.innerText.includes('Section B'),
      null, { timeout: 60000, polling: 500 });
  } catch (_) {}
  await page.waitForTimeout(3000);

  const state = await page.evaluate(() => {
    const t = document.body.innerText || '';
    const buttons = [...document.querySelectorAll('button')];
    const gen = buttons.find(b => /Generate questions for this objective/i.test(b.textContent || ''));
    return {
      sectionA: /Section A/.test(t),
      sectionB: /Section B/.test(t),
      fixedTemplates: (t.match(/13\b[^\n]{0,40}(fixed|governed)/i) || [])[0] || null,
      rails: (t.match(/✓ Reserved/g) || []).length,
      states: (t.match(/State:\s*[A-Z_]+/g) || []).slice(0, 4),
      candidateCountLine: (t.match(/Direct-QG:[^\n]*/i) || [])[0] || null,
      sectionBZero: (t.match(/Section B[\s\S]{0,120}/i) || [])[0] || null,
      generatePresent: !!gen,
      generateEnabled: gen ? !gen.disabled : null,
      recoveryFormPresent: /Authorise one recovery attempt/i.test(t),
      consentFormPresent: /Review the permission terms/i.test(t),
      progressText: (t.match(/Generating…[^\n]*/) || [])[0] || null,
    };
  });

  await page.evaluate(() => {
    const el = [...document.querySelectorAll('*')].find(n => n.children.length === 0 && /Section B/i.test(n.textContent || ''));
    if (el) el.scrollIntoView({ block: 'center' });
  });
  await page.waitForTimeout(1200);
  await page.screenshot({ path: `${DIR}/stage4_ready_2340.png` });

  console.log(JSON.stringify(state, null, 1));
  await browser.close();
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
