// Screenshot a dialog in the workspace shell.
//
// `shot.js` captures a page as it loads; a dialog only exists after a click, so
// this opens one route, clicks a trigger, and captures the overlay. Uses the
// same harness session as shot.js (HARNESS=1, ROLE=…).
//
// Usage: node shot_dialog.js <outdir> <width> <url> <triggerSelector> <name>
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

(async () => {
  const [, , outdir, widthArg, url, trigger, name] = process.argv;
  const width = Number(widthArg || 1440);
  fs.mkdirSync(outdir, { recursive: true });

  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const ctx = await browser.newContext({ viewport: { width, height: 1000 }, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  if (process.env.HARNESS === '1') {
    await installHarnessSession(page, { role: process.env.ROLE || 'auto' });
  }

  await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });
  await page.waitForTimeout(1500);
  await page.click(trigger);
  await page.waitForSelector('.overlay .dialog', { timeout: 8000 });
  await page.waitForTimeout(400);
  const out = path.join(outdir, `${name}-${width}.png`);
  await page.screenshot({ path: out, animations: 'disabled', caret: 'hide' });
  const box = await page.evaluate(() => {
    const d = document.querySelector('.dialog');
    const r = d.getBoundingClientRect();
    return { w: Math.round(r.width), h: Math.round(r.height), text: (d.innerText || '').replace(/\s+/g, ' ').slice(0, 160) };
  });
  console.log(`OK ${name} ${width}px dialog=${box.w}x${box.h} :: ${box.text}\n   ${out}`);
  if (errors.length) console.log('errors:\n  ' + [...new Set(errors)].slice(0, 5).join('\n  '));
  await browser.close();
})();
