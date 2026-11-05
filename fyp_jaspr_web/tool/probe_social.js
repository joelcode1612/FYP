// Debug: dump each .lp-social button's disabled state + the auth config source.
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = 'http://127.0.0.1:8141';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const b = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const ctx = await b.newContext({ viewport: { width: 1440, height: 980 } });
  const p = await ctx.newPage();
  await p.goto(BASE + '/login/', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(800);

  const socials = p.locator('.lp-social');
  const n = await socials.count();
  for (let i = 0; i < n; i++) {
    const info = await socials.nth(i).evaluate((el) => ({
      text: el.textContent.trim().slice(0, 40),
      disabledAttr: el.hasAttribute('disabled'),
      disabledProp: el.disabled,
      ariaLabel: el.getAttribute('aria-label'),
    }));
    console.log(`social[${i}]`, JSON.stringify(info));
  }
  const note = await p.locator('.lp-social-note').innerText().catch(() => 'MISSING');
  console.log('social-note:', note);
  // Is the auth bundle exposing configured? Check window.sitewiseAuth if present.
  const cfg = await p.evaluate(() => {
    const a = window.sitewiseAuth;
    return {
      hasAuth: !!a,
      configured: a ? a.configured : 'n/a',
      keys: a ? Object.keys(a).slice(0, 40) : [],
    };
  });
  console.log('window.sitewiseAuth:', JSON.stringify(cfg).slice(0, 400));
  const acJson = await p.evaluate(async () => {
    try {
      const r = await fetch('/auth-config.json');
      return await r.text();
    } catch (e) { return 'fetch failed: ' + e.message; }
  });
  console.log('auth-config.json:', acJson.slice(0, 300));
  await b.close();
})();
