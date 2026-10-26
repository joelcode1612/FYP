// Verification: serve the built site and confirm the new icon + signup photo
// <img> elements load (naturalWidth > 0), capture screenshots for review.
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = 'http://127.0.0.1:8141';
const OUT = 'C:/Users/Lenovo/AndroidStudioProjects/FYP/fyp_jaspr_web/tool/_diag';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function checkPage(browser, path, viewport, tag) {
  const ctx = await browser.newContext({ viewport, deviceScaleFactor: 1 });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', (e) => errs.push('PAGEERR: ' + e.message));
  p.on('console', (m) => {
    if (m.type() === 'error' && !m.text().includes('404')) errs.push('CONSOLE: ' + m.text().slice(0, 160));
  });
  await p.goto(BASE + path, { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(900);
  const imgs = await p.evaluate(() =>
    Array.from(document.images).map((i) => ({
      src: i.getAttribute('src'),
      nw: i.naturalWidth,
      nh: i.naturalHeight,
    }))
  );
  const broken = imgs.filter((i) => !i.src || i.nw === 0);
  const shot = `${OUT}/${tag}.png`;
  await p.screenshot({ path: shot, fullPage: false });
  console.log(`\n[${tag}] ${path} @ ${viewport.width}x${viewport.height}`);
  console.log('  images:');
  for (const i of imgs) console.log(`    ${i.nw}x${i.nh}  ${i.src}`);
  console.log('  broken images:', broken.length);
  console.log('  errors:', errs.length ? errs.join(' | ') : 'none');
  await ctx.close();
  return broken.length === 0 && errs.length === 0;
}

(async () => {
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  let ok = true;
  ok = (await checkPage(browser, '/', { width: 1440, height: 980 }, 'v_home')) && ok;
  ok = (await checkPage(browser, '/login/', { width: 1440, height: 980 }, 'v_login')) && ok;
  ok = (await checkPage(browser, '/signup/', { width: 1440, height: 980 }, 'v_signup')) && ok;
  ok = (await checkPage(browser, '/signup/', { width: 390, height: 844 }, 'v_signup_mobile')) && ok;
  await browser.close();
  console.log('\nRESULT:', ok ? 'PASS' : 'FAIL');
  process.exit(ok ? 0 : 1);
})();
