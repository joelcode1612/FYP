// Probe which Material Symbols ligature names actually resolve in the font.
// A resolved ligature is one glyph (~1em wide); an unresolved name renders as
// literal letters and is much wider.
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

const NAMES = process.argv.slice(3);
const URL = process.argv[2];

(async () => {
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const page = await browser.newPage();
  await page.goto(URL, { waitUntil: 'domcontentloaded' });
  await page.evaluate(() => document.fonts.ready);
  const res = await page.evaluate((names) => {
    const probe = document.createElement('span');
    probe.style.cssText =
      'position:fixed;left:-9999px;font-family:"Material Symbols Outlined";font-size:20px;' +
      'font-variation-settings:"FILL" 0,"wght" 400,"GRAD" 0,"opsz" 24';
    document.body.appendChild(probe);
    const out = {};
    for (const n of names) {
      probe.textContent = n;
      out[n] = Math.round(probe.getBoundingClientRect().width);
    }
    probe.remove();
    return out;
  }, NAMES);
  const bad = Object.entries(res).filter(([, w]) => w > 30);
  console.log('resolved: ' + (NAMES.length - bad.length) + '/' + NAMES.length);
  console.log('UNRESOLVED: ' + (bad.length ? bad.map(([k, w]) => `${k}(${w}px)`).join(', ') : 'none'));
  await browser.close();
})();
