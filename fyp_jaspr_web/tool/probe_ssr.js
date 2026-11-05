// Dump raw SSR HTML around the social buttons (before hydration).
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = 'http://127.0.0.1:8141';
(async () => {
  const b = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const p = await b.newPage();
  const resp = await p.goto(BASE + '/login/', { waitUntil: 'domcontentloaded', timeout: 60000 });
  const html = await resp.text();
  const idx = html.indexOf('lp-social');
  console.log('--- SSR raw around first social button ---');
  console.log(html.slice(idx - 40, idx + 420));
  await b.close();
})();
