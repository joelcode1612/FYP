// Screenshot the five stages of the uploaded reference mockup so the app's
// checkpoint views can be compared against it one-to-one.
// Usage: node tool/shot_reference_steps.js <reference.html> <outdir>
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

(async () => {
  const [, , refArg, outArg] = process.argv;
  const ref = refArg || 'C:/Users/Lenovo/Downloads/SiteWise_Assessment_Step5_Button_Fixed.html';
  const outdir = outArg || 'build/shots/ref';
  fs.mkdirSync(outdir, { recursive: true });

  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox', '--no-proxy-server'] });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  await page.goto('file:///' + ref.replace(/\\/g, '/'), { waitUntil: 'load' });
  await page.waitForTimeout(600);
  for (const n of [1, 2, 3, 4, 5]) {
    await page.click(`button.journey-step[data-stage="${n}"]`);
    await page.waitForTimeout(500);
    await page.screenshot({ path: path.join(outdir, `ref_step${n}.png`), fullPage: true });
  }
  console.log('saved 5 reference screenshots in', outdir);
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
