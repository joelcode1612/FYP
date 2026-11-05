// Debug: raw outerHTML of both .lp-social buttons (SSR + hydrated).
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = 'http://127.0.0.1:8141';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const b = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const ctx = await b.newContext({ viewport: { width: 1440, height: 980 } });
  const p = await ctx.newPage();
  // Capture the SSR HTML before hydration by intercepting the initial DOM.
  const resp = await p.goto(BASE + '/login/', { waitUntil: 'domcontentloaded', timeout: 60000 });
  const ssrHtml = await p.content();
  const ssrSocial = ssrHtml.match(/<button[^>]*lp-social[^>]*>[\s\S]*?<\/button>/g) || [];
  console.log('--- SSR social buttons ---');
  ssrSocial.forEach((h, i) => console.log(`SSR social[${i}]:`, h.slice(0, 260)));
  await sleep(1200);
  const socials = p.locator('.lp-social');
  const n = await socials.count();
  console.log('--- hydrated social buttons ---');
  for (let i = 0; i < n; i++) {
    const html = await socials.nth(i).evaluate((el) => el.outerHTML);
    console.log(`hydrated social[${i}]:`, html.slice(0, 260));
  }
  await b.close();
})();
