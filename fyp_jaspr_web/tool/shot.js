// Screenshot one or more URLs with playwright-core + the installed Chromium.
// Usage: node shot.js <outdir> <width> <url> [name] [<url> [name]] ...
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

(async () => {
  const [, , outdir, widthArg, ...rest] = process.argv;
  const width = Number(widthArg || 1440);
  fs.mkdirSync(outdir, { recursive: true });

  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const ctx = await browser.newContext({
    viewport: { width, height: 1000 },
    deviceScaleFactor: 1,
    bypassCSP: true,
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push('console: ' + m.text());
  });

  // The source design is auth-gated: every workspace page redirects to
  // login.html without a session in localStorage. Seed one so the pages under
  // comparison actually render. Key/shape come from data-source.js `_key` +
  // `_session`; ROLE=admin selects the seeded administrator.
  //
  // The Jaspr app is gated the other way — by `window.sitewiseAuth` and the
  // authenticated API — so it needs session_harness.js instead of a key. Set
  // HARNESS=1 and ROLE=entrepreneur|owner|admin|agent for those pages.
  const harness = process.env.HARNESS === '1';
  const role = process.env.ROLE || 'user';
  if (harness) {
    await installHarnessSession(page, { role: role === 'user' ? 'auto' : role });
  } else {
    const session =
      role === 'none'
        ? null
        : role === 'admin'
        ? { userId: 'u-admin', email: 'admin@sitewise.test', name: 'Sitewise Administrator', role: 'admin', at: new Date().toISOString() }
        : { userId: 'u-1001', email: 'owner@sitewise.test', name: 'Amir Rahman', role: 'user', at: new Date().toISOString() };
    if (session) {
      await ctx.addInitScript((s) => {
        try {
          localStorage.setItem('sitewise:v1:uanon:session', JSON.stringify(s));
        } catch (e) {}
      }, session);
    }
  }

  for (let i = 0; i < rest.length; i += 2) {
    const url = rest[i];
    const name = rest[i + 1] || ('page' + i);
    try {
      await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });
      // The app hydrates and then loads data through a cubit, so the first paint
      // is a skeleton. Wait for real content before capturing, otherwise the
      // screenshot is of the loading state.
      await page
        .waitForFunction(
          () => !document.querySelector('.skeleton') && document.body.scrollHeight > 400,
          { timeout: 8000 },
        )
        .catch(() => {});
      await page.waitForTimeout(900);
      const out = path.join(outdir, `${name}-${width}.png`);
      // Freeze CSS animations: the skeleton shimmer never settles, which makes
      // `fullPage` screenshots time out waiting for a stable frame.
      await page.screenshot({ path: out, fullPage: true, animations: 'disabled', caret: 'hide', timeout: 60000 });
      const h = await page.evaluate(() => document.body.scrollHeight);
      console.log(`OK   ${name.padEnd(28)} ${width}px  h=${h}  ${out}`);
    } catch (e) {
      console.log(`FAIL ${name.padEnd(28)} ${e.message.split('\n')[0]}`);
    }
  }
  if (errors.length) {
    console.log('\n--- console errors ---');
    for (const e of [...new Set(errors)].slice(0, 30)) console.log('  ' + e);
  }
  await browser.close();
})();
