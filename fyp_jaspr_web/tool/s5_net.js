// Capture live network traffic during Stage 3/4 and Stage 5 navigation.
//
// Read-only: it only navigates between in-page stage panels, which the app
// already does on a normal click. It never clicks Approve/Reject/Generate, so no
// owner decision changes and no model call is dispatched by this probe.
const fs = require('fs');
const http = require('http');

const getJson = (path) =>
  new Promise((resolve, reject) => {
    http
      .get({ host: '127.0.0.1', port: 9222, path }, (res) => {
        let body = '';
        res.on('data', (c) => (body += c));
        res.on('end', () => {
          try {
            resolve(JSON.parse(body));
          } catch (e) {
            reject(e);
          }
        });
      })
      .on('error', reject);
  });

(async () => {
  const targets = await getJson('/json/list');
  const target = targets.find(
    (t) => t.type === 'page' && t.url.includes('/entrepreneur/assessments'),
  );
  if (!target) throw new Error('no workspace page target');

  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((res, rej) => {
    ws.addEventListener('open', res, { once: true });
    ws.addEventListener('error', rej, { once: true });
  });

  let nextId = 1;
  const pending = new Map();
  const requests = new Map(); // requestId -> {method,url,type}
  const rows = [];

  ws.addEventListener('message', (event) => {
    const msg = JSON.parse(event.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(JSON.stringify(msg.error)));
      else resolve(msg.result);
      return;
    }
    const { method, params } = msg;
    if (method === 'Network.requestWillBeSent') {
      requests.set(params.requestId, {
        method: params.request.method,
        url: params.request.url,
        type: params.type,
        at: Date.now(),
      });
    } else if (method === 'Network.responseReceived') {
      const req = requests.get(params.requestId);
      if (req) {
        rows.push({ ...req, status: params.response.status,
                    mime: params.response.mimeType });
        requests.delete(params.requestId);
      }
    } else if (method === 'Network.loadingFailed') {
      const req = requests.get(params.requestId);
      if (req) {
        rows.push({ ...req, status: 'FAILED:' + params.errorText, mime: '' });
        requests.delete(params.requestId);
      }
    }
  });

  const send = (m, p = {}) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method: m, params: p }));
    });

  const evaluate = async (expression) => {
    const r = await send('Runtime.evaluate', {
      expression, returnByValue: true, awaitPromise: true,
    });
    if (r.exceptionDetails) throw new Error('eval failed');
    return r.result.value;
  };

  await send('Network.enable');
  await send('Page.enable');

  const go = async (stage, settleMs) => {
    const url =
      'http://127.0.0.1:8093/entrepreneur/assessments?id=EP-02638&stage=' + stage;
    await send('Page.navigate', { url });
    await new Promise((r) => setTimeout(r, settleMs));
    return evaluate('location.href');
  };

  const mark = (label) => rows.push({ method: '---', url: label, status: '', mime: '' });

  const stages = process.argv.slice(2);
  const plan = stages.length
    ? stages
    : ['location_evidence', 'assessment_report'];
  for (const stage of plan) {
    mark('PHASE: stage=' + stage);
    await go(stage, 18000);
  }

  const interesting = rows.filter(
    (r) => r.method === '---' || r.url.includes('/api/v1'),
  );

  console.log('=== captured ' + interesting.length + ' API rows ===');
  for (const r of interesting) {
    if (r.method === '---') {
      console.log('\n' + r.url);
      continue;
    }
    const path = r.url.replace('http://127.0.0.1:8093', '');
    console.log(
      `${String(r.method).padEnd(5)} ${String(r.status).padEnd(6)} ${path.slice(0, 130)}`,
    );
  }

  fs.writeFileSync(
    'net_capture.json',
    JSON.stringify(interesting.map((r) => ({ ...r, at: undefined })), null, 2),
  );
  process.exit(0);
})().catch((e) => {
  console.error('FAILED:', e && e.message ? e.message : e);
  process.exit(1);
});
