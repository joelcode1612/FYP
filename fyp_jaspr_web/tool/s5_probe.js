// Stage 5 verification through the normal Entrepreneur Web app on :8093.
//
// Drives the page target directly over CDP (see tool/cdp.js for why Playwright
// is not used). Reports what the composed-questionnaire screen actually
// rendered, then captures it in viewport-sized frames.
//
// The browser is opened by hand with the app URL; this probe only reads and
// scrolls the page it finds.
const { openPage } = require('./cdp');

const OUT = '../artifacts';

const REPORT = `(() => {
  const root = document.querySelector('.cq5');
  if (!root) {
    return { mounted: false, bodyHead: (document.body.innerText || '').slice(0, 500) };
  }
  const text = (sel) => Array.from(root.querySelectorAll(sel))
    .map((n) => (n.innerText || '').replace(/\\s+/g, ' ').trim());
  const publish = Array.from(root.querySelectorAll('button'))
    .find((b) => /publish questionnaire/i.test(b.innerText || ''));
  return {
    mounted: true,
    headings: text('.cq-heading h2, .cq-section-head h3, .cq-panel-head h3'),
    chips: text('.cq-status-strip .cq-chip'),
    questionIds: text('.cq-table tbody .cq-qid'),
    questionCount: root.querySelectorAll('.cq-table tbody tr').length,
    summary: text('.cq-summary-row'),
    sectionB: text('.cq-blocked strong'),
    requirements: text('.cq-req'),
    intended: text('.cq-intended'),
    publish: publish ? {
      found: true,
      disabled: publish.hasAttribute('disabled') || publish.getAttribute('aria-disabled') === 'true',
      text: (publish.innerText || '').trim(),
    } : { found: false },
    footnote: text('.cq-footnote'),
    hasCafeFixture: /How often do you visit a caf/i.test(root.innerText || ''),
    dpr: window.devicePixelRatio,
    inner: [window.innerWidth, window.innerHeight],
  };
})()`;

(async () => {
  const ID = process.argv[2] || 'EP-02638';
  const TARGET = `http://127.0.0.1:8093/entrepreneur/assessments?id=${ID}&stage=assessment_report`;
  const page = await openPage('8093');
  const landed = await page.navigate(TARGET, 18000);
  console.log(JSON.stringify({ landed }));

  // Make sure the Stage 5 checkpoint is the one on screen.
  const hasStage5 = await page.evaluate(`!!document.querySelector('.cq5')`);
  if (!hasStage5) {
    await page.evaluate(`(() => {
      const nodes = Array.from(document.querySelectorAll('button,a,li,[role=button],[role=tab]'));
      const hit = nodes.find((el) => /questionnaire preview|publish questionnaire/i
        .test((el.innerText || '').replace(/\\s+/g, ' ')) && (el.innerText || '').length < 80);
      if (hit) hit.click();
      return !!hit;
    })()`);
    await new Promise((r) => setTimeout(r, 9000));
  }

  const report = await page.evaluate(REPORT);
  console.log(JSON.stringify({ url: page.url, report }, null, 1));

  const shots = [];
  if (report.mounted) {
    const geom = await page.evaluate(`(() => {
      const el = document.querySelector('.cq5');
      const r = el.getBoundingClientRect();
      return { top: Math.round(r.top + window.scrollY), height: Math.round(r.height),
               vh: window.innerHeight };
    })()`);
    const step = Math.max(600, geom.vh - 120);
    const frames = Math.min(4, Math.max(1, Math.ceil(geom.height / step)));
    for (let i = 0; i < frames; i++) {
      await page.scrollTo(Math.max(0, geom.top - 24 + i * step));
      await new Promise((r) => setTimeout(r, 500));
      shots.push(
        await page.screenshot(`${OUT}/stage5_real_${ID}_frame${i + 1}_20261124.png`),
      );
    }
    console.log(JSON.stringify({ geom, shots }, null, 1));
  }
  page.close();
  process.exit(0);
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
