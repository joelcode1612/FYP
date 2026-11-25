const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');
(async () => {
  const b = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = b.contexts()[0];
  const page = ctx.pages().find(p => p.url().includes('127.0.0.1:8093')) || ctx.pages()[0];
  await page.bringToFront();
  const out = await page.evaluate(async () => {
    let token = null;
    try { const raw = localStorage.getItem('sb-lzdpjwmcjbhtkzkqudyt-auth-token'); if (raw) token = JSON.parse(raw).access_token; } catch (e) {}
    const H = { accept: 'application/json' }; if (token) H.authorization = 'Bearer ' + token;
    const r = await fetch('/api/v1/m2/assessments/0f958d15-c629-4df4-90b1-ba444e042612/ai-execution-status', { headers: H, credentials: 'same-origin' });
    let body = null; try { body = await r.json(); } catch (e) { body = 'PARSE_FAIL'; }
    return { status: r.status, body };
  });
  console.log(JSON.stringify(out, null, 1).slice(0, 3000));
  await b.close();
})().catch(e => { console.error(e.message); process.exit(2); });
