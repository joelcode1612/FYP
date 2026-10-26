// Capture screenshots of key routes for visual verification.
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = process.argv[2] || 'http://127.0.0.1:8124';
const OUT = process.argv[3] || 'C:/Users/Lenovo/AndroidStudioProjects/FYP/fyp_jaspr_web/_verify_shots';
const fs = require('fs');
fs.mkdirSync(OUT, { recursive: true });

const SHOTS = [
  ['/', 'landing_top', 1440],
  ['/', 'landing_full', 1440, true],
  ['/entrepreneur', 'entrepreneur', 1440],
  ['/admin/users', 'admin_users', 1440],
  ['/owner', 'owner', 1440],
  ['/admin', 'admin', 1440],
  ['/landing', 'landing_route', 1440],
];

(async () => {
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  for (const [route, name, w, full] of SHOTS) {
    const ctx = await browser.newContext({ viewport: { width: w, height: 900 } });
    const page = await ctx.newPage();
    await page.goto(BASE + route, { waitUntil: 'networkidle', timeout: 30000 });
    await page.waitForTimeout(1200);
    await page.screenshot({ path: `${OUT}/${name}.png`, fullPage: !!full });
    console.log(`shot ${name} (${route})`);
    await ctx.close();
  }
  await browser.close();
})();
