// Temporary diagnostic: dump the rendered structure of routes that failed
// verify_pages.js, to tell an intentional empty state apart from a crash.
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = process.argv[2] || 'http://localhost:8095';

const ROUTES = [
  '/entrepreneur/explanation?property=EP-03227',
  '/entrepreneur/report?id=EP-03227',
  '/entrepreneur/tour?id=EP-03227',
  '/owner/properties',
  '/owner/tours',
];

(async () => {
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  await installHarnessSession(page, { role: 'auto' });

  for (const route of ROUTES) {
    await page.goto(BASE + route, { waitUntil: 'networkidle', timeout: 30000 });
    await page.waitForTimeout(2500);
    const info = await page.evaluate(() => {
      const main = document.querySelector('main') || document.body;
      const classes = [...new Set([...main.querySelectorAll('*')].flatMap((el) => [...el.classList]))];
      return {
        url: location.pathname + location.search,
        text: (main.innerText || '').replace(/\s+/g, ' ').slice(0, 420),
        classes: classes.join(' '),
      };
    });
    console.log(`\n### ${info.url}\nclasses: ${info.classes}\ntext: ${info.text}`);
  }
  if (errors.length) console.log('\n--- errors ---\n' + [...new Set(errors)].slice(0, 10).join('\n'));
  await browser.close();
})();
