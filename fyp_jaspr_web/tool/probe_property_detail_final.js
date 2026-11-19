/* Headless verification of the reworked Property Detail page.
 * Checks: hero business-match section, three tabs, DOSM panel (nearby tab),
 * and absence of fatal console errors. */
const path = require('path');
const { chromium } = require('playwright-core');

const EXE = 'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1243/chrome-win64/chrome.exe';
const BASE = 'http://127.0.0.1:8090';
const URL = BASE + '/entrepreneur/property-detail?id=MD-01755';

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

  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 45000 });
  await page.waitForTimeout(2500);

  const results = {};
  results.title = (await page.textContent('h1.sw-pd__title').catch(() => null)) || '';
  results.matchHero = await page.locator('.sw-match').count();
  results.matchTitle = (await page.locator('.sw-match__title').textContent().catch(() => 'MISSING')).trim();
  results.matchContext = (await page.locator('.sw-match__context').textContent().catch(() => '')).trim();
  results.tabs = await page.locator('.sw-info__tab').count();
  results.activeTab = (await page.locator('.sw-info__tab.is-active .sw-info__tab-title').textContent().catch(() => '')).trim();
  results.businessReasonCards = await page.locator('.sw-matchdetail__card').count();
  results.oldIdeasPanel = await page.locator('.sw-biz').count(); // removed panel class
  results.matchHeroText = (await page.locator('.sw-match__business-text h3').textContent().catch(() => '')).trim();

  // Switch to the nearby tab and verify the DOSM block.
  await page.locator('#sw-info-tab-nearby').click();
  await page.waitForTimeout(1200);
  results.nearbyAge = await page.locator('.sw-age').count();
  results.ageTitle = (await page.locator('#sw-age-title').textContent().catch(() => '')).trim();
  results.ageScope = (await page.locator('.sw-age__scope').textContent().catch(() => '')).trim();
  results.ageBars = await page.locator('.sw-age__bar').count();
  results.ageEmpty = await page.locator('.sw-age__empty').count();
  results.ageDistrictTotal = (await page.locator('.sw-age__stat--district strong').textContent().catch(() => '')).trim();

  // Score tab still intact.
  await page.locator('#sw-info-tab-score').click();
  await page.waitForTimeout(1200);
  results.fitSection = await page.locator('.sw-fit').count();
  results.shapSection = await page.locator('.sw-explain').count();
  results.catFitRemoved = await page.locator('.sw-catfit').count();

  results.jsErrors = errors.filter(
    (e) => !e.includes('favicon') && !e.includes('net::') && !e.includes('404'),
  );
  console.log(JSON.stringify(results, null, 2));
  await browser.close();
})().catch((e) => {
  console.error('PROBE_FAILED', e);
  process.exit(1);
});
