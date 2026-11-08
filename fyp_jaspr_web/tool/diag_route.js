// One-off: load a route with the harness and print the uncaught error text.
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = process.argv[2] || 'http://127.0.0.1:8124';
const ROUTE = process.argv[3] || '/owner';

(async () => {
  const b = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const ctx = await b.newContext({ viewport: { width: 1440, height: 980 } });
  const p = await ctx.newPage();
  await installHarnessSession(p, { role: 'owner' });
  p.on('pageerror', (e) => console.log('PAGEERR:', (e.message || '') + ' :: ' + (e.stack || '').slice(0, 400)));
  p.on('console', (m) => console.log('CONSOLE', m.type() + ':', m.text().slice(0, 300)));
  const resp = await p.goto(BASE + ROUTE, { waitUntil: 'networkidle', timeout: 60000 });
  await new Promise((r) => setTimeout(r, 1500));
  console.log('status', resp.status());
  console.log('body head:', (await p.evaluate(() => document.body.innerText)).replace(/\s+/g, ' ').slice(0, 300));
  await b.close();
})();
