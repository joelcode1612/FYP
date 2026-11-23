// RT-E2E-01 Gate E — real-browser evidence for the report integration.
//
// Three captures, one browser, no mocks:
//
//   E-01  /dev/report  — the development harness mounts the SAME
//         `AssessmentReportView` the workspace Step-5 mounts. Proves the report
//         renders its nine sections, that the EE-01 measurement card is bound to
//         the assessment the readback names, that the Q01 demonstration is a
//         separate dataset in the same section, and that the business section
//         states a held state rather than inventing a description.
//   E-02  /entrepreneur/assessments — the intended workspace entry point,
//         navigated in the browser. Records what actually renders and whether a
//         measurement card can appear there at all.
//   E-03  (run against a production-labelled build) /dev/report — the harness
//         must not exist when the compile-time gate is off.
//
// Usage: node tool/rt_e2e_01_browser.js <url-base> <outdir> [--mode=dev|prod]
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const EXE = 'C:/Users/HP/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';

(async () => {
  const args = process.argv.slice(2);
  const base = args[0] || 'http://127.0.0.1:8090';
  const outdir = args[1] || 'build/rt_e2e_01_shots';
  const mode = (args.find((a) => a.startsWith('--mode=')) || '--mode=dev').split('=')[1];
  fs.mkdirSync(outdir, { recursive: true });

  const browser = await chromium.launch({
    executablePath: EXE,
    args: ['--no-proxy-server', '--disable-gpu', '--hide-scrollbars'],
  });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });

  const errors = [];
  const api = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(m.text());
  });
  page.on('response', (r) => {
    if (r.url().includes('/api/v1/')) api.push([r.status(), new URL(r.url()).pathname]);
  });

  const out = { base, mode, captures: [], pageErrors: errors, apiCalls: api };

  // ---------------------------------------------------------------- E-01/E-03
  const harnessUrl = `${base}/dev/report`;
  await page.goto(harnessUrl, { waitUntil: 'networkidle', timeout: 60000 });
  await page.waitForTimeout(1500);
  const harnessText = await page.evaluate(() => document.body.innerText);

  if (mode === 'prod') {
    // The compile-time gate is off: the route was never registered, so the SPA
    // must resolve the path to its own not-found document instead of the report.
    const registered = harnessText.includes('Assessment overview');
    const notFound = /not found|404|does not exist|could not be found/i.test(harnessText);
    await page.screenshot({ path: path.join(outdir, 'E03_prod_dev_report.png'), fullPage: true });
    out.captures.push({
      id: 'E-03',
      url: harnessUrl,
      checks: [
        ['harness route is not registered in a production-labelled build', !registered],
        ['the SPA resolves it to a not-found document', notFound],
      ].map(([name, ok]) => ({ name, ok })),
      bodyHead: harnessText.slice(0, 400),
    });
  } else {
    await page.waitForSelector('text=Customer questionnaire', { timeout: 30000 });
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
        counts: [...table.querySelectorAll('tbody tr')].map((tr) => tr.children[2].innerText),
        shares: [...table.querySelectorAll('tbody tr')].map((tr) => tr.children[3].innerText),
      };
    });

    const cardsWithMeasurement = await page.evaluate(() =>
      [...document.querySelectorAll('.asw-rpt__card')]
        .filter((c) => /measurement readback/i.test(c.innerText)).length);
    const q01OwnCard = await page.evaluate(() =>
      [...document.querySelectorAll('.asw-rpt__card')]
        .some((c) => /Q01 · Area connection/.test(c.innerText)));

    const sectionIds = await page.evaluate(() =>
      [...document.querySelectorAll('[id^="asw-rpt-"]')].map((e) => e.id));

    await page.screenshot({ path: path.join(outdir, 'E01_report_full.png'), fullPage: true });
    const q = page.locator('#asw-rpt-questionnaire');
    if (await q.count()) {
      await q.scrollIntoViewIfNeeded();
      await page.waitForTimeout(400);
      await q.screenshot({ path: path.join(outdir, 'E01_report_questionnaire.png') });
    }
    if (await card.count()) {
      await card.scrollIntoViewIfNeeded();
      await page.waitForTimeout(300);
      await card.screenshot({ path: path.join(outdir, 'E01_measurement_card.png') });
    }
    const biz = page.locator('#asw-rpt-business');
    if (await biz.count()) {
      await biz.scrollIntoViewIfNeeded();
      await page.waitForTimeout(300);
      await biz.screenshot({ path: path.join(outdir, 'E01_business_section.png') });
    }

    const checks = [
      ['report document is mounted', harnessText.includes('Assessment overview')],
      ['questionnaire section is present', harnessText.includes('Customer questionnaire')],
      ['nine sections are rendered', sectionIds.length >= 9],
      ['measurement card is bound and drawn', /measurement readback/i.test(cardText)],
      ['withheld state is stated on the card', cardText.includes('Findings withheld')],
      ['the gate that withholds it is named', cardText.includes('A10_ADAPTER_UNVERIFIED')],
      ['the real funnel is printed', /V = 24/.test(cardText)],
      ['the measurement card shows no percentage', !cardText.includes('%')],
      ['count column is withheld', !!cardTable && cardTable.counts.every((v) => v === 'withheld')],
      ['status column is withheld', !!cardTable && cardTable.shares.every((v) => v === 'withheld')],
      ['the Q01 demonstration is preserved as its own dataset',
        harnessText.includes('Q01 · Area connection')],
      ['exactly one card is the measurement readback', cardsWithMeasurement === 1],
      ['the Q01 demonstration is its own card', q01OwnCard],
      // The harness supplies no BCB readback, so the section must fall back to
      // the Step-2 declaration and LABEL it as such rather than claiming a
      // confirmed declaration it does not have.
      ['the business section labels its source instead of claiming a confirmation',
        harnessText.includes('Declared business') &&
        harnessText.includes('From Step 2') &&
        !harnessText.includes('Confirmed business description')],
      ['no page errors', errors.length === 0],
    ];

    out.captures.push({
      id: 'E-01',
      url: harnessUrl,
      title: await page.title(),
      sectionIds,
      cardTable,
      checks: checks.map(([name, ok]) => ({ name, ok })),
    });
  }

  // -------------------------------------------------------------------- E-02
  const workspaceUrl = `${base}/entrepreneur/assessments`;
  api.length = 0;
  await page.goto(workspaceUrl, { waitUntil: 'networkidle', timeout: 60000 });
  await page.waitForTimeout(2000);
  const wsText = await page.evaluate(() => document.body.innerText);
  await page.screenshot({ path: path.join(outdir, 'E02_workspace_entry.png'), fullPage: true });

  const wsChecks = [
    ['the workspace entry point renders', wsText.length > 200],
    ['it is the assessment workspace, not the harness',
      !wsText.includes('Development harness')],
    ['no measurement readback is drawn for a workspace assessment',
      !/measurement readback/i.test(wsText)],
    ['the page does not claim a report it could not load',
      !/V = 24/.test(wsText)],
  ];
  out.captures.push({
    id: 'E-02',
    url: workspaceUrl,
    title: await page.title(),
    apiCalls: api.slice(0, 12),
    checks: wsChecks.map(([name, ok]) => ({ name, ok })),
    bodyHead: wsText.slice(0, 600),
  });

  console.log(JSON.stringify(out, null, 2));
  await browser.close();
  const failed = out.captures.flatMap((c) => c.checks).filter((c) => !c.ok);
  process.exit(failed.length === 0 ? 0 : 1);
})();
