const { openPage } = require('./cdp');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  const page = await openPage('8093');
  await page.navigate('http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638&stage=assessment_report', 17000);
  const shots = [];
  for (const [label, file] of [
    ['Who sees each question', 'routing'],
    ['Question details', 'details'],
  ]) {
    await page.evaluate(`(() => {
      const b = Array.from(document.querySelectorAll('.cq-tab'))
        .find((n) => (n.innerText || '').includes(${JSON.stringify(label)}));
      if (b) b.click();
      return !!b;
    })()`);
    await sleep(600);
    const geom = await page.evaluate(`(() => {
      const el = document.querySelector('.cq5');
      const r = el.getBoundingClientRect();
      return { top: Math.round(r.top + window.scrollY), vh: window.innerHeight };
    })()`);
    await page.scrollTo(Math.max(0, geom.top - 24));
    await sleep(400);
    shots.push(await page.screenshot(`../artifacts/s5v_tab_${file}.png`));
  }
  console.log(JSON.stringify(shots, null, 1));
  page.close(); process.exit(0);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
