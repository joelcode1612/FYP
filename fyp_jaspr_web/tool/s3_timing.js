// Stage 3 render-time check for the governed objective panel.
//
// The panel used to stay in "Reading persisted research objectives…" for ~20s
// because it awaited every per-proposal readback and decision before rendering
// the list it had already received. It now renders the list first and hydrates
// provenance afterwards. This measures the gap between navigation and the list
// being on screen, so the fix is evidence rather than an assertion.
const { openPage } = require('./cdp');

const TARGET =
  'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638';

(async () => {
  const page = await openPage('8093');
  const started = Date.now();
  await page.navigate(TARGET, 1500);

  let outcome = 'timeout';
  let sawLoading = false;
  for (let i = 0; i < 120; i++) {
    const state = await page.evaluate(`(() => {
      const body = document.body.innerText || '';
      if (/\\d+ proposals? ·/.test(body)) return 'list';
      if (/Reading persisted research objectives/.test(body)) return 'loading';
      return 'other';
    })()`);
    if (state === 'loading') sawLoading = true;
    if (state === 'list') {
      outcome = 'list';
      break;
    }
    await new Promise((r) => setTimeout(r, 250));
  }

  const elapsed = Date.now() - started;
  const detail = await page.evaluate(`(() => {
    const body = document.body.innerText || '';
    const line = body.match(/[^\\n]*\\d+ proposals? ·[^\\n]*/);
    const prov = body.match(/Execution mode[^\\n]*/);
    const badges = (body.match(/Approved by you|Rejected by you/g) || []);
    return {
      line: line ? line[0].trim() : '',
      provenance: prov ? prov[0].trim() : '',
      badges: Array.from(new Set(badges)),
    };
  })()`);

  console.log(JSON.stringify({ outcome, sawLoading, ms: elapsed, ...detail }, null, 1));
  page.close();
  process.exit(0);
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
