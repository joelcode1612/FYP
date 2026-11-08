// Screenshots of the five-screen administrator operations suite, at the two
// verification widths (1440 desktop / 390 mobile), with the stand-in session
// installed so the guarded routes render.
//
// Usage: node tool/shot_admin_ops.js [baseUrl] [outDir]
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

const BASE = process.argv[2] || 'http://127.0.0.1:8090';
const OUT = process.argv[3] || 'C:/Users/Lenovo/AndroidStudioProjects/FYP/fyp_jaspr_web/_verify_shots';
const fs = require('fs');
fs.mkdirSync(OUT, { recursive: true });

const SHOTS = [
  ['/admin/ownership', 'admin_ownership'],
  ['/admin/agents', 'admin_agents'],
  ['/admin/campaigns', 'admin_campaigns'],
  ['/admin/activity', 'admin_activity'],
  ['/admin/surveys', 'admin_surveys'],
];

(async () => {
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  for (const [route, name] of SHOTS) {
    for (const width of [1440, 390]) {
      const ctx = await browser.newContext({ viewport: { width, height: 900 } });
      const page = await ctx.newPage();
      await installHarnessSession(page, { role: 'admin' });
      await page.goto(BASE + route, { waitUntil: 'networkidle', timeout: 30000 });
      await page.waitForTimeout(1200);
      await page.screenshot({ path: `${OUT}/${name}_${width}.png` });
      console.log(`shot ${name}_${width} (${route})`);
      await ctx.close();
    }
  }
  await browser.close();
})().catch((e) => {
  console.error(e.message);
  process.exit(1);
});