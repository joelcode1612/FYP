// Keyboard + accessible-name probe for the five-screen admin operations suite.
//
// For each route it checks that:
//   * every focusable control has an accessible name
//   * every form input has a programmatic label (label[for] / aria-label)
//   * toggle chips expose aria-pressed
//   * Tab actually walks the controls and each stop has a non-empty name
//
// Usage: node tool/probe_admin_ops_a11y.js [baseUrl]
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');
const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const BASE = process.argv[2] || 'http://127.0.0.1:8090';

const ROUTES = [
  '/admin/ownership',
  '/admin/agents',
  '/admin/campaigns',
  '/admin/activity',
  '/admin/surveys',
];

// Accessible-name rules mirrored from the page's own DOM: aria-label,
// aria-labelledby, <label for>, text content, title, placeholder.
const nameCheck = `(() => {
  const name = (el) => {
    const al = el.getAttribute('aria-label');
    if (al && al.trim()) return true;
    const lb = el.getAttribute('aria-labelledby');
    if (lb && lb.split(/\\s+/).some((id) => (document.getElementById(id) || {}).textContent)) return true;
    if (el.id) {
      const lab = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
      if (lab && lab.textContent.trim()) return true;
    }
    // Implicit association: the control sits inside a <label>.
    if (el.closest('label')) return true;
    if ((el.textContent || '').trim()) return true;
    if (el.getAttribute('title')) return true;
    if (el.getAttribute('placeholder')) return true;
    return false;
  };
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden';
  };
  const focusables = [...document.querySelectorAll(
    'a[href],button,input,select,textarea,[tabindex]:not([tabindex="-1"])'
  )].filter(visible);
  const unnamed = focusables.filter((el) => !name(el)).map((el) => el.outerHTML.slice(0, 90));
  const controls = [...document.querySelectorAll('input,select,textarea')].filter(visible);
  const unlabeled = controls.filter((el) => !name(el)).map((el) => el.outerHTML.slice(0, 90));
  const pressed = document.querySelectorAll('[aria-pressed]').length;
  return { focusables: focusables.length, unnamed, unlabeled: controls.length ? unlabeled : [], pressed };
})()`;

(async () => {
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  let problems = 0;

  for (const route of ROUTES) {
    const page = await ctx.newPage();
    await installHarnessSession(page, { role: 'admin' });
    await page.goto(BASE + route, { waitUntil: 'networkidle', timeout: 30000 });
    await page.waitForTimeout(1000);
    const info = await page.evaluate(nameCheck);

    // Keyboard walk: 40 Tab stops, each must land on something named.
    let stops = 0;
    let firstUnnamedStop = null;
    for (let i = 0; i < 40; i++) {
      await page.keyboard.press('Tab');
      const stop = await page.evaluate(() => {
        const el = document.activeElement;
        if (!el || el === document.body || el === document.documentElement) return null;
        const label = (el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title') || el.getAttribute('placeholder'))) ||
          (el.textContent || '').trim();
        let named = Boolean(label && label.length);
        // Mirror the static check: a control inside <label> takes the
        // label's text as its accessible name.
        if (!named && el.closest) {
          const wrap = el.closest('label');
          if (wrap && (wrap.textContent || '').trim()) named = true;
        }
        const r = el.getBoundingClientRect();
        return {
          tag: el.tagName.toLowerCase(),
          visible: r.width > 0 && r.height > 0,
          named,
        };
      });
      if (!stop) break;
      stops++;
      if (!stop.named && !firstUnnamedStop) firstUnnamedStop = stop.tag;
    }

    const issues = [];
    if (info.unnamed.length) issues.push(`${info.unnamed.length} focusable without name`);
    if (info.unlabeled.length) issues.push(`${info.unlabeled.length} input without label`);
    if (stops < 5) issues.push(`only ${stops} tab stops`);
    if (firstUnnamedStop) issues.push(`unnamed tab stop: ${firstUnnamedStop}`);
    if (issues.length) problems++;
    console.log(
      `${issues.length ? 'FAIL' : 'ok  '} ${route.padEnd(20)} focusable=${String(info.focusables).padEnd(3)} ` +
      `aria-pressed=${String(info.pressed).padEnd(3)} tabStops=${String(stops).padEnd(3)} ${issues.join(' | ')}`
    );
    await page.close();
  }

  // Dialog sub-check: the invite dialog's screening checkbox only exists once
  // the dialog is open, so probe it explicitly.
  {
    const page = await ctx.newPage();
    await installHarnessSession(page, { role: 'admin' });
    await page.goto(BASE + '/admin/agents', { waitUntil: 'networkidle', timeout: 30000 });
    await page.waitForTimeout(1000);
    await page.getByRole('button', { name: /invite agent/i }).first().click();
    await page.waitForSelector('[role="dialog"]', { timeout: 5000 });
    const dialogInfo = await page.evaluate(`(() => {
      const dlg = document.querySelector('[role="dialog"]');
      const namedAttr = Boolean(dlg.getAttribute('aria-label') || dlg.getAttribute('aria-labelledby'));
      const controls = [...dlg.querySelectorAll('input,select,textarea')];
      const unlabeled = controls.filter((el) => {
        if (el.closest('label')) {
          const t = el.closest('label').textContent.trim();
          if (t) return false;
        }
        if (el.getAttribute('aria-label')) return false;
        if (el.id && document.querySelector('label[for="' + CSS.escape(el.id) + '"]')) return false;
        if (el.getAttribute('placeholder') || el.getAttribute('title')) return false;
        return true;
      }).map((el) => el.outerHTML.slice(0, 80));
      return { namedAttr, controls: controls.length, unlabeled, modal: dlg.getAttribute('aria-modal') };
    })()`);
    const dialogIssues = [];
    if (!dialogInfo.namedAttr) dialogIssues.push('dialog without accessible name');
    if (dialogInfo.modal !== 'true') dialogIssues.push('aria-modal missing');
    if (dialogInfo.unlabeled.length) dialogIssues.push(`${dialogInfo.unlabeled.length} dialog input without label`);
    if (dialogIssues.length) problems++;
    console.log(
      `${dialogIssues.length ? 'FAIL' : 'ok  '} /admin/agents (invite dialog) controls=${dialogInfo.controls} ${dialogIssues.join(' | ')}`
    );
    // Escape must close it once the opener has moved focus into the dialog.
    await page.waitForTimeout(150);
    await page.keyboard.press('Escape');
    await page.waitForTimeout(300);
    const stillOpen = await page.evaluate(() => Boolean(document.querySelector('[role="dialog"]')));
    if (stillOpen) {
      problems++;
      console.log('FAIL invite dialog did not close on Escape');
    } else {
      console.log('ok   invite dialog closes on Escape');
    }
    await page.close();
  }

  await browser.close();
  console.log(problems ? `\n${problems} route(s) with a11y problems` : '\nAll routes pass keyboard/name checks');
  process.exit(problems ? 1 : 0);
})().catch((e) => {
  console.error(e.message);
  process.exit(2);
});