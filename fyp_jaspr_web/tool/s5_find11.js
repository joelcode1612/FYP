// Read the rendered Stage 5 page and report every place a count could read as
// "11", plus the full status strip and blocker list. Read-only: no clicks that
// mutate, no API writes.
const { openPage } = require('./cdp.js');

(async () => {
  const page = await openPage('/entrepreneur/assessments');
  const url = await page.evaluate('location.href');
  const text = await page.evaluate('document.body.innerText');
  console.log('URL:', url);
  console.log('LENGTH:', text.length);

  // 1. Every line containing the digits 11.
  const lines = text.split('\n');
  const hits = [];
  lines.forEach((line, i) => {
    if (/\b11\b/.test(line)) hits.push(`[${i}] ${line.trim().slice(0, 200)}`);
  });
  console.log('\n=== lines containing "11" (' + hits.length + ') ===');
  hits.forEach((h) => console.log(h));

  // 2. The composed questionnaire component's own text.
  const comp = await page.evaluate(`(() => {
    const el = document.querySelector('.cq5, .cq-shell, [class*="cq"]');
    if (!el) return null;
    const root = el.closest('section') || el.parentElement || el;
    return root.innerText;
  })()`);
  if (comp) {
    console.log('\n=== component text length:', comp.length, '===');
    const cl = comp.split('\n').filter((l) => l.trim());
    console.log('=== first 120 lines of component ===');
    cl.slice(0, 120).forEach((l, i) => console.log(`[${i}] ${l.trim().slice(0, 180)}`));
  } else {
    console.log('\n(no .cq5 container found)');
  }
  process.exit(0);
})().catch((e) => {
  console.error('FAILED:', e && e.message ? e.message : e);
  process.exit(1);
});
