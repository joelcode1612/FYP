// Diagnostic: inspect the entrepreneur .lp-submit button for any overlay /
// instability / page errors that could cause a click timeout.
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = 'http://127.0.0.1:8141';

(async () => {
  const b = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const p = await b.newPage({ viewport: { width: 1440, height: 980 } });
  const errs = [];
  p.on('pageerror', e => errs.push('PAGEERR: ' + e.message));
  p.on('console', m => { if (m.type() === 'error' && !m.text().includes('404')) errs.push('CONSOLE: ' + m.text().slice(0, 200)); });

  await p.goto(BASE + '/login/', { waitUntil: 'networkidle', timeout: 60000 });
  await p.waitForTimeout(1200);

  const info = await p.evaluate(() => {
    const btn = document.querySelector('.lp-submit');
    if (!btn) return { found: false };
    const r = btn.getBoundingClientRect();
    const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    const topEl = document.elementFromPoint(cx, cy);
    const cs = getComputedStyle(btn);
    // look for fixed/absolute elements with large size and high z-index
    const overlays = Array.from(document.querySelectorAll('body *'))
      .filter(el => {
        const s = getComputedStyle(el);
        if (!/fixed|absolute/.test(s.position)) return false;
        const rr = el.getBoundingClientRect();
        return rr.width > window.innerWidth * 0.6 && rr.height > window.innerHeight * 0.4;
      })
      .map(el => ({ tag: el.tagName, cls: el.className, z: getComputedStyle(el).zIndex, pos: getComputedStyle(el).position }));
    return {
      found: true,
      rect: { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) },
      visible: cs.visibility, display: cs.display, opacity: cs.opacity,
      topElTag: topEl ? topEl.tagName : null,
      topElCls: topEl ? (typeof topEl.className === 'string' ? topEl.className : topEl.className.baseVal) : null,
      topIsButtonOrChild: !!(topEl && (topEl === btn || btn.contains(topEl) || topEl.contains(btn))),
      overlays,
    };
  });

  console.log('SUBMIT DIAG:', JSON.stringify(info, null, 2));
  console.log('ERRORS:', errs.length ? errs.join(' | ') : 'none');
  await b.close();
})();
