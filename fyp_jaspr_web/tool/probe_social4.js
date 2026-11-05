// Verify social buttons: tag, aria-label, aria-disabled, disabled, text.
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = 'http://127.0.0.1:8141';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  const b = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const p = await b.newPage();
  await p.goto(BASE + '/login/', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(800);
  const socials = p.locator('.lp-social');
  const n = await socials.count();
  for (let i = 0; i < n; i++) {
    const info = await socials.nth(i).evaluate((el) => ({
      tag: el.tagName.toLowerCase(),
      text: el.textContent.trim().slice(0, 24),
      ariaLabel: el.getAttribute('aria-label'),
      ariaDisabled: el.getAttribute('aria-disabled'),
      disabledAttr: el.hasAttribute('disabled'),
      tabindex: el.getAttribute('tabindex'),
    }));
    console.log(`social[${i}]`, JSON.stringify(info));
  }
  await b.close();
})();
