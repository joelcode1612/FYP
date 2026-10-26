// Dump the rendered DOM outline (tags + classes + short text) of pages.
// Usage: node dump.js <outdir> <url> [name] ...
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

(async () => {
  const [, , outdir, ...rest] = process.argv;
  fs.mkdirSync(outdir, { recursive: true });
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const role = process.env.ROLE || 'user';
  if (role !== 'none') {
    const session =
      role === 'admin'
        ? { userId: 'u-admin', email: 'admin@sitewise.test', name: 'Sitewise Administrator', role: 'admin', at: new Date().toISOString() }
        : { userId: 'u-1001', email: 'owner@sitewise.test', name: 'Amir Rahman', role: 'user', at: new Date().toISOString() };
    await ctx.addInitScript((s) => {
      try { localStorage.setItem('sitewise:v1:uanon:session', JSON.stringify(s)); } catch (e) {}
    }, session);
  }
  const page = await ctx.newPage();

  for (let i = 0; i < rest.length; i += 2) {
    const url = rest[i];
    const name = rest[i + 1] || 'page' + i;
    try {
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
      await page.waitForTimeout(1500);
      const outline = await page.evaluate(() => {
        const VOID = new Set(['area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr']);
        const out = [];
        function walk(el, depth) {
          if (depth > 14) return;
          const tag = el.tagName.toLowerCase();
          if (tag === 'script' || tag === 'style' || tag === 'svg') return;
          let s = '  '.repeat(depth) + '<' + tag;
          if (el.id) s += '#' + el.id;
          if (el.className && typeof el.className === 'string') {
            s += ' .' + el.className.trim().split(/\s+/).join(' .');
          }
          if (tag === 'img') s += ' src=' + (el.getAttribute('src') || '').slice(0, 60);
          s += '>';
          // own text (direct children only), truncated
          let own = '';
          for (const n of el.childNodes) if (n.nodeType === 3) own += n.textContent;
          own = own.replace(/\s+/g, ' ').trim();
          if (own) s += ' "' + (own.length > 70 ? own.slice(0, 70) + '…' : own) + '"';
          out.push(s);
          if (!VOID.has(tag)) for (const c of el.children) walk(c, depth + 1);
        }
        walk(document.body, 0);
        return out.join('\n');
      });
      const f = path.join(outdir, `${name}.txt`);
      fs.writeFileSync(f, outline, 'utf8');
      console.log(`OK   ${name.padEnd(26)} ${outline.split('\n').length} nodes`);
    } catch (e) {
      console.log(`FAIL ${name.padEnd(26)} ${e.message.split('\n')[0]}`);
    }
  }
  await browser.close();
})();
