// Dump the full rendered text of the currently open Stage 5 page.
const { openPage } = require('./cdp.js');

(async () => {
  const page = await openPage('/entrepreneur/assessments');
  const text = await page.evaluate('document.body.innerText');
  console.log('URL:', await page.evaluate('location.href'));
  console.log('=== BODY ===');
  console.log(text);
  process.exit(0);
})().catch((e) => {
  console.error('FAILED:', e && e.message ? e.message : e);
  process.exit(1);
});
