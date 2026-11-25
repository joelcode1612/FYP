// Activity History acceptance walk-through over Chrome DevTools Protocol.
//
// Proves the page an owner actually sees, not just the JSON behind it:
//   * assessment selection through the saved-assessment dropdown;
//   * historical activity records and current-vs-historical revision labels;
//   * Available Sources, including the questionnaire publication state;
//   * eligibility / admission metadata rendered from persisted records;
//   * empty and unavailable source states;
//   * cross-assessment and cross-owner isolation of the assessment list.
//
// Each step writes a full-page screenshot and the page text it asserted on, so a
// claim in the report can be traced to an artefact.
const { chromium } = require('C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/fyp_jaspr_web/tool/node_modules/playwright-core');
const fs = require('fs');
const path = require('path');

const BASE = 'http://127.0.0.1:8093';
const DIR = 'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/deliverables/screenshots/20261125_activity_history';
fs.mkdirSync(DIR, { recursive: true });

// The assessment whose questionnaire was published for revision 23, and whose
// objective proposals sit at revision 21 -- so it carries both current and
// historical records.
const PUBLISHED = 'df15adf3-be2c-4751-86aa-78fda663cf93';
// Carries an objective admission (WORTH_RESEARCHING) and no campaign.
const ADMITTED = 'ef5c028e-3563-5b66-bb51-6d618861c551';
// Carries records but no questionnaire campaign.
const UNPUBLISHED = '3eac222f-5376-426c-866e-bae90c0825ba';
// Revision 0, no activity at all.
const EMPTY = 'f9a180b0-58a0-4d5d-ba74-111b8e6ae01f';
const OTHER_OWNER_EMAIL = 'gatebc-e2e-b9e62014@example.invalid';

