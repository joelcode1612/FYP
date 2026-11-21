// Verify the entrepreneur home no longer shows the "Load assigned research
// reviews" panel/button, and capture the page for visual evidence.
// Usage: NODE_PATH=... node tool/shot_dashboard_no_button.js [baseUrl] [outdir]
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness.js');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

(async () => {
  const [, , baseArg, outArg] = process.argv;
  const base = baseArg || 'http://127.0.0.1:8091';
  const outdir = outArg || 'tool/screenshots';
  fs.mkdirSync(outdir, { recursive: true });

  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-sandbox', '--no-proxy-server'],
  });
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
    bypassCSP: true,
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push('console: ' + m.text());
  });
  await installHarnessSession(page, { role: 'entrepreneur' });
  await page.goto(`${base}/entrepreneur`, {
    waitUntil: 'networkidle',
    timeout: 30000,
  });
  await page.waitForSelector('.sw-dash', { timeout: 15000 });
  await page.waitForTimeout(600);

  const text = await page.evaluate(() => document.body.innerText);
  const checks = {
    'home renders': text.includes('Welcome back') || text.includes('ENTREPRENEUR WORKSPACE'),
    'review button gone': !text.includes('Load assigned research reviews'),
    'no candidate panel text': !text.includes('Scientific authorization pending') &&
      !text.includes('Review unavailable. Reload your assignments.'),
    'kpis still present': text.includes('Saved properties') || text.includes('Assessments') || text.includes('Recommendations'),
  };
  const out = path.join(outdir, 'dashboard_no_review_button.png');
  await page.screenshot({ path: out, fullPage: true });
  console.log('checks:', JSON.stringify(checks, null, 1));
  console.log('saved', out);
  console.log(errors.length ? errors.join('\n') : 'no console/page errors');
  await browser.close();
})().catch((e) => {
  console.error('FATAL', e.message);
  process.exit(1);
});
