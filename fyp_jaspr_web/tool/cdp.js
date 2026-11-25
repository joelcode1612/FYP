// Minimal CDP client for the SiteWise verification probes.
//
// Playwright's `connectOverCDP` hangs against this Chrome build (156) because of
// its extra `browser_ui` targets, so the probes talk to the page target's
// websocket directly. Node 22 provides a global `WebSocket`, so no dependency is
// needed beyond the standard library.
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

/// Connects to the first page target whose URL matches [match].
async function openPage(match) {
  const targets = await getJson('/json/list');
  const target = targets.find(
    (t) => t.type === 'page' && (!match || t.url.includes(match)),
  );
  if (!target) throw new Error('no page target matched ' + match);

  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', reject, { once: true });
  });

  let nextId = 1;
  const pending = new Map();
  ws.addEventListener('message', (event) => {
    const msg = JSON.parse(event.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(JSON.stringify(msg.error)));
      else resolve(msg.result);
    }
  });

  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    });

  const evaluate = async (expression) => {
    const result = await send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (result.exceptionDetails) {
      throw new Error(
        'evaluate failed: ' + JSON.stringify(result.exceptionDetails).slice(0, 400),
      );
    }
    return result.result.value;
  };

  const screenshot = async (path) => {
    const { data } = await send('Page.captureScreenshot', {
      format: 'png',
      captureBeyondViewport: false,
    });
    fs.writeFileSync(path, Buffer.from(data, 'base64'));
    const b = fs.readFileSync(path);
    return { path, w: b.readUInt32BE(16), h: b.readUInt32BE(20), kb: Math.round(b.length / 1024) };
  };

  const scrollTo = (y) =>
    evaluate(`window.scrollTo(0, ${y}); Math.round(window.scrollY)`);

  // A target opened from the command line can still report about:blank in its
  // own execution context, so navigation is driven explicitly instead of being
  // assumed.
  const navigate = async (url, settleMs = 12000) => {
    await send('Page.enable');
    await send('Page.navigate', { url });
    await new Promise((r) => setTimeout(r, settleMs));
    return evaluate('location.href');
  };

  return {
    ws,
    send,
    evaluate,
    screenshot,
    scrollTo,
    navigate,
    url: target.url,
    close: () => ws.close(),
  };
}

module.exports = { openPage, getJson };
