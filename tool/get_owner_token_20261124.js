// Prints the Supabase access token from the signed-in page so a curl probe can
// reproduce exactly what the browser sends. Only a short fingerprint is echoed.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  let page = null;
  for (const ctx of browser.contexts()) for (const p of ctx.pages()) if (p.url().includes('127.0.0.1:8093')) page = p;
  if (!page) { console.error('no page'); process.exit(2); }
  const token = await page.evaluate(() => {
    for (const k of Object.keys(localStorage)) {
      if (k.includes('auth-token')) {
        try {
          const v = JSON.parse(localStorage.getItem(k));
          if (v && v.access_token) return v.access_token;
        } catch (_) {}
      }
    }
    return null;
  });
  if (!token) { console.error('no token'); process.exit(3); }
  require('fs').writeFileSync('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/backend/var/e2e/pg18/.owner_token.tmp', token);
  console.log('token fingerprint', token.slice(0, 12) + '…' + token.slice(-6), 'len', token.length);
  await browser.close();
})().catch(e => { console.error('ERROR', e.message); process.exit(2); });
