/*
 * Explore map probe — verifies the Leaflet integration runtime behaviour of
 * `web/sitewise_combined_explore.js` against the BUILT site output, without
 * needing a signed-in session:
 *
 *   1. Static assets exist (vendored Leaflet, cluster plugin, explore JS/CSS).
 *   2. index.html loads them in the documented order, before the app bundle.
 *   3. /entrepreneur/explore is routed (anonymous visitors are redirected to
 *      the login screen with the destination preserved — the app guard).
 *   4. A self-written fixture page (materialised inside build/jaspr, so it is
 *      a build artifact and never ships in the repo) reproduces the page's
 *      DOM contract and asserts, on the SAME origin:
 *        - a real Leaflet map initialises in the canvas,
 *        - one marker per valid property renders (zero-coordinate records
 *          are skipped, never plotted),
 *        - the 500 m/1 km radius circle draws,
 *        - a marker click forwards the property id through the selection
 *          bridge into the app layer,
 *        - the transport panel reports an honest idle state when disabled.
 *
 * Usage: BASE=http://127.0.0.1:8091 node tool/probe_explore_map.js
 */
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const BASE = process.env.BASE || 'http://127.0.0.1:8091';
const BASE_DIR = new URL(BASE).pathname; // e.g. /
const BUILD_DIR = path.join(__dirname, '..', 'build', 'jaspr');
const FIXTURE_NAME = '_probe_explore_fixture.html';
const FIXTURE_PATH = path.join(BUILD_DIR, FIXTURE_NAME);

let pass = 0;
let fail = 0;
function check(name, ok, detail) {
  if (ok) {
    pass++;
    console.log(`  ok  ${name}${detail ? ' — ' + detail : ''}`);
  } else {
    fail++;
    console.log(`FAIL  ${name}${detail ? ' — ' + detail : ''}`);
  }
}

function get(path_) {
  return new Promise((resolve) => {
    http
      .get(BASE + path_, (res) => {
        let body = '';
        res.on('data', (c) => (body += c));
        res.on('end', () => resolve({ status: res.statusCode, body }));
      })
      .on('error', (e) => resolve({ status: 0, body: String(e) }));
  });
}

const STATE = JSON.stringify({
  selectedId: 'EP-01002',
  radiusM: 500,
  showTransport: false,
  properties: [
    { id: 'EP-01002', title: 'Selected shop', address: 'Jalan Test 1, Kuala Lumpur', lat: 3.139, lon: 101.687, rentRm: 3500, nearby: true },
    { id: 'EP-01003', title: 'Nearby cafe lot', address: 'Jalan Test 2, Kuala Lumpur', lat: 3.1412, lon: 101.6891, rentRm: 2800, nearby: true },
    { id: 'EP-01044', title: 'Far retail unit', address: 'Jalan Far 9, Petaling Jaya', lat: 3.1578, lon: 101.7118, rentRm: 5200, nearby: false },
    { id: 'EP-01077', title: 'No-coordinate record', address: 'Unknown', lat: 0, lon: 0, rentRm: 900, nearby: false },
  ],
});

const FIXTURE_HTML = `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<link rel="stylesheet" href="/vendor/leaflet/leaflet.css">
<link rel="stylesheet" href="/vendor/leaflet/MarkerCluster.css">
<link rel="stylesheet" href="/sitewise_combined_explore.css">
<style>body{margin:0}#swcx-leaflet{height:550px;width:900px}</style>
</head><body>
<div id="swcx-leaflet" class="swcx-map-canvas" role="region"
     aria-label="Interactive commercial property map"
     data-state='${STATE.replace(/'/g, '&#39;')}'></div>
<button id="swcx-selection-bridge" type="button" tabindex="-1"
        aria-hidden="true" style="display:none"></button>
<p id="swcx-transport-status" aria-live="polite"></p>
<div id="swcx-transport-results"></div>
<script src="/vendor/leaflet/leaflet.js"></script>
<script src="/vendor/leaflet/leaflet.markercluster.js"></script>
<script src="/sitewise_combined_explore.js"></script>
<script>
  window.__results = {};
  const results = window.__results;
  let bridgeCalls = 0;
  document.getElementById('swcx-selection-bridge')
    .addEventListener('click', () => bridgeCalls++);
  results.leafletLoaded = typeof window.L !== 'undefined';
  results.clusterLoaded = typeof window.L !== 'undefined' &&
    typeof window.L.markerClusterGroup === 'function';
  const settle = (ms) => new Promise((r) => setTimeout(r, ms));
  (async () => {
    await settle(1200); // boot + MutationObserver-driven first render
    results.mapInitialized =
      !!document.querySelector('#swcx-leaflet .leaflet-pane');
    results.markersRendered =
      document.querySelectorAll('#swcx-leaflet .swcx-pin').length;
    results.radiusCircleDrawn =
      !!document.querySelector('#swcx-leaflet path.leaflet-interactive, #swcx-leaflet svg path');
    results.selectedMarkerPresent =
      !!document.querySelector('#swcx-leaflet .swcx-pin--selected');
    const pins = [...document.querySelectorAll('#swcx-leaflet .swcx-pin')];
    const target = pins.find(
      (el) => el.closest('.leaflet-marker-icon')?.getAttribute('title') === 'Nearby cafe lot',
    );
    if (target) target.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await settle(400);
    results.bridgeCalled = bridgeCalls === 1;
    results.choiceId =
      document.getElementById('swcx-leaflet').getAttribute('data-choice');
    results.transportStatus =
      document.getElementById('swcx-transport-status').textContent.trim();
    results.mapError = !!document.querySelector('.swcx-map-error');
    results.done = true;
  })();
</script>
</body></html>`;

