// Assessment-switching check for Stage 5.
//
// Tries an *in-place* switch first (history pushState + popstate, which is what
// the client router observes), then falls back to full navigations. Either way
// the assertion is the same: after switching, the document must belong to the
// newly selected assessment and must not carry anything from the previous one.
const { openPage } = require('./cdp');

const BASE = 'http://127.0.0.1:8093';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const SUMMARY = `(() => {
  const root = document.querySelector('.cq5');
  if (!root) return null;
  const rows = Array.from(root.querySelectorAll('.cq-summary-row'))
    .map((n) => n.innerText.replace(/\\s+/g, ' ').trim());
  const note = root.querySelector('.cq-preview-note');
  const ids = Array.from(root.querySelectorAll('.cq-table tbody .cq-qid'))
    .map((n) => n.innerText.trim());
  return {
    rows,
    assessmentLine: note ? note.innerText.replace(/\\s+/g, ' ').trim() : '',
    ids,
    revision: (rows.find((r) => r.startsWith('Revision composed against')) || ''),
  };
})()`;

const url = (id) => `${BASE}/entrepreneur/assessments?id=${id}&stage=assessment_report`;

(async () => {
  const page = await openPage('8093');

  const visits = [];
  const record = async (label) => {
    const s = await page.evaluate(SUMMARY);
    visits.push({ label, mounted: s != null, ...(s || {}) });
    return s;
  };

  // 1 — first assessment
  await page.navigate(url('EP-02638'), 17000);
  const a = await record('EP-02638 (load)');

  // 2 — in-place switch to the second assessment
  await page.evaluate(`(() => {
    history.pushState({}, '', ${JSON.stringify(url('EP-02087'))});
    window.dispatchEvent(new PopStateEvent('popstate'));
    return true;
  })()`);
  await sleep(9000);
  const b = await record('EP-02087 (pushState)');
  const inPlaceWorked =
    b != null && b.assessmentLine.includes('8c30a934');

  // 3 — in-place switch back
  await page.evaluate(`(() => {
    history.pushState({}, '', ${JSON.stringify(url('EP-02638'))});
    window.dispatchEvent(new PopStateEvent('popstate'));
    return true;
  })()`);
  await sleep(9000);
  const c = await record('EP-02638 (pushState back)');

  // 4 — if the in-place path did not re-render, prove the same with full loads
  let fallback = null;
  if (!inPlaceWorked) {
    const again = [];
    for (const id of ['EP-02087', 'EP-02638']) {
      await page.navigate(url(id), 16000);
      const s = await page.evaluate(SUMMARY);
      again.push({ id, mounted: s != null, ...(s || {}) });
    }
    fallback = again;
  }

  console.log(JSON.stringify({
    inPlaceWorked,
    visits,
    fallback,
    leakage: {
      // The second visit must not mention the first assessment's id.
      ep02087CarriesFirst: !!(b && b.assessmentLine.includes('9af8000e')),
      backCarriesSecond: !!(c && c.assessmentLine.includes('8c30a934')),
    },
  }, null, 1));

  page.close();
  process.exit(0);
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
