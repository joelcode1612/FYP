// Full Stage 5 verification through the normal Entrepreneur app on :8093.
//
// For one assessment this checks, in order:
//   1. the composed-questionnaire API response (status, counts, authority flags);
//   2. the rendered document (headings, items, summary, publish control);
//   3. the three preserved views (Question list / Who sees each question /
//      Question details) and that switching them changes the panel;
//   4. refresh consistency (a reload must produce the same document identity).
//
// Usage: node tool/s5_verify.js EP-02638
const { openPage } = require('./cdp');

const BASE = 'http://127.0.0.1:8093';
const ID = process.argv[2] || 'EP-02638';
const OUT = '../artifacts';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const REPORT = `(() => {
  const root = document.querySelector('.cq5');
  if (!root) return { mounted: false, body: (document.body.innerText || '').slice(0, 400) };
  const t = (sel) => Array.from(root.querySelectorAll(sel))
    .map((n) => (n.innerText || '').replace(/\\s+/g, ' ').trim());
  const tabs = Array.from(root.querySelectorAll('.cq-tab'))
    .map((b) => (b.innerText || '').replace(/\\s+/g, ' ').trim());
  const publish = Array.from(root.querySelectorAll('button'))
    .find((b) => /publish questionnaire/i.test(b.innerText || ''));
  return {
    mounted: true,
    tabs,
    activeTab: (() => {
      const a = root.querySelector('.cq-tab.is-active');
      return a ? (a.innerText || '').replace(/\\s+/g, ' ').trim() : null;
    })(),
    headings: t('.cq-section-head h3, .cq-detail-box h4'),
    chips: t('.cq-status-strip .cq-chip'),
    questionIds: t('.cq-table tbody .cq-qid'),
    summary: t('.cq-summary-row'),
    viewCopy: t('.cq-view-copy'),
    publish: publish
      ? {
          disabled: publish.hasAttribute('disabled'),
          ariaDisabled: publish.getAttribute('aria-disabled'),
          caption: t('.cq-decision-box small').join(' '),
        }
      : null,
    footnote: t('.cq-footnote').join(' '),
    // The design fixture's exact sentence. A loose /visit a caf/ match is a
    // false positive: Q08's real governed wording contains 'visit a café'.
    hasDesignFixture: (root.innerText || '').includes('How often do you visit a caf'),
  };
})()`;

