// FC4-D report integration — capture the EXISTING assessment report with the
// real EE-01 measurement readback mounted in its R03 section.
//
// This drives the development harness at /dev/report, which mounts the same
// `AssessmentReportView` the Step-5 workspace mounts. It is not a second report
// page: every class and every card on screen belongs to the report.
//
// Usage: node tool/shot_fc4d_report.js <url-base> <outdir>
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const EXE = 'C:/Users/HP/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

(async () => {
  const [, , baseArg, outArg] = process.argv;
  const base = baseArg || 'http://127.0.0.1:8093';
  const outdir = outArg || 'build/fc4d_shots';
  fs.mkdirSync(outdir, { recursive: true });

  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-proxy-server', '--disable-gpu', '--hide-scrollbars'],
  });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });

  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(m.text());
  });

  const url = `${base}/dev/report`;
  await page.goto(url, { waitUntil: 'networkidle', timeout: 60000 });

  // The report's own section index is the reliable "document is mounted" marker.
  await page.waitForSelector('text=Customer questionnaire', { timeout: 30000 });
  await page.waitForTimeout(1200);

  // --- assertions on the rendered document --------------------------------
  const bodyText = await page.evaluate(() => document.body.innerText);

  // The percentage rule applies to the MEASUREMENT card only. The Q01 card in
  // the same section is a SYNTHETIC_PREVIEW_ONLY demonstration and legitimately
  // shows shares; conflating the two is exactly the confusion this change is
  // meant to prevent.
  const card = page.locator('.asw-rpt__card')
    .filter({ hasText: 'measurement readback' }).first();
  const cardText = (await card.count()) ? await card.innerText() : '';
  const cardTable = await page.evaluate(() => {
    const cards = [...document.querySelectorAll('.asw-rpt__card')];
    const found = cards.find((c) => /measurement readback/i.test(c.innerText));
    const table = found && found.querySelector('table');
    if (!table) return null;
    return {
      heads: [...table.querySelectorAll('thead th')].map((t) => t.innerText),
      counts: [...table.querySelectorAll('tbody tr')]
        .map((tr) => tr.children[2].innerText),
      shares: [...table.querySelectorAll('tbody tr')]
        .map((tr) => tr.children[3].innerText),
    };
  });

  const checks = [
    ['report mounted', bodyText.includes('Assessment overview')],
    ['section 05 present', bodyText.includes('Customer questionnaire')],
    ['R03 held notice intact', bodyText.includes('R03 · Concept intent distribution — held')],
    ['measurement card present', /measurement readback/i.test(bodyText)],
    ['withheld state stated', cardText.includes('Findings withheld')],
    ['real funnel printed', /28 qualified .* 28 shown .* 28 answered .* 24 substantive/.test(cardText)],
    ['gate named', cardText.includes('A10_ADAPTER_UNVERIFIED')],
    ['Q01 demo preserved', bodyText.includes('Q01 · Area connection')],
    ['measurement card shows no share', !cardText.includes('%')],
    ['count column withheld', !!cardTable && cardTable.counts.every((v) => v === 'withheld')],
    ['status column withheld', !!cardTable && cardTable.shares.every((v) => v === 'withheld')],
  ];

  await page.screenshot({ path: path.join(outdir, 'fc4d_report_full.png'), fullPage: true });

  // A focused capture of the questionnaire section, where both charts live.
  const section = page.locator('#asw-rpt-questionnaire');
  if (await section.count()) {
    await section.scrollIntoViewIfNeeded();
    await page.waitForTimeout(400);
    await section.screenshot({ path: path.join(outdir, 'fc4d_report_r03_section.png') });
  } else {
    await page.screenshot({ path: path.join(outdir, 'fc4d_report_r03_section.png') });
  }

  // The measurement card on its own, so its text is legible.
  if (await card.count()) {
    await card.scrollIntoViewIfNeeded();
    await page.waitForTimeout(300);
    await card.screenshot({ path: path.join(outdir, 'fc4d_report_measurement_card.png') });
  }

  console.log(JSON.stringify({
    url,
    outdir,
    checks: checks.map(([name, ok]) => ({ name, ok })),
    passed: checks.filter(([, ok]) => ok).length,
    total: checks.length,
    pageErrors: errors.slice(0, 5),
    title: await page.title(),
  }, null, 2));

  await browser.close();
  process.exit(checks.every(([, ok]) => ok) ? 0 : 1);
})();
