// GATE 5 browser probe: does the BUILT report route render a measurement?
//
// This is a UI-render probe, not authenticated-E2E evidence. It answers one
// question: with the report page loaded in a real browser against the real
// backend, does any measurement number reach the DOM?
//
// Probe A loads the route with NO session. The guard must refuse.
// Probe B loads it with the stand-in bridge from tool/session_harness.js so the
//   page's post-guard rendering can be observed. The session is fabricated by
//   the harness, so probe B proves what the UI *displays*, never that a request
//   was authorised.
//
// Usage: node gate5_browser_probe.js --api http://127.0.0.1:8011 --out <path>
const http = require('http');
const fs = require('fs');
const path = require('path');

const WEB = path.join(__dirname, '..', '..', 'fyp_jaspr_web');
const ROOT = path.join(WEB, 'build', 'jaspr');
const { installHarnessSession } = require(path.join(WEB, 'tool', 'session_harness.js'));
const { chromium } = require(path.join(WEB, 'tool', 'node_modules', 'playwright-core'));

const EXE = 'C:/Users/HP/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe';
const TYPES = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.json': 'application/json',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml',
  '.woff2': 'font/woff2', '.woff': 'font/woff', '.webp': 'image/webp',
  '.map': 'application/json', '.txt': 'text/plain; charset=utf-8',
};

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const API = arg('api', 'http://127.0.0.1:8011');
const OUT = arg('out', '');
const PORT = Number(arg('port', '8190'));

// Static bundle + /api proxy, so the SPA's same-origin default
// (http://127.0.0.1:8090/api/...) reaches the isolated backend unchanged.
function startServer() {
  const api = new URL(API);
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      if (req.url.startsWith('/api/')) {
        const upstream = http.request(
          { host: api.hostname, port: api.port, path: req.url, method: req.method,
            headers: { ...req.headers, host: `${api.hostname}:${api.port}` } },
          (up) => { res.writeHead(up.statusCode, up.headers); up.pipe(res); },
        );
        upstream.on('error', () => {
          res.writeHead(502, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ detail: 'isolated backend unreachable' }));
        });
        req.pipe(upstream);
        return;
      }
      const urlPath = decodeURIComponent(req.url.split('?')[0]);
      let file = path.join(ROOT, urlPath);
      if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) {
        file = path.join(ROOT, 'index.html');
      }
      fs.readFile(file, (err, data) => {
        if (err) { res.writeHead(404); res.end('not found'); return; }
        res.writeHead(200, {
          'content-type': TYPES[path.extname(file)] || 'application/octet-stream',
          'cache-control': 'no-store',
        });
        res.end(data);
      });
    });
    server.listen(PORT, '127.0.0.1', () => resolve(server));
  });
}

// A measurement is a rendered figure with a unit or a percentage. The report
// page's own chrome (dates, counts of sections) is not a measurement, so the
// pattern requires a percent sign or a unit word after the number.
const MEASUREMENT = /\b\d[\d,]*(\.\d+)?\s*(%|percent|days?|respondents?|visits?|customers?|RM\s?\d)/i;

async function probe(browser, { label, route, session }) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 980 } });
  const page = await ctx.newPage();
  const api = [];
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e.message || e).slice(0, 200)));
  page.on('response', (r) => {
    const u = new URL(r.url());
    if (u.pathname.startsWith('/api/')) {
      api.push({ path: u.pathname, status: r.status() });
    }
  });
  if (session) await installHarnessSession(page, { role: 'entrepreneur' });

  const result = { label, route, session: session ? 'STANDIN_HARNESS' : 'NONE' };
  try {
    const resp = await page.goto(`http://127.0.0.1:${PORT}${route}`,
      { waitUntil: 'networkidle', timeout: 45000 });
    await page.waitForTimeout(2500);
    result.http_status = resp ? resp.status() : null;
    result.final_path = new URL(page.url()).pathname;
    const text = await page.evaluate(() => document.body.innerText || '');
    const flat = text.replace(/\s+/g, ' ').trim();
    result.body_excerpt = flat.slice(0, 700);
    result.body_length = flat.length;
    result.measurement_matches = [...new Set((flat.match(
      new RegExp(MEASUREMENT.source, 'gi')) || []).map((s) => s.trim()))].slice(0, 10);
    result.renders_a_measurement = result.measurement_matches.length > 0;
    result.api_calls = api;
    result.page_errors = errors.slice(0, 5);
  } catch (e) {
    result.error = String(e.message || e).slice(0, 300);
    result.api_calls = api;
    result.page_errors = errors.slice(0, 5);
  }
  await ctx.close();
  return result;
}

(async () => {
  const server = await startServer();
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox', '--no-proxy-server'] });
  const receipt = {
    _note: 'Probe A is genuine evidence that the route guard refuses an anonymous '
      + 'load. Probe B uses the stand-in bridge, so it evidences what the UI '
      + 'renders and nothing about authorisation.',
    route: '/entrepreneur/cafe-report/view?assessment=gate5-probe',
    backend: API,
    probes: [],
  };
  try {
    receipt.probes.push(await probe(browser, {
      label: 'A_anonymous',
      route: '/entrepreneur/cafe-report/view?assessment=gate5-probe',
      session: false,
    }));
    receipt.probes.push(await probe(browser, {
      label: 'B_standin_session',
      route: '/entrepreneur/cafe-report/view?assessment=gate5-probe',
      session: true,
    }));
    // The report selector, which is the entry point and needs no assessment id.
    receipt.probes.push(await probe(browser, {
      label: 'C_selector_standin_session',
      route: '/entrepreneur/cafe-report',
      session: true,
    }));
  } finally {
    await browser.close();
    server.close();
  }
  const body = JSON.stringify(receipt, null, 2);
  if (OUT) fs.writeFileSync(OUT, body);
  console.log(body);
})();
