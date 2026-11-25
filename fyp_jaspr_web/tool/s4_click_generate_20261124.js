// Click the generation action once it exists, then capture the governed
// response. Longer, explicit waits; a single click, no retry.
const fs = require('fs');
const { chromium } = require('playwright-core');
const BASE = 'http://127.0.0.1:8093';
const ID = 'EP-02638';
const OUT = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/backend/var/e2e/shots';

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = await ctx.newPage();
  await page.setViewportSize({ width: 1440, height: 1000 });
  // A background tab is timer-throttled by Chrome, which stalls the panel's
  // sequential reads and makes it look like a hang.
  await page.bringToFront();

  let captured = null;
  page.on('response', async (r) => {
    if (!/qg-candidates\/generate/.test(r.url())) return;
    try { captured = { status: r.status(), body: await r.text() }; }
    catch (e) { captured = { status: r.status(), body: '<unreadable>' }; }
  });

  await page.goto(`${BASE}/entrepreneur/assessments?id=${ID}&stage=ai_explanation`, {
    waitUntil: 'domcontentloaded', timeout: 60000,
  });

  try {
    await page.waitForFunction(
      () => Array.from(document.querySelectorAll('button'))
        .some((b) => /Generate questions for this objective/i.test(b.innerText || '')),
      null, { timeout: 120000, polling: 1000 },
    );
    console.log('button present');
  } catch (e) {
    console.log('button NEVER appeared within 120s');
    const titles = await page.evaluate(() =>
      Array.from(document.querySelectorAll('.p1-card')).map((c) => (c.innerText || '').split('\n')[0]));
    console.log('cards on screen:', JSON.stringify(titles));
    process.exit(2);
  }

  // Click through the DOM so a hidden overlay cannot swallow the event.
  await page.evaluate(() => {
    const b = Array.from(document.querySelectorAll('button'))
      .find((x) => /Generate questions for this objective/i.test(x.innerText || ''));
    if (b) b.scrollIntoView({ block: 'center' });
    if (b) b.click();
  });
  console.log('clicked');
  await page.waitForTimeout(10000);

  const notice = await page.evaluate(() => {
    const texts = Array.from(document.querySelectorAll('p, .p1-notice'))
      .map((e) => (e.innerText || '').trim())
      .filter((t) => /generation is unavailable|No candidate was produced|Question candidate saved|could not be verified/i.test(t));
    return Array.from(new Set(texts)).slice(0, 4);
  });

  console.log('\n--- server response ---');
  console.log(captured ? `status=${captured.status}\n${captured.body.slice(0, 900)}` : '(no request captured)');
  console.log('\n--- UI notice ---');
  console.log(notice.length ? notice.join('\n---\n') : '(none found)');

  await page.screenshot({ path: `${OUT}/stage4_generate_click_20261124.png`, clip: { x: 0, y: 0, width: 1440, height: 1000 }, timeout: 60000 });
  fs.writeFileSync(`${OUT}/stage4_generate_click_20261124.json`, JSON.stringify({ captured, notice }, null, 2));
  console.log('\nsaved screenshot + json');
  process.exit(0);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
