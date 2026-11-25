// Compare "Continue to question review" (button) against direct stepper
// navigation, and record every API request each path produces.
//
// Read-only: it clicks a navigation button, never Approve/Reject/Generate.
const fs = require('fs');
const http = require('http');

const getJson = (path) =>
  new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port: 9222, path }, (res) => {
      let b = '';
      res.on('data', (c) => (b += c));
      res.on('end', () => { try { resolve(JSON.parse(b)); } catch (e) { reject(e); } });
    }).on('error', reject);
  });

(async () => {
  const targets = await getJson('/json/list');
  const target = targets.find(
    (t) => t.type === 'page' && t.url.includes('/entrepreneur/assessments'));
  if (!target) throw new Error('no workspace target');

  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r, j) => {
    ws.addEventListener('open', r, { once: true });
    ws.addEventListener('error', j, { once: true });
  });

  let nextId = 1;
  const pending = new Map();
  const live = new Map();
  let rows = [];

  ws.addEventListener('message', (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      const { resolve, reject } = pending.get(m.id);
      pending.delete(m.id);
      m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result);
      return;
    }
    if (m.method === 'Network.requestWillBeSent') {
      const u = m.params.request.url;
      if (u.includes('/api/v1')) {
        live.set(m.params.requestId, { method: m.params.request.method, url: u });
      }
    } else if (m.method === 'Network.responseReceived') {
      const r = live.get(m.params.requestId);
      if (r) {
        rows.push({ ...r, status: m.params.response.status });
        live.delete(m.params.requestId);
      }
    }
  });

  const send = (m, p = {}) => new Promise((res, rej) => {
    const id = nextId++;
    pending.set(id, { resolve: res, reject: rej });
    ws.send(JSON.stringify({ id, method: m, params: p }));
  });
  const evaluate = async (e) => {
    const r = await send('Runtime.evaluate',
      { expression: e, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error('eval: ' + JSON.stringify(r.exceptionDetails).slice(0, 200));
    return r.result.value;
  };

  await send('Network.enable');
  await send('Page.enable');

  const url = (stage) =>
    'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638&stage=' + stage;

  // --- Path A: land on Stage 3, then click the transition button ---
  await send('Page.navigate', { url: url('location_evidence') });
  await new Promise((r) => setTimeout(r, 16000));

  const buttons = await evaluate(`(() => {
    const out = [];
    document.querySelectorAll('button').forEach((b) => {
      const t = (b.innerText || '').trim();
      if (t) out.push({ text: t, disabled: b.disabled });
    });
    return out;
  })()`);
  console.log('=== buttons on Stage 3 ===');
  buttons.forEach((b) => console.log(`  ${b.disabled ? '[disabled] ' : ''}${b.text}`));

  const hasButton = buttons.some((b) => /view stage 4: question review/i.test(b.text));
  console.log('\nhas "View Stage 4: Question review":', hasButton);

  rows = [];
  if (hasButton) {
    await evaluate(`(() => {
      const b = [...document.querySelectorAll('button')]
        .find((x) => /view stage 4: question review/i.test(x.innerText || ''));
      b.click();
      return true;
    })()`);
    await new Promise((r) => setTimeout(r, 16000));
  }
  const pathA = rows.slice();
  const stageAfterA = await evaluate(`(() => {
    const el = document.querySelector('.asw-stepbar__title, h1, h2');
    return { url: location.href, title: el ? el.innerText : null };
  })()`);

  console.log('\n=== Path A: click "Continue to question review" ===');
  console.log('landed:', JSON.stringify(stageAfterA));
  console.log('API requests produced by the click:', pathA.length);
  pathA.forEach((r) => console.log(`  ${r.method.padEnd(4)} ${r.status} ${r.url.replace('http://127.0.0.1:8093','').slice(0,120)}`));

  // --- Path B: direct navigation to the Stage 4 stage key ---
  rows = [];
  await send('Page.navigate', { url: url('ai_explanation') });
  await new Promise((r) => setTimeout(r, 16000));
  const pathB = rows.slice();
  console.log('\n=== Path B: direct stepper navigation to ai_explanation ===');
  console.log('API requests:', pathB.length);
  pathB.forEach((r) => console.log(`  ${r.method.padEnd(4)} ${r.status} ${r.url.replace('http://127.0.0.1:8093','').slice(0,120)}`));

  fs.writeFileSync('transition_capture.json',
    JSON.stringify({ buttons, pathA, pathB, stageAfterA }, null, 2));
  process.exit(0);
})().catch((e) => { console.error('FAILED:', e.message || e); process.exit(1); });