(async () => {
  const page = await openPage('8093');

  // -- 1. API evidence -------------------------------------------------------
  const url = `${BASE}/entrepreneur/assessments?id=${ID}&stage=assessment_report`;
  await page.navigate(url, 17000);

  const api = await page.evaluate(`(async () => {
    const raw = localStorage.getItem(Object.keys(localStorage)
      .find((k) => /-auth-token$/.test(k)));
    const token = JSON.parse(raw).access_token;
    // The EP-xxxxx code is a display id. The marketplace assessment UUID comes
    // from by-property, and by-marketplace requires the UUID (a code answers 422).
    const rec = await (await fetch('/api/v1/assessments/by-property/${ID}', {
      headers: { authorization: 'Bearer ' + token } })).json();
    const marketplaceId = rec.assessment.assessment_id;
    const link = await (await fetch(
      '/api/v1/m2/assessments/by-marketplace/' + marketplaceId,
      { headers: { authorization: 'Bearer ' + token } })).json();
    const m2 = link.m2_assessment_id;
    const draft = await (await fetch('/api/v1/m2/assessments/' + m2, {
      headers: { authorization: 'Bearer ' + token } })).json();
    const rev = draft.assessment.revision;
    const conf = await (await fetch(
      '/api/v1/m2/assessments/' + m2 + '/confirmation-current',
      { headers: { authorization: 'Bearer ' + token } })).json();
    const q = '/api/v1/project1-workflow/assessments/' + m2 +
      '/stage5/composed-questionnaire?expected_revision=' + rev +
      '&confirmation_id=' + conf.id;
    const r = await fetch(q, { headers: { authorization: 'Bearer ' + token } });
    const body = await r.json();
    return {
      status: r.status,
      request: q.replace('/api/v1/project1-workflow', ''),
      marketplace_assessment_id: marketplaceId,
      m2_assessment_id: m2,
      revision: rev,
      confirmation_id: conf.id,
      contract_version: body.contract_version,
      counts: body.counts,
      composition_status: body.composition_status,
      population_status: body.population_status,
      additional_status: body.additional_status,
      admitted_objective_count: body.admitted_objective_count,
      validation_status: body.validation && body.validation.status,
      blocking: (body.unresolved_requirements || [])
        .filter((x) => x.blocking).map((x) => x.code),
      authority: {
        fielding_authorized: body.fielding_authorized,
        publication_authorized: body.publication_authorized,
        scientifically_accepted: body.scientifically_accepted,
        customer_fielding_enabled: body.customer_fielding_enabled,
        report_release_authorized: body.report_release_authorized,
      },
      publication_readiness: body.publication_readiness,
      fixed_ids: (body.items || []).filter((i) => i.section === 'A_FIXED_CORE')
        .map((i) => i.item_id),
      additional_ids: (body.items || []).filter((i) => i.section === 'B_ADDITIONAL')
        .map((i) => i.item_id),
    };
  })()`);

  // -- 2. rendered document --------------------------------------------------
  const list = await page.evaluate(REPORT);

  // -- 3. the three views ----------------------------------------------------
  const views = {};
  for (const label of ['Who sees each question', 'Question details', 'Question list']) {
    await page.evaluate(`(() => {
      const b = Array.from(document.querySelectorAll('.cq-tab'))
        .find((n) => (n.innerText || '').includes(${JSON.stringify(label)}));
      if (b) b.click();
      return !!b;
    })()`);
    await sleep(400);
    const s = await page.evaluate(REPORT);
    views[label] = {
      activeTab: s.activeTab,
      headings: s.headings,
      viewCopy: s.viewCopy,
      questionRows: s.questionIds ? s.questionIds.length : 0,
    };
  }
  // Back to the list for the screenshot.
  await page.evaluate(`(() => {
    const b = Array.from(document.querySelectorAll('.cq-tab'))
      .find((n) => (n.innerText || '').includes('Question list'));
    if (b) b.click();
  })()`);
  await sleep(400);

  // -- 4. refresh consistency ------------------------------------------------
  const before = await page.evaluate(`(() => {
    const s = Array.from(document.querySelectorAll('.cq-summary-row'))
      .map((n) => n.innerText.replace(/\\s+/g, ' ').trim());
    return s.join(' | ');
  })()`);
  await page.send('Page.reload', { ignoreCache: true });
  await sleep(17000);
  const after = await page.evaluate(`(() => {
    const root = document.querySelector('.cq5');
    if (!root) return 'NOT MOUNTED';
    return Array.from(root.querySelectorAll('.cq-summary-row'))
      .map((n) => n.innerText.replace(/\\s+/g, ' ').trim()).join(' | ');
  })()`);

  // -- screenshots -----------------------------------------------------------
  const shots = [];
  const geom = await page.evaluate(`(() => {
    const el = document.querySelector('.cq5');
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { top: Math.round(r.top + window.scrollY), height: Math.round(r.height),
             vh: window.innerHeight };
  })()`);
  if (geom) {
    const step = Math.max(600, geom.vh - 120);
    const frames = Math.min(3, Math.max(1, Math.ceil(geom.height / step)));
    for (let i = 0; i < frames; i++) {
      await page.scrollTo(Math.max(0, geom.top - 24 + i * step));
      await sleep(400);
      shots.push(await page.screenshot(`${OUT}/s5v_${ID}_f${i + 1}.png`));
    }
  }

  console.log(JSON.stringify({
    id: ID, api, rendered: list,
    views,
    refresh: { identical: before === after, before, after },
    shots,
  }, null, 1));
  page.close();
  process.exit(0);
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
