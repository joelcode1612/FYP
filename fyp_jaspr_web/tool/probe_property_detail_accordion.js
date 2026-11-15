/* Headless verification of the Property Detail listing-details accordion.
 * Runs through the session_harness stand-in bridge and fixture catalogue
 * (the role routes are guarded; the fixture's rows carry the base fields, so
 * the expanded grid is expected to be modest — the check is that the rows the
 * record actually has render, not a fixed count).
 * Checks: position (directly above "Your business & this property"), collapsed
 * default, aria-expanded/aria-controls semantics, chevron rotation, keyboard
 * activation, expand/collapse cycling, mobile layout, and absence of fatal
 * console errors. */
const path = require('path');
const { chromium } = require('playwright-core');
const { installHarnessSession } = require('./session_harness');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1243/chrome-win64/chrome.exe';
const BASE = 'http://127.0.0.1:8090';
const URL = BASE + '/entrepreneur/property-detail?id=EP-01051';

const checks = [];
function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
}

(async () => {
  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-proxy-server', '--no-sandbox'],
  });
  const page = await browser.newPage({ viewport: { width: 1440, height: 950 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push('console: ' + m.text().slice(0, 200));
  });
  // The insights endpoint is not served by the harness; the page renders that
  // as its own contained failure state. The accordion needs only the record.
  await installHarnessSession(page, { role: 'entrepreneur' });

  // The harness serves the catalogue detail wrapped as {ok, data} (the shape
  // the assessment workspace's _call unwraps). The Property Detail page reads
  // the same endpoint through ApiPropertyRepository.getPropertyById, which
  // parses the payload directly — matching the real backend, which returns
  // the bare row (catalog.py get_catalog_property spreads **prop at the top
  // level). Registered after the harness routes, so this one wins.
  const fixtureRows = JSON.parse(require('fs').readFileSync(
    require('path').join(__dirname, '..', '..', 'test', '.data', 'jaspr_catalog_fixture.json'),
    'utf8',
  )).rows;
  const propertyRow = fixtureRows.find((r) => r.id === 'EP-01051');
  if (!propertyRow) throw new Error('EP-01051 missing from the catalog fixture');
  await page.route('**/api/v1/catalog/properties/EP-01051', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(propertyRow),
    }),
  );

  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 45000 });
  await page.waitForSelector('.sw-pd__details', { timeout: 20000 });
  await page.waitForTimeout(1500);

  const section = page.locator('.sw-pd__details');
  const toggle = page.locator('.sw-pd__details-toggle');
  const body = page.locator('#sw-pd-details-body');
  const chevron = page.locator('.sw-pd__details-chevron');

  check('exactly one details accordion', (await section.count()) === 1, await section.count());
  check('toggle exists', (await toggle.count()) === 1);

  // --- collapsed by default ------------------------------------------------
  const expanded0 = await toggle.getAttribute('aria-expanded');
  check('collapsed by default (aria-expanded=false)', expanded0 === 'false', expanded0);
  const label0 = (await toggle.textContent()).trim();
  check('collapsed label', label0.includes('Show listing details'), label0);
  const bodyH0 = (await body.boundingBox())?.height ?? -1;
  check('body clamped when collapsed', bodyH0 >= -0.5 && bodyH0 < 2, bodyH0);
  const chevTransform0 = await chevron.evaluate((el) => getComputedStyle(el).transform);
  check('chevron unrotated when collapsed', chevTransform0 === 'none' || chevTransform0 === 'matrix(1, 0, 0, 1, 0, 0)', chevTransform0);

  // --- position: directly above the business match section -----------------
  const order = await page.evaluate(() => {
    const details = document.querySelector('.sw-pd__details');
    const match = document.querySelector('.sw-match');
    const hero = document.querySelector('.sw-pd__hero');
    const tabs = document.querySelector('.sw-info');
    if (!details || !match || !hero) return 'missing';
    const after = (a, b) => !!(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);
    return JSON.stringify({
      heroThenDetails: after(hero, details),
      detailsThenMatch: after(details, match),
      matchThenTabs: tabs ? after(match, tabs) : null,
    });
  });
  const orderObj = JSON.parse(order);
  check('hero precedes details', orderObj.heroThenDetails === true, order);
  check('details precedes business match', orderObj.detailsThenMatch === true, order);
  check('business match precedes tabs', orderObj.matchThenTabs === true, order);

  // --- full-width bar -------------------------------------------------------
  const secBox = (await section.boundingBox()) ?? { width: 0, x: 0 };
  const heroBox = (await page.locator('.sw-pd__hero').boundingBox()) ?? { width: 0, x: 0 };
  check(
    'accordion spans page content width',
    Math.abs(secBox.width - heroBox.width) <= 2 && Math.abs(secBox.x - heroBox.x) <= 2,
    `sec=${secBox.width}x@${secBox.x} hero=${heroBox.width}x@${heroBox.x}`,
  );
  const radius = await section.evaluate((el) => getComputedStyle(el).borderRadius);
  check('rounded corners ~18-20px', parseFloat(radius) >= 17 && parseFloat(radius) <= 21, radius);
  const color = await toggle.evaluate((el) => getComputedStyle(el).color);
  check('blue label colour', color === 'rgb(29, 78, 216)', color);

  // --- expand by click -------------------------------------------------------
  await toggle.click();
  await page.waitForTimeout(500);
  const expanded1 = await toggle.getAttribute('aria-expanded');
  check('click expands (aria-expanded=true)', expanded1 === 'true', expanded1);
  const label1 = (await toggle.textContent()).trim();
  check('expanded label', label1.includes('Hide listing details'), label1);
  const bodyH1 = (await body.boundingBox())?.height ?? 0;
  // Fixture rows carry only the base fields, so the expanded grid is short
  // (often a single row) — the check is "open means visible", vs <2px closed.
  check('body visibly expanded', bodyH1 > 20, bodyH1);
  const rows = await page.locator('.sw-pd__detail-row').count();
  check('detail rows rendered from the record', rows >= 1, rows);
  const chevTransform1 = await chevron.evaluate((el) => getComputedStyle(el).transform);
  check('chevron rotated when expanded', chevTransform1 !== 'none' && chevTransform1 !== 'matrix(1, 0, 0, 1, 0, 0)', chevTransform1);
  const bodyHidden1 = await body.getAttribute('aria-hidden');
  check('body aria-hidden=false when open', bodyHidden1 === 'false', bodyHidden1);

  // --- collapse again --------------------------------------------------------
  await toggle.click();
  await page.waitForTimeout(500);
  check('click collapses again', (await toggle.getAttribute('aria-expanded')) === 'false');
  const bodyH2 = (await body.boundingBox())?.height ?? -1;
  check('body clamped after collapse', bodyH2 < 2, bodyH2);

  // --- keyboard activation ---------------------------------------------------
  await toggle.focus();
  await page.keyboard.press('Enter');
  await page.waitForTimeout(450);
  check('Enter expands', (await toggle.getAttribute('aria-expanded')) === 'true');
  await page.keyboard.press('Space');
  await page.waitForTimeout(450);
  check('Space collapses', (await toggle.getAttribute('aria-expanded')) === 'false');
  const focusOk = await page.evaluate(() => {
    const el = document.activeElement;
    return el && el.classList.contains('sw-pd__details-toggle');
  });
  check('focus stays on the toggle', focusOk === true);
  const ariaControls = await toggle.getAttribute('aria-controls');
  check('aria-controls resolves', ariaControls === 'sw-pd-details-body' && (await body.count()) === 1, ariaControls);

  // --- business match untouched ---------------------------------------------
  check('business match section intact', (await page.locator('.sw-match').count()) === 1);
  check('tabs intact', (await page.locator('.sw-info').count()) >= 1);

  // --- mobile viewport --------------------------------------------------------
  await page.setViewportSize({ width: 390, height: 844 });
  await page.waitForTimeout(400);
  const mobBox = (await section.boundingBox()) ?? { width: 0 };
  const mobToggle = (await toggle.boundingBox()) ?? { height: 0 };
  check('mobile: bar visible and full width', mobBox.width > 300, mobBox.width);
  check('mobile: header tap target comfortable', mobToggle.height >= 30, mobToggle.height);
  await toggle.click();
  await page.waitForTimeout(500);
  check('mobile: expands on tap', (await toggle.getAttribute('aria-expanded')) === 'true');
  const gridCols = await page
    .locator('.sw-pd__detail-grid')
    .evaluate((el) => getComputedStyle(el).gridTemplateColumns.split(' ').length);
  check('mobile: detail grid single column', gridCols === 1, gridCols);

  check(
    'no fatal console errors',
    errors.filter((e) => !e.includes('favicon') && !e.includes('net::') && !e.includes('404') && !e.includes('Failed to load resource')).length === 0,
    errors.slice(0, 3).join(' | '),
  );

  const failed = checks.filter((c) => !c.ok);
  console.log(JSON.stringify({ passed: checks.length - failed.length, total: checks.length, failed }, null, 2));
  await browser.close();
  process.exit(failed.length ? 1 : 0);
})().catch((e) => {
  console.error('PROBE_FAILED', e);
  process.exit(1);
});
