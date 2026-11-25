// Stage 3 retrieval probe for the synthetic acceptance-test assessment.
//
// Two corrections over the earlier probe:
//  * `?id=` is the PROPERTY id (MD-03209), not the marketplace assessment id.
//  * A cold load of an /entrepreneur route races the auth bridge and bounces to
//    /login, so the probe settles the bridge on /login first and then navigates
//    client-side, which is what an owner clicking through the app actually does.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');
const fs = require('fs');

const PROPERTY = 'MD-03209';
const STAGE = process.argv[2] || 'ai_explanation';
const TARGET = `/entrepreneur/assessments?id=${PROPERTY}&stage=${STAGE}`;
const DIR = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/deliverables/screenshots/20261125_acceptance';
fs.mkdirSync(DIR, { recursive: true });

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = await ctx.newPage();
  await page.bringToFront();
  await page.setViewportSize({ width: 1440, height: 1500 });

  await page.goto('http://127.0.0.1:8093/login', { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.evaluate(async () => { try { await window.sitewiseAuth.ready; } catch (_) {} });
  await page.waitForTimeout(1500);

  await page.evaluate((t) => {
    history.pushState({}, '', t);
    window.dispatchEvent(new PopStateEvent('popstate', { state: {} }));
  }, TARGET);

  let state = 'UNKNOWN';
  try {
    state = await page.waitForFunction(() => {
      const t = document.body.innerText || '';
      if (/No property with this identifier/i.test(t)) return 'PROPERTY_NOT_FOUND';
      if (/Research objectives could not be read/i.test(t)) return 'error';
      if (/The confirmed source is not current/i.test(t)) return 'stale';
      if (/No research objectives yet/i.test(t)) return 'empty';
      if (/(9c16db41|495044db)/.test(t)) return 'cards';
      return false;
    }, null, { timeout: 75000, polling: 500 }).then(h => h.jsonValue());
  } catch (e) { state = 'TIMEOUT'; }

  await page.waitForTimeout(1500);
  const text = await page.evaluate(() => document.body.innerText || '');
  const slug = `${STAGE}_${Date.now()}`;
  fs.writeFileSync(`${DIR}/stage3_${STAGE}.txt`, text, 'utf8');
  await page.screenshot({ path: `${DIR}/stage3_${STAGE}.png`, fullPage: true });

  console.log('URL      :', page.url());
  console.log('TERMINAL :', state);
  const lines = text.split('\n').map(s => s.trim()).filter(Boolean);
  const keep = lines.filter(l => /proposal|objective|M2V2|Reading|No research|not current|could not|SUGGESTED|area|explore|Admission|Generate|permission|Question/i.test(l));
  console.log('--- relevant lines ---');
  console.log(keep.slice(0, 50).join('\n'));
  await page.close();
  await browser.close();
})().catch(e => { console.error('FAILED', e.message); process.exit(1); });
