// Diagnostic: dump computed styles + bounding boxes for landing scene elements.
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = process.argv[2] || 'http://127.0.0.1:8124';

(async () => {
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(BASE + '/', { waitUntil: 'networkidle', timeout: 30000 });
  await page.waitForTimeout(1200);

  const out = await page.evaluate(() => {
    const sel = ['.lnd', '.topbar', '.nav', '.brand', '.navlinks', '.nav-actions', '.scroll-experience',
      '.scene-sticky', '.scene-mount', '.scene-ui', '.scene-copy', '.scene-copy h1', '.scene-copy p',
      '.glass-stack', '.camera-presets', '.scene-controls'];
    const res = {};
    for (const s of sel) {
      const el = document.querySelector(s);
      if (!el) { res[s] = 'MISSING'; continue; }
      const r = el.getBoundingClientRect();
      const c = getComputedStyle(el);
      res[s] = {
        box: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)],
        pos: c.position, display: c.display, color: c.color, vis: c.visibility, op: c.opacity,
        z: c.zIndex, left: c.left, top: c.top, right: c.right, bottom: c.bottom,
        w: c.width, h: c.height, transform: c.transform, overflow: c.overflow,
        fs: c.fontSize, order: el.parentElement ? Array.prototype.indexOf.call(el.parentElement.children, el) : -1,
      };
    }
    res.__body = { scrollW: document.documentElement.scrollWidth, innerW: window.innerWidth,
                   scrollH: document.documentElement.scrollHeight, bodyOverflowX: getComputedStyle(document.body).overflowX };
    res.__h1text = (document.querySelector('.scene-copy h1') || {}).textContent;
    res.__navlinksCount = document.querySelectorAll('.navlinks .navlinks-a').length;
    res.__navActions = Array.from(document.querySelectorAll('.nav-actions a')).map(a => {
      const r = a.getBoundingClientRect();
      return [a.textContent.trim(), Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)];
    });
    return res;
  });
  console.log(JSON.stringify(out, null, 1));
  await browser.close();
})();
