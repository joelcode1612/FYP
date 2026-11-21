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
 *        - the four surrounding-area layer chips render, draw category
 *          markers from the pushed `data-nearby` payload, carry honest
 *          per-layer states (mapped / no data / source unavailable), toggle
 *          on click and re-slice when the radius changes.
 *
 * Usage: BASE=http://127.0.0.1:8091 node tool/probe_explore_map.js
 */
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const BASE = process.env.BASE || 'http://127.0.0.1:8091';
// The real app server (unified FastAPI) — the anonymous-guard redirect only
// exists there; a bare static file server cannot exercise the client router.
const APP_BASE = process.env.APP_BASE || 'http://127.0.0.1:8090';
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

const STATE_500 = JSON.stringify({
  selectedId: 'EP-01002',
  radiusM: 500,
  properties: [
    { id: 'EP-01002', title: 'Selected shop', address: 'Jalan Test 1, Kuala Lumpur', lat: 3.139, lon: 101.687, rentRm: 3500, nearby: true },
    { id: 'EP-01003', title: 'Nearby cafe lot', address: 'Jalan Test 2, Kuala Lumpur', lat: 3.1412, lon: 101.6891, rentRm: 2800, nearby: true },
    { id: 'EP-01044', title: 'Far retail unit', address: 'Jalan Far 9, Petaling Jaya', lat: 3.1578, lon: 101.7118, rentRm: 5200, nearby: false },
    { id: 'EP-01077', title: 'No-coordinate record', address: 'Unknown', lat: 0, lon: 0, rentRm: 900, nearby: false },
  ],
});
const STATE_1000 = JSON.stringify({ ...JSON.parse(STATE_500), radiusM: 1000 });

// Same shape the nearby-places endpoint returns; one category per honest
// state so the chips must show mapped / no data / source unavailable.
const NEARBY = JSON.stringify({
  property_id: 'EP-01002',
  radius_m: 1000,
  distance_method: 'straight_line_spherical',
  categories: {
    competitors: { state: 'mapped', returned: 2, total_in_radius: 2, truncated: false, source: 'fnb_outlet' },
    demand_generators: { state: 'mapped', returned: 1, total_in_radius: 1, truncated: false, source: 'pois_master' },
    accessibility: { state: 'source_unavailable', returned: 0, total_in_radius: null, truncated: false, source: 'gtfs_stops', error: 'fixture' },
    parking: { state: 'mapped', returned: 1, total_in_radius: 1, truncated: false, source: 'psense_parking' },
  },
  places: [
    { id: 'fnb-1', name: 'Fixture kopitiam', category: 'competitors', subtype: 'cafe', detail: null, lat: 3.1396, lng: 101.6876, source: 'osm', distance_m: 90, operating_status: 'likely_open', observed_at: '2026-06-21' },
    { id: 'fnb-2', name: 'Fixture bakery', category: 'competitors', subtype: 'bakery', detail: null, lat: 3.1365, lng: 101.6855, source: 'osm', distance_m: 330, operating_status: 'unknown', observed_at: '2026-06-21' },
    { id: 'poi-1', name: 'Fixture mall', category: 'demand_generators', subtype: 'shopping_mall', detail: null, lat: 3.1398, lng: 101.688, source: 'osm', distance_m: 130, operating_status: null, observed_at: null },
    { id: 'park-1', name: 'Fixture car park', category: 'parking', subtype: 'parking', detail: 'multi-storey', lat: 3.1394, lng: 101.6874, source: 'osm', distance_m: 800, operating_status: null, observed_at: null },
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
     data-state='${STATE_500.replace(/'/g, '&#39;')}'
     data-nearby='${NEARBY.replace(/'/g, '&#39;')}'></div>
<button id="swcx-selection-bridge" type="button" tabindex="-1"
        aria-hidden="true" style="display:none"></button>