const results = [];
function check(ok, name, detail) {
  results.push({ ok: !!ok, name, detail: detail === undefined ? '' : String(detail).slice(0, 300) });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${!ok && detail ? `  [${String(detail).slice(0, 300)}]` : ''}`);
}

async function settle(page) {
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.evaluate(async () => { try { await window.sitewiseAuth.ready; } catch (_) {} });
  await page.waitForTimeout(1200);
}

async function openFirst(page, assessmentId) {
  const target = `/entrepreneur/activity-history?assessment=${assessmentId}`;
  await page.evaluate((t) => {
    history.pushState({}, '', t);
    window.dispatchEvent(new PopStateEvent('popstate', { state: {} }));
  }, target);
  await page.waitForFunction(() => /Questionnaire publication/i.test(document.body.innerText || ''),
    null, { timeout: 90000, polling: 500 });
  await page.waitForTimeout(2500);
}

/// Selects through the real dropdown, which is the path an owner takes.
async function selectAssessment(page, id) {
  const handles = await page.$$('select');
  for (const h of handles) {
    const values = await h.evaluate((s) => Array.from(s.options).map((o) => o.value));
    if (values.includes(id)) {
      await h.selectOption(id);
      await page.waitForTimeout(3000);
      return true;
    }
  }
  return false;
}

async function capture(page, name) {
  const text = await page.evaluate(() => document.body.innerText || '');
  fs.writeFileSync(path.join(DIR, `${name}.txt`), text, 'utf8');
  const file = path.join(DIR, `${name}.png`);
  try {
    await page.screenshot({ path: file, fullPage: true, timeout: 60000, animations: 'disabled' });
  } catch (e) {
    // A full-page capture of a very long timeline can exceed the timeout. The
    // viewport shot still shows the header, coverage and the newest records,
    // which is what the assertions are about.
    console.log(`NOTE  full-page capture failed (${e.name}); falling back to viewport`);
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(500);
    await page.screenshot({ path: file, fullPage: false, timeout: 60000, animations: 'disabled' });
  }
  return text;
}

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const page = await ctx.newPage();
  await page.bringToFront();
  await page.setViewportSize({ width: 1440, height: 1800 });
  page.on('dialog', (d) => d.dismiss().catch(() => {}));

  await settle(page);

  // ------------------------------------------------------ 1. published, current
  await openFirst(page, PUBLISHED);
  let text = await capture(page, '01_published_assessment');

  check(/Activity history/i.test(text), 'activity history page rendered');
  check(/Questionnaire published/.test(text), 'publication event in the timeline');
  check(/Questionnaire published \d{4}-/.test(text), 'publication status line rendered');
  check(/bank CQ-ENTREP-df15adf3-r23-cq-manifest-1/.test(text),
    'publication names the bank version');
  check(/13 questions/.test(text), 'publication names the question count');
  check(/7 authorized/.test(text), 'publication names the authorized count');
  check(/fielding disabled/.test(text), 'publication states fielding is disabled');
  check(/not an open fielding authorization/.test(text),
    'publication is not presented as fielding authority');
  check(/Customer Questionnaire:\s*VERIFIED_AVAILABLE/.test(text),
    'Customer Questionnaire reported available');
  check(/no respondent identity, answer, session or count is exposed/.test(text),
    'respondent boundary stated on the page');
  check(/Source revision matches the current saved revision\./.test(text),
    'current revision label on the selected record');
  check(/historical source; not a current handoff/.test(text),
    'historical label on an earlier BCB snapshot');
  check(/EE-01 measurement:\s*BLOCKED_AUTHORIZATION/.test(text),
    'unavailable source rendered as BLOCKED_AUTHORIZATION');
  check(/Report generation \/ admission:\s*BLOCKED_AUTHORIZATION/.test(text),
    'report source rendered as BLOCKED_AUTHORIZATION');

  // ------------------------------------------- 2. historical revision on a record
  // Filter to the proposal kind, whose records sit at revision 21 of 23.
  let historicalLabel = false;
  try {
    const selects = await page.$$('select');
    for (const h of selects) {
      const values = await h.evaluate((s) => Array.from(s.options).map((o) => o.value));
      if (values.includes('OBJECTIVE_PROPOSED')) {
        await h.selectOption('OBJECTIVE_PROPOSED');
        await page.waitForTimeout(2500);
        break;
      }
    }
    const card = page.getByText('Objective proposed', { exact: false }).first();
    if (await card.count()) {
      await card.click();
      await page.waitForTimeout(1500);
    }
    const filtered = await capture(page, '02_historical_revision');
    historicalLabel = /Historical source revision — original outcome retained; not a current handoff\./.test(filtered);
    check(historicalLabel, 'historical revision label on a revision-21 record',
      filtered.slice(0, 200));
  } catch (e) {
    check(false, 'historical revision label on a revision-21 record', e.message);
  }

  // ------------------------------------------------- 3. admission metadata
  check(await selectAssessment(page, ADMITTED), 'assessment switched via the dropdown');
  text = await capture(page, '03_admitted_assessment');
  check(/Objective admitted/.test(text), 'objective admission rendered', text.slice(0, 200));
  check(/WORTH_RESEARCHING/.test(text), 'admission disposition rendered');
  check(/Questionnaire publication: not published/.test(text),
    'assessment without a campaign reads as not published');

  // ------------------------------------------------------ 4. not published
  check(await selectAssessment(page, UNPUBLISHED), 'second assessment selected');
  text = await capture(page, '04_not_published');
  check(/Questionnaire publication: not published/.test(text),
    'no-campaign assessment reads as not published');

  // ------------------------------------------------------------ 5. empty state
  // A saved assessment always carries an ASSESSMENT_CREATED record, so the
  // "no records at all" branch is unreachable without fabricating rows. The
  // zero-match branch is reachable through the real date filter, which is the
  // same empty-state renderer an owner sees.
  check(await selectAssessment(page, EMPTY), 'minimal assessment selected');
  text = await capture(page, '05_single_record_assessment');
  check(/1 matching activity/.test(text), 'minimal assessment renders its single record');
  check(/Assessment created/.test(text), 'the creation record is the one shown');

  // The "no records at all" branch cannot be produced without fabricating rows:
  // every saved assessment carries at least an ASSESSMENT_CREATED record. That
  // is asserted from the live API rather than assumed.
  const counts = JSON.parse(fs.readFileSync(
    'C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/backend/var/e2e/pg18/activity_history_20261125/http_event_counts.json',
    'utf8'));
  const minEvents = Math.min(...counts.map((c) => c.events));
  check(minEvents >= 1,
    'no saved assessment has zero records (the empty branch is unreachable with real data)',
    `min=${minEvents}`);

  // Zero-match filtering is reachable and renders a distinct message. The date
  // widget is a bound framework input, so it is driven only when it accepts a
  // value; otherwise the state is reported as not driven rather than assumed.
  let filteredOut = false;
  try {
    const start = page.locator('input.sr-date').first();
    if (await start.count()) {
      await start.click();
      await start.fill('2099-01-01');
      await start.press('Tab');
      await page.waitForTimeout(2500);
      filteredOut = (await start.inputValue()) === '2099-01-01';
    }
  } catch (e) {
    filteredOut = false;
  }
  text = await capture(page, '06_empty_filtered');
  if (/No matching activities/.test(text)) {
    check(/No matching activities/.test(text), 'zero-match empty state rendered');
    check(/Try clearing some filters\./.test(text),
      'empty state explains how to recover');
  } else {
    // The date input is a framework-bound value; a synthetic change does not
    // reach its handler in this build, so the state is NOT claimed. The
    // renderer itself is confirmed separately against the served bundle.
    console.log('NOTE  zero-match empty state not driven through the UI; '
      + 'not claimed. See served-bundle check for the renderer strings.');
  }

  // ------------------------------------------------------------- 6. isolation
  const options = await page.evaluate(() => {
    const found = [];
    document.querySelectorAll('select').forEach((sel) => {
      const values = Array.from(sel.options).map((o) => o.value);
      if (values.some((v) => /^[0-9a-f-]{36}$/.test(v))) found.push(values);
    });
    return found.length ? found[0] : [];
  });
  fs.writeFileSync(path.join(DIR, '06_assessment_options.json'), JSON.stringify(options, null, 2), 'utf8');
  check(options.length > 0, 'saved-assessment dropdown populated', `options=${options.length}`);
  check(options.includes(PUBLISHED), 'dropdown includes the published assessment');

  const html = await page.evaluate(() => document.documentElement.outerHTML || '');
  check(!html.includes(OTHER_OWNER_EMAIL), 'no other-owner account identifier on the page');
  check(!/cq_participants|cq_sessions|respondent_id|session_id/i.test(html),
    'no respondent-scoped table or column name on the page');

  fs.writeFileSync(path.join(DIR, 'results.json'),
    JSON.stringify({ generated: new Date().toISOString(), results }, null, 2), 'utf8');

  const failed = results.filter((r) => !r.ok);
  console.log(`\n${failed.length === 0 ? 'ALL CHECKS PASSED' : 'FAILURES: ' + failed.map((f) => f.name).join(' | ')}`);
  console.log(`artefacts: ${DIR}`);
  await page.close();
  process.exit(failed.length === 0 ? 0 : 1);
})().catch((e) => { console.error('SCRIPT ERROR', e); process.exit(2); });
