// Stage 4 Section A — normal-application browser verification.
//
// Connects to the owner's already-authenticated Chrome over CDP (no new
// profile, no credential handling), reloads the workspace so the freshly
// deployed bundle is used, opens Stage 4, and reads what actually rendered.
//
// Read-only: it clicks navigation and reads text. It never presses Approve,
// Reject, Request revision, or any save control.
//
// Writes backend/var/e2e/stage4_sectionA_browser.json + screenshots.
const fs = require('fs');
const path = require('path');
const { chromium } = require(path.join(
  process.cwd(), 'fyp_jaspr_web', 'tool', 'node_modules', 'playwright-core'));

const CDP = 'http://127.0.0.1:9222';
const ORIGIN = 'http://127.0.0.1:8093';
const SHOTS = 'backend/var/e2e/shots';
const OUT = 'backend/var/e2e/stage4_sectionA_browser.json';

const results = [];
function check(id, ok, detail) {
  results.push({ id, status: ok ? 'PASS' : 'FAIL', detail: detail || '' });
  console.log(`[${ok ? 'PASS' : 'FAIL'}] ${id}${detail ? ' — ' + detail : ''}`);
}

(async () => {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await chromium.connectOverCDP(CDP);
  const ctx = browser.contexts()[0];
  let page = ctx.pages().find((p) => p.url().includes('/entrepreneur/assessments'));
  if (!page) {
    page = await ctx.newPage();
    await page.goto(`${ORIGIN}/entrepreneur/assessments`);
  }

  const consoleErrors = [];
  page.on('console', (m) => {
    if (m.type() === 'error') consoleErrors.push(m.text().slice(0, 200));
  });

  // Reload so the bundle deployed in this session is the one under test.
  await page.goto(`${ORIGIN}/entrepreneur/assessments`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(2500);
  check('workspace loaded', page.url().includes('/entrepreneur/assessments'), page.url());

  const bodyText = await page.evaluate(() => document.body.innerText || '');
  check('workspace is authenticated (no sign-in wall)',
    !/sign in to continue/i.test(bodyText),
    bodyText.slice(0, 120).replace(/\s+/g, ' '));

  // ---------------------------------------------------------- open Stage 4
  const stageLabel = 'AI recommendation explanation';
  const stageControl = page.getByText(stageLabel, { exact: false }).first();
  const stageCount = await page.getByText(stageLabel, { exact: false }).count();
  check('Stage 4 control is present', stageCount > 0, `matches=${stageCount}`);

  if (stageCount > 0) {
    await stageControl.click({ timeout: 10000 }).catch(() => {});
    await page.waitForTimeout(4000);
  }

  const afterClick = await page.evaluate(() => document.body.innerText || '');
  const hasSectionA = /Fixed core questionnaire/i.test(afterClick);
  check('Section A heading rendered', hasSectionA,
    afterClick.slice(0, 160).replace(/\s+/g, ' '));

  // ------------------------------------------------- extract Section A DOM
  const sectionA = await page.evaluate(() => {
    const heads = Array.from(document.querySelectorAll('h3'));
    const head = heads.find((h) => /Fixed core questionnaire/i.test(h.textContent || ''));
    if (!head) return null;
    const card = head.closest('section') || head.closest('div');
    if (!card) return null;

    const qids = Array.from(card.querySelectorAll('.p1-qid'))
      .map((n) => (n.textContent || '').trim())
      .filter(Boolean);
    const titles = Array.from(card.querySelectorAll('.p1-qtitle'))
      .map((n) => (n.textContent || '').trim());
    const buttons = Array.from(card.querySelectorAll('button'))
      .map((n) => (n.textContent || '').trim())
      .filter(Boolean);
    const chips = Array.from(card.querySelectorAll('.p1-chip'))
      .map((n) => (n.textContent || '').trim());

    return {
      text: (card.innerText || '').slice(0, 6000),
      qids,
      titles,
      buttons,
      chips,
      hasApprove: /^approve$/i.test(buttons.join('|')),
      hasReject: buttons.some((b) => /^reject$/i.test(b)),
    };
  });

  check('Section A card found in DOM', sectionA !== null);
  if (sectionA) {
    check('all 13 question ids rendered',
      sectionA.qids.length === 13, sectionA.qids.join(','));
    const expected = Array.from({ length: 13 }, (_, i) =>
      'Q' + String(i + 1).padStart(2, '0'));
    check('ids are Q01..Q13 in order',
      JSON.stringify(sectionA.qids) === JSON.stringify(expected),
      sectionA.qids.join(','));

    check('no Approve control inside Section A',
      !sectionA.buttons.some((b) => /approve/i.test(b)),
      sectionA.buttons.join(' | ') || '(none)');
    check('no Reject control inside Section A',
      !sectionA.hasReject, sectionA.buttons.join(' | ') || '(none)');

    check('wording shows the owner price RM 12.50',
      /RM 12\.50/.test(sectionA.text),
      (sectionA.text.match(/[^.]*RM 12\.50[^.]*/) || [''])[0].slice(0, 120));
    check('unresolved area placeholder stays visible',
      /\[named area\]/.test(sectionA.text),
      (sectionA.text.match(/[^.]*\[named area\][^.]*/) || [''])[0].slice(0, 110));
    check('"Needs your input" badge present',
      sectionA.chips.some((c) => /needs your input/i.test(c)),
      sectionA.chips.filter((c) => /needs/i.test(c)).join(' | '));
    check('"Preview only" badge present',
      sectionA.chips.some((c) => /preview only/i.test(c)),
      sectionA.chips.slice(0, 4).join(' | '));
    check('"Not yet fielded" notice present',
      /not yet fielded/i.test(sectionA.text));
    check('Section B label present on the page',
      /Section B/i.test(afterClick));
  }

  await page.screenshot({
    path: path.join(SHOTS, 'stage4_sectionA.png'),
    fullPage: true,
  });

  const payload = {
    captured_at: new Date().toISOString(),
    url: page.url(),
    bundle_hash_note: 'served main.client.dart.js sha256 recorded separately',
    console_errors: consoleErrors,
    sectionA,
    results,
    passed: results.filter((r) => r.status === 'PASS').length,
    failed: results.filter((r) => r.status === 'FAIL').length,
  };
  fs.writeFileSync(OUT, JSON.stringify(payload, null, 1));

  console.log(`\n${payload.passed}/${results.length} checks passed`);
  if (payload.failed) {
    console.log('FAILED:');
    for (const r of results.filter((x) => x.status === 'FAIL')) {
      console.log(`  - ${r.id}: ${r.detail}`);
    }
  }
  await browser.close();
  process.exit(payload.failed ? 1 : 0);
})().catch((e) => {
  console.error('PROBE ERROR', e && e.message);
  process.exit(2);
});