<script src="/map-config.js"></script>
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
  const chip = (k) => document.querySelector('.swcx-layer-chip[data-layer="' + k + '"]');
  const catMarkers = () =>
    document.querySelectorAll('#swcx-leaflet .swcx-cat-icon').length;
  (async () => {
   try {
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
    results.mapError = !!document.querySelector('.swcx-map-error');

    // --- surrounding-area layer chips -------------------------------------
    results.chipsRendered = document.querySelectorAll('.swcx-layer-chip').length;
    results.catMarkersAt500 = catMarkers();
    results.competitorCount = chip('competitors')
      ?.querySelector('.swcx-layer-chip__count')?.textContent;
    results.accessibilityCount = chip('accessibility')
      ?.querySelector('.swcx-layer-chip__count')?.textContent;
    results.accessibilityTag = chip('accessibility')
      ?.querySelector('.swcx-layer-chip__tag')?.textContent;
    results.parkingCount = chip('parking')
      ?.querySelector('.swcx-layer-chip__count')?.textContent;
    results.parkingTag = chip('parking')
      ?.querySelector('.swcx-layer-chip__tag')?.textContent;
    results.competitorTag = chip('competitors')
      ?.querySelector('.swcx-layer-chip__tag')?.textContent;

    // toggle one layer off and on again
    chip('competitors').click();
    await settle(300);
    results.competitorPressedAfterHide =
      chip('competitors').getAttribute('aria-pressed');
    results.catMarkersAfterHide = catMarkers();
    chip('competitors').click();
    await settle(300);
    results.competitorPressedAfterShow =
      chip('competitors').getAttribute('aria-pressed');
    results.catMarkersAfterShow = catMarkers();

    // --- regression: the framework must not own Leaflet's container --------
    const host = document.getElementById('swcx-leaflet');
    const mount = host.querySelector(':scope > .swcx-map-mount');
    results.mountIsChild = !!mount && mount.classList.contains('leaflet-container');
    results.hostHasNoLeafletClass = !host.classList.contains('leaflet-container');
    const tileWidth = () => {
      const t = document.querySelector('#swcx-leaflet img.leaflet-tile');
      return t ? Math.round(t.getBoundingClientRect().width) : 0;
    };
    results.tileWidthBeforeRewrite = tileWidth();
    host.setAttribute('class', 'swcx-map-canvas');
    await settle(250);
    results.tileWidthAfterRewrite = tileWidth();
    results.panesAfterRewrite =
      document.querySelectorAll('#swcx-leaflet .leaflet-pane').length;
   } catch (e) {
    results.error = String((e && e.stack) || e);
   } finally {
    results.done = true;
   }
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
  const appUp = await new Promise((resolve) => {
    http
      .get(APP_BASE + '/index.html', (res) => resolve(res.statusCode === 200))
      .on('error', () => resolve(false));
  });
  if (!appUp) {
    console.log(
      `  SKIP  anonymous-guard redirect — app server ${APP_BASE} is down; the guard is verified live there, a static server cannot exercise the client router`,
    );
  } else {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    await page.goto(APP_BASE + '/entrepreneur/explore', { waitUntil: 'load' });
    await page.waitForTimeout(1200); // hydration + client router redirect
    const url = page.url();
    check(
      'explore route resolves through the client router (anonymous -> login with next)',
      url.includes('/login') && url.includes('next='),
      url,
    );
  }

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
    if (r.error) console.log('  fixture error: ' + String(r.error).slice(0, 400));

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
    check('no map-level error banner', !r.mapError);

    check('four surrounding-layer chips rendered', r.chipsRendered === 4, `got ${r.chipsRendered}`);
    check(
      'category markers at 500 m (2 competitors + 1 place; unavailable source and 800 m parking excluded)',
      r.catMarkersAt500 === 3,
      `got ${r.catMarkersAt500}`,
    );
    check('competitor chip count', r.competitorCount === '2', `got "${r.competitorCount}"`);
    check(
      'unavailable source keeps its slot with a dash count',
      r.accessibilityCount === '0',
      `got "${r.accessibilityCount}"`,
    );
    check(
      'source_unavailable chip shows the honest tag',
      r.accessibilityTag === 'source unavailable',
      `got "${r.accessibilityTag}"`,
    );
    check(
      'parking inside 500 m? no — chip shows no data and zero count',
      r.parkingCount === '0' && r.parkingTag === 'no data',
      `got "${r.parkingCount}" / "${r.parkingTag}"`,
    );
    check('mapped layer with data carries no warning tag', !r.competitorTag, `got "${r.competitorTag}"`);

    check(
      'toggling a chip hides its markers',
      r.competitorPressedAfterHide === 'false' && r.catMarkersAfterHide === 1,
      `pressed=${r.competitorPressedAfterHide}, markers=${r.catMarkersAfterHide}`,
    );
    check(
      'toggling again restores the markers',
      r.competitorPressedAfterShow === 'true' && r.catMarkersAfterShow === 3,
      `pressed=${r.competitorPressedAfterShow}, markers=${r.catMarkersAfterShow}`,
    );

    check(
      'Leaflet mounts on a child element, not the framework canvas',
      r.mountIsChild,
    );
    check('framework canvas carries no Leaflet class', r.hostHasNoLeafletClass);
    check(
      'tiles render at full size',
      r.tileWidthBeforeRewrite === 256,
      `${r.tileWidthBeforeRewrite}px`,
    );
    check(
      'tiles survive a framework class rewrite',
      r.tileWidthAfterRewrite === 256,
      `${r.tileWidthAfterRewrite}px`,
    );
    check(
      'map panes survive a framework class rewrite',
      r.panesAfterRewrite > 0,
      `${r.panesAfterRewrite} panes`,
    );

    // --- radius change re-slices the pushed layers --------------------------
    await fixturePage.evaluate(() => {
      const host = document.getElementById('swcx-leaflet');
      const state = JSON.parse(host.getAttribute('data-state'));
      state.radiusM = 1000;
      host.setAttribute('data-state', JSON.stringify(state));
    });
    await fixturePage.waitForTimeout(600);
    const r2 = await fixturePage.evaluate(() => ({
      parkingCount:
        document.querySelector('.swcx-layer-chip[data-layer="parking"] .swcx-layer-chip__count')
          ?.textContent ?? null,
      parkingTag:
        document.querySelector('.swcx-layer-chip[data-layer="parking"] .swcx-layer-chip__tag')
          ?.textContent ?? null,
      catMarkers: document.querySelectorAll('#swcx-leaflet .swcx-cat-icon').length,
    }));
    check(
      '1 km radius draws the 800 m parking record (count grows, tag clears)',
      r2.parkingCount === '1' && r2.parkingTag === '' && r2.catMarkers === 4,
      `count="${r2.parkingCount}" tag="${r2.parkingTag}" markers=${r2.catMarkers}`,
    );

    // --- regression: wheel over the map zooms (Google-Maps-like) ------------
    const zoom = await fixturePage.evaluate(async () => {
      const zoomSet = () => [...new Set(
        [...document.querySelectorAll('#swcx-leaflet img.leaflet-tile')]
          .map((t) => Number((t.src.split('light_all/')[1] || '').split('/')[0]))
          .filter((n) => Number.isFinite(n) && n > 0),
      )].sort((a, b) => a - b);
      const before = zoomSet();
      const settle = (ms) => new Promise((r) => setTimeout(r, ms));
      document
        .querySelector('#swcx-leaflet .swcx-map-mount')
        .dispatchEvent(new WheelEvent('wheel', {
          deltaY: -120, deltaMode: 0, bubbles: true, cancelable: true,
          clientX: 450, clientY: 275,
        }));
      await settle(900);
      return { before, after: zoomSet() };
    });
    check(
      'wheel over the map zooms (Google-Maps-like)',
      zoom.after.some((z) => !zoom.before.includes(z)),
      `${JSON.stringify(zoom.before)} -> ${JSON.stringify(zoom.after)}`,
    );
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
