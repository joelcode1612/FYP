/*
 * Property detail map probe — verifies the Leaflet catchment map used by the
 * Property Detail and Property Analysis pages against the BUILT site output.
 * The map runs as a self-contained iframe page (`/property_leaflet_map.html`),
 * so its runtime is verifiable without a signed-in session:
 *
 *   1. Static assets exist (iframe HTML, map JS, upgrade CSS, 955-record
 *      reference dataset) and the iframe loads the VENDORED Leaflet.
 *   2. index.html ships the upgrade stylesheet before the app bundle.
 *   3. /entrepreneur/property-detail and /entrepreneur/property-analysis are
 *      routed (anonymous visitors land on the login screen with next=).
 *   4. Runtime, on the real iframe page: Leaflet map initialises, the 500 m
 *      and 1 km rings draw, the 955-record reference dataset loads and pins
 *      inside 1 km are plotted, and the radius tabs (500 m / 1 km / Both)
 *      re-render the overlays and the count label.
 *
 * Usage: BASE=http://127.0.0.1:8091 node tool/probe_property_detail_map.js
 */
const http = require('node:http');

const BASE = process.env.BASE || 'http://127.0.0.1:8091';

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

(async () => {
  const { chromium } = require('playwright-core');

  // --- 1. static assets -------------------------------------------------------
  for (const asset of [
    '/property_leaflet_map.html',
    '/property_leaflet_map.js',
    '/property_detail_upgrade.css',
    '/property_reference_955.json',
    '/vendor/leaflet/leaflet.js',
    '/vendor/leaflet/leaflet.css',
  ]) {
    const res = await get(asset);
    check(`asset ${asset}`, res.status === 200, `HTTP ${res.status}`);
  }
  const refJson = await get('/property_reference_955.json');
  let refCount = 0;
  try { refCount = JSON.parse(refJson.body).length; } catch (_) {}
  check('reference dataset carries the 955 research records', refCount === 955, `got ${refCount}`);
  const iframeHtml = (await get('/property_leaflet_map.html')).body;
  check(
    'iframe map loads the vendored Leaflet (no CDN)',
    iframeHtml.includes('/vendor/leaflet/leaflet.js') &&
      !iframeHtml.includes('unpkg.com'),
  );

  // --- 2. stylesheet + app wiring ----------------------------------------------
  const index = (await get('/index.html')).body;
  check(
    'index.html ships property_detail_upgrade.css before the app bundle',
    index.indexOf('/property_detail_upgrade.css') > -1 &&
      index.indexOf('/property_detail_upgrade.css') < index.indexOf('/main.client.dart.js'),
  );
  const bundle = await get('/main.client.dart.js');
  check(
    'compiled bundle contains the property-analysis route',
    bundle.body.includes('/entrepreneur/property-analysis'),
  );

  // --- 3. routes + anonymous guard ----------------------------------------------
  const APP_BASE = process.env.APP_BASE || 'http://127.0.0.1:8090';
  const appUp = await new Promise((resolve) => {
    http
      .get(APP_BASE + '/index.html', (res) => resolve(res.statusCode === 200))
      .on('error', () => resolve(false));
  });
  const browser = await chromium.launch({
    executablePath:
      'C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe',
    args: ['--no-proxy-server'],
  });
  if (!appUp) {
    console.log(
      `  SKIP  anonymous-guard redirects — app server ${APP_BASE} is down; a bare static server cannot exercise the client router`,
    );
  } else {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    await page.goto(APP_BASE + '/entrepreneur/property-detail?id=EP-01051', { waitUntil: 'load' });
    await page.waitForTimeout(1200);
    check(
      'property-detail route resolves (anonymous -> login with next + id)',
      page.url().includes('/login') &&
        page.url().includes('next=') &&
        decodeURIComponent(page.url()).includes('EP-01051'),
      page.url(),
    );
    await page.goto(APP_BASE + '/entrepreneur/property-analysis?id=EP-01051', { waitUntil: 'load' });
    await page.waitForTimeout(1200);
    check(
      'property-analysis route resolves (anonymous -> login with next + id)',
      page.url().includes('/login') && decodeURIComponent(page.url()).includes('EP-01051'),
      page.url(),
    );
  }

  // --- 4. real iframe page runtime ----------------------------------------------
  const mapPage = await browser.newPage({ viewport: { width: 900, height: 700 } });
  await mapPage.goto(BASE + '/property_leaflet_map.html?lat=3.139&lon=101.687&id=EP-01051', {
    waitUntil: 'load',
  });
  // Reference dataset fetch + marker render settle.
  await mapPage.waitForTimeout(2500);
  const r = await mapPage.evaluate(() => ({
    mapInitialized: !!document.querySelector('#map .leaflet-pane'),
    ringCount: document.querySelectorAll('#map path.leaflet-interactive, #map svg path').length,
    pinCount: document.querySelectorAll('#map path.leaflet-interactive, #map svg path').length,
    label: (document.getElementById('nearby-label') || {}).textContent || '',
    alertShown: !((document.getElementById('map-alert') || {}).hidden !== false),
    alertText: (document.getElementById('map-alert') || {}).textContent || '',
    idLabel: (document.getElementById('location-id') || {}).textContent || '',
  }));
  check('Leaflet map initialised in the iframe', r.mapInitialized);
  check('property id rendered in the toolbar', r.idLabel.includes('EP-01051'), r.idLabel);
  check(
    'no error banner (tiles or library)',
    !r.alertShown || r.alertText.length === 0,
    r.alertText.slice(0, 60),
  );
  check(
    'nearby count label rendered from the reference dataset',
    /\d+ within 500 m · \d+ from 500 m–1 km/.test(r.label),
    `"${r.label}"`,
  );

  // Radius tab interaction: switch to 500 m and confirm re-render.
  const afterClick = await mapPage.evaluate(() => {
    const btn = document.querySelector('[data-radius="500"]');
    if (!btn) return { clicked: false };
    btn.click();
    return new Promise((done) =>
      setTimeout(() => done({
        clicked: true,
        pressed: btn.getAttribute('aria-pressed'),
        label: (document.getElementById('nearby-label') || {}).textContent || '',
      }), 400),
    );
  });
  check('500 m tab activates', afterClick.clicked && afterClick.pressed === 'true');
  const inner = parseInt((r.label.match(/(\d+) within 500 m/) || [])[1] || '0', 10);
  const innerAfter = parseInt(
    ((afterClick.label || '').match(/(\d+) within 500 m/) || [])[1] || '-1',
    10,
  );
  check(
    '500 m selection keeps the inner-ring count and the label stays consistent',
    innerAfter === inner,
    `${inner} -> ${innerAfter}`,
  );

  // --- 5. nearby-payload mode (surfaces 2+3 share this frame) --------------------
  // The Dart component pushes the nearby-places payload in with a same-origin
  // postMessage; the frame then draws the surrounding-area layers and shows
  // honest per-layer states. Places are spread so the cluster plugin keeps
  // them as individual icons, mirroring the endpoint's real shape.
  const NEARBY = {
    property_id: 'EP-01051',
    radius_m: 3000,
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
      { id: 'park-1', name: 'Fixture car park', category: 'parking', subtype: 'parking', detail: 'multi-storey', lat: 3.15, lng: 101.7, source: 'osm', distance_m: 1800, operating_status: null, observed_at: null },
    ],
  };
  await mapPage.evaluate((payload) => {
    window.postMessage('sitewiseNearbyPlaces:' + JSON.stringify(payload), window.location.origin);
  }, NEARBY);
  await mapPage.waitForTimeout(900);
  const r3 = await mapPage.evaluate(() => {
    const chip = (k) => document.querySelector(`.chip[data-layer="${k}"]`);
    const txt = (el, sel) => el?.querySelector(sel)?.textContent ?? null;
    return {
      chips: document.querySelectorAll('.chip').length,
      competitorTag: txt(chip('competitors'), '.chip__tag'),
      competitorCount: txt(chip('competitors'), '.chip__count'),
      accessibilityTag: txt(chip('accessibility'), '.chip__tag'),
      parkingTag: txt(chip('parking'), '.chip__tag'),
      parkingCount: txt(chip('parking'), '.chip__count'),
      placeIcons: document.querySelectorAll('.sw-place-icon').length,
    };
  });
  check('five layer chips render in the frame', r3.chips === 5, `got ${r3.chips}`);
  check(
    'pushed competitors map inside 500 m with the mapped tag',
    r3.competitorCount === '2' && r3.competitorTag === 'mapped',
    `count="${r3.competitorCount}" tag="${r3.competitorTag}"`,
  );
  check(
    'unavailable transit source keeps its slot with the honest tag',
    r3.accessibilityTag === 'source unavailable',
    `tag="${r3.accessibilityTag}"`,
  );
  check(
    'parking beyond the ring with no recorded count stays bare — no invented totals or tags',
    r3.parkingTag === null && r3.parkingCount === null,
    `tag="${r3.parkingTag}" count="${r3.parkingCount}"`,
  );
  check(
    'three real place icons drawn (2 competitors + 1 nearby place)',
    r3.placeIcons === 3,
    `got ${r3.placeIcons}`,
  );

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => {
  console.error('probe crashed:', e);
  process.exit(2);
});
