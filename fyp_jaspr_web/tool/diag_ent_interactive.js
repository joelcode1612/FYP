// Confirm the entrepreneur form is interactive: force-click submit on empty
// form and verify validation errors surface (proves hydration + handlers work).
const { chromium } = require('playwright-core');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = 'http://127.0.0.1:8141';

(async () => {
  const b = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const p = await b.newPage({ viewport: { width: 1440, height: 980 } });
  await p.goto(BASE + '/login/', { waitUntil: 'networkidle', timeout: 60000 });
  await p.waitForTimeout(1500);
  await p.click('.lp-submit', { force: true });
  await p.waitForTimeout(400);
  const shown = await p.locator('.lp-err:not(.is-hidden)').allInnerTexts().catch(() => []);
  const alert = (await p.locator('.lp-alert').innerText().catch(() => 'MISSING')).slice(0, 80);
  // toggle password eye
  await p.click('.lp-eye', { force: true });
  await p.waitForTimeout(200);
  const pwType = await p.locator('#lp-password').getAttribute('type');
  console.log('empty-submit validation errors:', JSON.stringify(shown));
  console.log('alert text:', alert);
  console.log('password type after eye toggle:', pwType);
  const ok = shown.length > 0 && /password/i.test(pwType || '');
  console.log(ok ? 'RESULT: ENTREPRENEUR INTERACTIVE (PASS)' : 'RESULT: FAIL');
  await b.close();
  process.exit(ok ? 0 : 1);
})().catch(e => { console.error('DIAG ERROR', e.message); process.exit(2); });
