// Capture Stage 3, Stage 4, Stage 5 and the LLM execution progress indicator
// from the real application on :8093. No fixtures, no stubbed responses.
const fs = require('fs');
const path = require('path');
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');

const OUT = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/deliverables/screenshots/20261124_stage4_live';
const BASE = 'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638&stage=';

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];

  const page = ctx.pages().find(p => p.url().includes('127.0.0.1:8093'))
    || await ctx.newPage();
  await page.bringToFront();
  await page.setViewportSize({ width: 1440, height: 1000 });

  const stages = [
    ['location_evidence', 'stage3'],
    ['ai_explanation', 'stage4'],
    ['assessment_report', 'stage5'],
  ];

  for (const [slug, name] of stages) {
    await page.goto(BASE + slug, { waitUntil: 'domcontentloaded', timeout: 60000 });
    // The workspace issues a long chain of authenticated reads, and the AI
    // execution card is read separately afterwards. Waiting for the stage
    // heading alone captures the card mid-flight, so wait for the card to stop
    // saying it is loading and to report a real state.
    try {
      await page.waitForFunction(() => {
        const body = document.body.innerText;
        if (!body.includes('AI Execution Status')) return false;
        if (body.includes('Loading verified status')) return false;
        return /State: (BLOCKED|PROCESSING|RETURNED|VALIDATING|PERSISTED|FAILED|UNKNOWN_OUTCOME)/.test(body);
      }, { timeout: 150000 });
    } catch (e) { console.log(`  [${name}] AI card did not settle; capturing as-is`); }
    await page.waitForTimeout(2500);
    const file = path.join(OUT, `${name}_20261124.png`);
    await page.screenshot({ path: file, fullPage: true });
    const text = await page.evaluate(() => document.body.innerText.slice(0, 400));
    console.log(`[${name}] ${file}`);
    console.log(`  heading: ${text.split('\n').filter(Boolean).slice(0, 3).join(' | ')}`);
  }

  // The progress indicator lives in the AI Execution Status card. Capture it
  // as its own image so the rail is legible.
  await page.goto(BASE + 'ai_explanation', { waitUntil: 'domcontentloaded', timeout: 60000 });
  try {
    await page.waitForFunction(
      () => document.body.innerText.includes('AI Execution Status'),
      { timeout: 120000 });
  } catch (e) { console.log('  (AI Execution Status not found)'); }
  await page.waitForTimeout(6000);

  const card = page.locator('.p1-ai').first();
  if (await card.count()) {
    await card.scrollIntoViewIfNeeded();
    await page.waitForTimeout(1200);
    const file = path.join(OUT, 'progress_indicator_20261124.png');
    await card.screenshot({ path: file });
    console.log(`[progress] ${file}`);
    const txt = await card.innerText();
    console.log('  --- card text ---');
    console.log(txt.split('\n').map(l => '  ' + l).join('\n'));
  } else {
    console.log('[progress] .p1-ai card not present on this stage');
  }

  await browser.close();
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
