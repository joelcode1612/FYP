const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');
const TARGET = '/entrepreneur/assessments?id=MD-03209&stage=assessment_report';
(async () => {
  const b = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = b.contexts()[0];
  const page = await ctx.newPage();
  const seen = [];
  page.on('response', async (r) => {
    const u = r.url();
    if (!/composed-questionnaire|questionnaire-preview|business-context|confirmation-current|\/m2\/assessments\//.test(u)) return;
    let body = '';
    try { body = (await r.text()).slice(0, 260); } catch (_) {}
    seen.push({ status: r.status(), url: u.replace('http://127.0.0.1:8093', ''), body });
  });
  await page.goto('http://127.0.0.1:8093/login', { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.evaluate(async () => { try { await window.sitewiseAuth.ready; } catch (_) {} });
  await page.waitForTimeout(1200);
  await page.evaluate((t) => { history.pushState({}, '', t); window.dispatchEvent(new PopStateEvent('popstate', { state: {} })); }, TARGET);
  await page.waitForTimeout(15000);
  for (const s of seen) console.log(s.status, s.url, '\n   ', s.body.replace(/\s+/g, ' ').slice(0, 200));
  await page.close(); await b.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
