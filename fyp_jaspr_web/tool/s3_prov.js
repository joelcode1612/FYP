const { openPage } = require('./cdp');
(async () => {
  const page = await openPage('8093');
  const t0 = Date.now();
  await page.navigate('http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638', 1000);
  const marks = {};
  for (let i = 0; i < 160; i++) {
    const s = await page.evaluate(`(() => {
      const b = document.body.innerText || '';
      return {
        list: /\\d+ proposals? ·/.test(b),
        prov: /Execution mode/.test(b),
      };
    })()`);
    if (s.list && !marks.list) marks.list = Date.now() - t0;
    if (s.prov && !marks.prov) marks.prov = Date.now() - t0;
    if (marks.list && marks.prov) break;
    await new Promise((r) => setTimeout(r, 250));
  }
  const prov = await page.evaluate(`(() => {
    const m = (document.body.innerText || '').match(/Execution mode[^\\n]*/);
    return m ? m[0].trim() : '';
  })()`);
  console.log(JSON.stringify({ marks, prov }, null, 1));
  page.close(); process.exit(0);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
