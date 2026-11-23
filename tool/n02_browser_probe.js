// N02 browser probe: open the normal application and report what the login
// page actually renders, so the verification script can drive the real form.
const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: true, channel: 'chrome' });
  const page = await browser.newPage();
  const net = [];
  page.on('response', r => {
    const u = r.url();
    if (u.includes('/api/') || u.includes('54329')) net.push(`${r.status()} ${u}`);
  });
  await page.goto('http://127.0.0.1:8092/login', { waitUntil: 'networkidle', timeout: 45000 });
  await page.waitForTimeout(1500);

  console.log('TITLE  :', await page.title());
  console.log('URL    :', page.url());

  const inputs = await page.$$eval('input', els => els.map(e => ({
    type: e.type, name: e.name, id: e.id, placeholder: e.placeholder,
    aria: e.getAttribute('aria-label'), autocomplete: e.autocomplete,
  })));
  console.log('INPUTS :', JSON.stringify(inputs, null, 1));

  const buttons = await page.$$eval('button', els => els.map(e => ({
    type: e.type, text: (e.textContent || '').trim().slice(0, 40),
    id: e.id,
  })));
  console.log('BUTTONS:', JSON.stringify(buttons, null, 1));

  console.log('NET    :', JSON.stringify(net.slice(0, 12), null, 1));
  await page.screenshot({ path: 'backend/var/e2e/shots/n02_login_probe.png', fullPage: true });
  await browser.close();
})().catch(e => { console.error('PROBE ERROR:', e.message); process.exit(1); });