(async () => {
  const { chromium } = require('playwright-core');

  // --- 1. static assets -----------------------------------------------------
  for (const asset of [
    '/vendor/leaflet/leaflet.js',
    '/vendor/leaflet/leaflet.markercluster.js',
    '/vendor/leaflet/leaflet.css',
    '/vendor/leaflet/MarkerCluster.css',
    '/sitewise_combined_explore.js',
    '/sitewise_combined_explore.css',
  ]) {
    const res = await get(asset);
    check(`asset ${asset}`, res.status === 200, `HTTP ${res.status}`);
  }

  // --- 2. load order ---------------------------------------------------------
  const index = await get('/index.html');
  const html = index.body;
  const pos = (needle) => html.indexOf(needle);
  check(
    'index.html references the explore map assets',
    pos('/vendor/leaflet/leaflet.js') > -1 && pos('/sitewise_combined_explore.js') > -1,
  );
  check(
    'leaflet.js executes before the cluster plugin and the explore script',
    pos('/vendor/leaflet/leaflet.js') < pos('/vendor/leaflet/leaflet.markercluster.js') &&
      pos('/vendor/leaflet/leaflet.markercluster.js') < pos('/sitewise_combined_explore.js'),
  );
  check(
    'explore script executes before the app bundle',
    pos('/sitewise_combined_explore.js') < pos('/main.client.dart.js'),
  );

  const browser = await chromium.launch({
    executablePath:
      'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe',
    args: ['--no-proxy-server'],
  });

  // --- 3. route + anonymous guard -------------------------------------------
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await page.goto(BASE + '/entrepreneur/explore', { waitUntil: 'load' });
  await page.waitForTimeout(1200); // hydration + client router redirect
  const url = page.url();
  check(
    'explore route resolves through the client router (anonymous -> login with next)',
    url.includes('/login') && url.includes('next='),
    url,
  );

  // --- 4. map runtime fixture (same-origin page inside build output) ---------
  fs.mkdirSync(BUILD_DIR, { recursive: true });
  fs.writeFileSync(FIXTURE_PATH, FIXTURE_HTML, 'utf8');
  try {
    const fixturePage = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    await fixturePage.goto(BASE + '/' + FIXTURE_NAME, { waitUntil: 'load' });
    await fixturePage.waitForFunction('window.__results && window.__results.done', {
      timeout: 15000,
    });
    const r = await fixturePage.evaluate('window.__results');

    check('Leaflet library loaded from vendored files', r.leafletLoaded);
    check('marker clustering plugin available', r.clusterLoaded);
    check('Leaflet map initialised inside the canvas', r.mapInitialized);
    check('three valid markers rendered', r.markersRendered === 3, `got ${r.markersRendered}`);
    check('zero-coordinate record not plotted', r.markersRendered === 3);
    check('radius circle drawn for the selected property', r.radiusCircleDrawn);
    check('selected marker highlighted', r.selectedMarkerPresent);
    check(
      'marker click forwarded through the selection bridge',
      r.bridgeCalled && r.choiceId === 'EP-01003',
      `choice=${r.choiceId}`,
    );
    check(
      'transport panel shows honest idle state when disabled',
      r.transportStatus.includes('Turn on Transport'),
      `"${r.transportStatus.slice(0, 60)}"`,
    );
    check('no map-level error banner', !r.mapError);
  } finally {
    fs.rmSync(FIXTURE_PATH, { force: true });
  }

  // --- 5. responsive rules in the shipped CSS --------------------------------
  const css = await get('/sitewise_combined_explore.css');
  check(
    'responsive rules ship for narrow screens',
    css.body.includes('@media (max-width:950px)') &&
      css.body.includes('grid-template-columns:1fr'),
  );

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => {
  console.error('probe crashed:', e);
  try { fs.rmSync(FIXTURE_PATH, { force: true }); } catch (_) {}
  process.exit(2);
});
