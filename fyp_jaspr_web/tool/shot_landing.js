const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = process.argv[2] || 'http://127.0.0.1:8130';
const OUT = 'C:/Users/Lenovo/AndroidStudioProjects/FYP/fyp_jaspr_web/_shots';
const fs = require('fs');
fs.mkdirSync(OUT, { recursive: true });

(async () => {
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(BASE + '/', { waitUntil: 'networkidle', timeout: 60000 });
  await page.waitForTimeout(2500);

  // full page
  await page.screenshot({ path: `${OUT}/landing_full.png`, fullPage: true });
  console.log('shot full');

  // recommendations section
  const rec = await page.$('#recommendations');
  if (rec) {
    await rec.scrollIntoViewIfNeeded();
    await page.waitForTimeout(800);
    await rec.screenshot({ path: `${OUT}/landing_recommendations.png` });
    console.log('shot recommendations');
  }

  // footer
  const footer = await page.$('.site-footer');
  if (footer) {
    await footer.scrollIntoViewIfNeeded();
    await page.waitForTimeout(500);
    await footer.screenshot({ path: `${OUT}/landing_footer.png` });
    console.log('shot footer');
  }

  // measure key widths
  const metrics = await page.evaluate(() => {
    const q = (s) => document.querySelector(s);
    const r = (el) => el ? { w: Math.round(el.getBoundingClientRect().width), x: Math.round(el.getBoundingClientRect().x) } : null;
    return {
      viewport: window.innerWidth,
      wrap: r(q('#recommendations .wrap')),
      footerGrid: r(q('.footer-grid')),
      candidateGrid: r(q('.candidate-grid')),
      candidateCard: r(q('.candidate-card')),
      workflow: r(q('.workflow')),
      interactiveStage: r(q('.interactive-stage')),
      footerCols: [...document.querySelectorAll('.footer-grid > *')].map(el => Math.round(el.getBoundingClientRect().width)),
    };
  });
  console.log(JSON.stringify(metrics, null, 2));

  await browser.close();
})();
