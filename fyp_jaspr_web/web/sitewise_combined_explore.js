/*
 * SiteWise Combined Explore map.
 * Property coordinates come only from the existing authenticated FastAPI
 * catalogue, serialized by ExplorePage.dart. No static/Excel data is loaded.
 * Optional transport stops are fetched from OSM Overpass on explicit opt-in.
 */
(() => {
  'use strict';

  const ROOT_ID = 'swcx-leaflet';
  const BRIDGE_ID = 'swcx-selection-bridge';
  const STATUS_ID = 'swcx-transport-status';
  const LIST_ID = 'swcx-transport-results';
  const OVERPASS = 'https://overpass-api.de/api/interpreter';
  const DEFAULT = [3.139, 101.687];
  const OSM_CACHE_TTL = 15 * 60 * 1000;
  const MAX_STOPS = 120;

  let map = null;
  let root = null;
  let markerLayer = null;
  let transportLayer = null;
  let radiusCircle = null;
  let previousState = '';
  let previousCenter = null;
  let viewInitialized = false;
  let pendingFrame = false;
  let transitRequest = null;
  let transitRequestGeneration = 0;
  let displayedTransitKey = null;
  const transitCache = new Map();

  function isValidPoint(obj) {
    if (!obj) return false;
    const lat = Number(obj.lat), lon = Number(obj.lon);
    return Number.isFinite(lat) && Number.isFinite(lon) &&
      Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && !(lat === 0 && lon === 0);
  }
  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>"']/g, ch =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch]);
  }
  function setTransportStatus(text) {
    const el = document.getElementById(STATUS_ID);
    if (el) el.textContent = text;
  }
  function clearTransitList() {
    const el = document.getElementById(LIST_ID);
    if (el) el.replaceChildren();
  }
  function abortTransitRequest() {
    transitRequestGeneration++;
    if (transitRequest) {
      transitRequest.abort();
      transitRequest = null;
    }
  }
  function destroy() {
    abortTransitRequest();
    if (map) { try { map.remove(); } catch (_) { /* detached node */ } }
    map = null;
    root = null;
    markerLayer = null;
    transportLayer = null;
    radiusCircle = null;
    previousState = '';
    previousCenter = null;
    viewInitialized = false;
    displayedTransitKey = null;
  }
  function mapUnavailable(el, message) {
    if (el.querySelector('.swcx-map-error')) return;
    const e = document.createElement('p');
    e.className = 'swcx-map-error';
    e.textContent = message;
    el.appendChild(e);
  }
  function initialize(el) {
    if (typeof window.L === 'undefined') {
      mapUnavailable(el, 'The map library could not load. Property search and listings remain available.');
      return false;
    }
    try {
      map = L.map(el, { zoomControl: true, preferCanvas: true, scrollWheelZoom: false })
        .setView(DEFAULT, 11);
      L.tileLayer('https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png', {
        subdomains: 'abcd', maxZoom: 19,
        attribution: '&copy; OpenStreetMap contributors &copy; CARTO',
      }).addTo(map);
      markerLayer = (typeof L.markerClusterGroup === 'function')
        ? L.markerClusterGroup({ maxClusterRadius: 42, showCoverageOnHover: false })
        : L.layerGroup();
      markerLayer.addTo(map);
      transportLayer = L.layerGroup().addTo(map);
      root = el;
      return true;
    } catch (_) {
      destroy();
      mapUnavailable(el, 'Map tiles or initialization are unavailable. Listings are unaffected.');
      return false;
    }
  }

  function pickProperty(id) {
    if (!root || !root.isConnected) return;
    root.setAttribute('data-choice', String(id));
    const bridge = document.getElementById(BRIDGE_ID);
    if (bridge) bridge.click();
  }

  function metersBetween(a, b) {
    const toRadian = Math.PI / 180;
    const deltaLat = (Number(a.lat) - Number(b.lat)) * toRadian;
    const deltaLon = (Number(a.lon) - Number(b.lon)) * toRadian;
    const h = Math.sin(deltaLat / 2) ** 2 +
      Math.cos(Number(a.lat) * toRadian) * Math.cos(Number(b.lat) * toRadian) *
      Math.sin(deltaLon / 2) ** 2;
    return 2 * 6371008.8 * Math.asin(Math.min(1, Math.sqrt(h)));
  }

  function propertyIcon(selected, nearby) {
    return L.divIcon({
      className: selected ? 'swcx-pin swcx-pin--selected'
        : nearby ? 'swcx-pin swcx-pin--near' : 'swcx-pin swcx-pin--other',
      html: '<span aria-hidden="true"></span>',
      iconSize: selected ? [25, 25] : [19, 19],
      iconAnchor: selected ? [12, 12] : [9, 9],
    });
  }
  function renderProperties(data) {
    const points = Array.isArray(data.properties) ? data.properties.filter(isValidPoint) : [];
    const selectedId = data.selectedId == null ? null : String(data.selectedId);
    const center = points.find(p => String(p.id) === selectedId) || null;
    const radiusM = Number(data.radiusM) === 500 ? 500 : 1000;

    markerLayer.clearLayers();
    if (radiusCircle) {
      map.removeLayer(radiusCircle);
      radiusCircle = null;
    }

    const bounds = [];
    for (const p of points) {
      const selected = String(p.id) === selectedId;
      const marker = L.marker([Number(p.lat), Number(p.lon)], {
        title: String(p.title || p.id),
        icon: propertyIcon(selected, Boolean(p.nearby)),
      });
      marker.bindPopup(`<div class="swcx-popup"><strong>${escapeHtml(p.title || p.id)}</strong>` +
        `<small>${escapeHtml(p.address || '')}</small>` +
        `<small>RM ${Number(p.rentRm || 0).toLocaleString('en-MY')}/month</small>` +
        `<a href="/entrepreneur/property-detail?id=${encodeURIComponent(String(p.id))}">View details</a></div>`);
      marker.on('click', () => pickProperty(p.id));
      markerLayer.addLayer(marker);
      bounds.push([Number(p.lat), Number(p.lon)]);
    }

    if (center) {
      const latlon = [Number(center.lat), Number(center.lon)];
      radiusCircle = L.circle(latlon, {
        radius: radiusM, color: '#1d4ed8', weight: 2,
        fillColor: '#3b82f6', fillOpacity: .08,
        interactive: false,
      }).addTo(map);
      if (selectedId !== previousCenter) {
        map.setView(latlon, 15, { animate: false });
      }
    } else if (!viewInitialized || previousCenter !== null) {
      if (bounds.length > 1) map.fitBounds(bounds, { padding: [25, 25], maxZoom: 12, animate: false });
      else if (bounds.length === 1) map.setView(bounds[0], 14, { animate: false });
      else map.setView(DEFAULT, 10, { animate: false });
    }
    previousCenter = selectedId;
    viewInitialized = true;
    requestAnimationFrame(() => { if (map) map.invalidateSize(); });
    syncTransport(center, radiusM, Boolean(data.showTransport));
  }

  function osmType(tags) {
    if (!tags) return 'Transport stop';
    if (tags.railway === 'station' || tags.railway === 'halt' ||
        tags.station === 'subway' || tags.station === 'light_rail') return 'Rail station';
    if (tags.railway === 'tram_stop') return 'Tram stop';
    if (tags.amenity === 'bus_station') return 'Bus terminal';
    if (tags.highway === 'bus_stop' || tags.bus === 'yes') return 'Bus stop';
    if (tags.public_transport === 'platform') return 'Transport platform';
    if (tags.public_transport === 'station') return 'Transport station';
    return 'Transit point';
  }

  function normaliseStops(data, center, radiusM) {
    const rows = Array.isArray(data?.elements) ? data.elements : [];
    const used = new Set();
    const stops = [];
    for (const row of rows) {
      const lat = row.lat ?? row.center?.lat;
      const lon = row.lon ?? row.center?.lon;
      const point = { lat: Number(lat), lon: Number(lon) };
      if (!isValidPoint(point)) continue;
      const metres = metersBetween(point, center);
      if (metres > radiusM + 5) continue;
      const tags = row.tags || {};
      const name = tags.name || tags['name:en'] || osmType(tags);
      const kind = osmType(tags);
      // Multiple OSM objects can refer to the same physical platform/stop.
      const key = `${name.toLowerCase().trim()}|${Math.round(point.lat * 10000)}|${Math.round(point.lon * 10000)}`;
      if (used.has(key)) continue;
      used.add(key);
      stops.push({ name: String(name), kind, ...point, distanceM: Math.round(metres) });
    }
    stops.sort((a, b) => a.distanceM - b.distanceM);
    return stops.slice(0, MAX_STOPS);
  }

  function overpassQuery(center, radiusM) {
    const lat = Number(center.lat).toFixed(7);
    const lon = Number(center.lon).toFixed(7);
    const around = `(around:${radiusM},${lat},${lon})`;
    return `[out:json][timeout:20];(` +
      `node${around}["highway"="bus_stop"];` +
      `nwr${around}["amenity"="bus_station"];` +
      `nwr${around}["railway"~"^(station|halt|tram_stop)$"];` +
      `nwr${around}["public_transport"~"^(platform|station)$"];` +
      `);out center;`;
  }

  function showStops(stops) {
    if (!transportLayer) return;
    transportLayer.clearLayers();
    clearTransitList();
    const list = document.getElementById(LIST_ID);
    if (!stops.length) {
      setTransportStatus('No transport stops were returned from OpenStreetMap for this radius. Coverage may be incomplete.');
      return;
    }
    for (const item of stops) {
      L.circleMarker([item.lat, item.lon], {
        radius: 6, weight: 2, color: '#fff', fillColor: '#0d9488', fillOpacity: 1,
      }).bindPopup(`<strong>${escapeHtml(item.name)}</strong><br>` +
        `${escapeHtml(item.kind)} · ${item.distanceM} m (straight-line)`)
        .addTo(transportLayer);
    }
    setTransportStatus(`${stops.length} OpenStreetMap transport points plotted in the chosen radius. Not real-time service availability.`);
    if (list) {
      for (const item of stops.slice(0, 6)) {
        const row = document.createElement('div');
        row.className = 'swcx-transport-item';
        const left = document.createElement('span');
        const name = document.createElement('strong');
        name.textContent = item.name;
        const kind = document.createElement('small');
        kind.textContent = item.kind;
        left.append(name, kind);
        const dist = document.createElement('b');
        dist.textContent = `${item.distanceM} m`;
        row.append(left, dist);
        list.appendChild(row);
      }
    }
  }

  async function loadTransport(center, radiusM, key, controller, generation) {
    const timeout = setTimeout(() => controller.abort(), 26000);
    try {
      const response = await fetch(OVERPASS, {
        method: 'POST',
        body: new URLSearchParams({ data: overpassQuery(center, radiusM) }),
        headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
        signal: controller.signal,
      });
      if (!response.ok) throw new Error('Overpass unavailable');
      const data = await response.json();
      if (generation !== transitRequestGeneration || !root?.isConnected) return;
      const stops = normaliseStops(data, center, radiusM);
      if (transitCache.size >= 24) transitCache.delete(transitCache.keys().next().value);
      transitCache.set(key, { timestamp: Date.now(), stops });
      showStops(stops);
    } catch (_) {
      if (generation !== transitRequestGeneration) return;
      transportLayer?.clearLayers();
      clearTransitList();
      setTransportStatus('Transport map data is unavailable right now. Turn the layer off and on to retry; property listings are unaffected.');
    } finally {
      clearTimeout(timeout);
      if (transitRequest === controller) transitRequest = null;
    }
  }

  function syncTransport(center, radiusM, enabled) {
    if (!enabled || !center) {
      abortTransitRequest();
      displayedTransitKey = null;
      transportLayer?.clearLayers();
      clearTransitList();
      setTransportStatus(center
        ? 'Turn on Transport stops to load nearby OpenStreetMap records.'
        : 'Select a property, then turn on Transport stops.');
      return;
    }
    const key = `${Number(center.lat).toFixed(6)}:${Number(center.lon).toFixed(6)}:${radiusM}`;
    if (key === displayedTransitKey) return;
    displayedTransitKey = key;
    abortTransitRequest();
    transportLayer?.clearLayers();
    clearTransitList();
    const cached = transitCache.get(key);
    if (cached && Date.now() - cached.timestamp < OSM_CACHE_TTL) {
      showStops(cached.stops);
      return;
    }
    setTransportStatus('Loading mapped bus stops, rail stations and public transport platforms…');
    const controller = new AbortController();
    transitRequest = controller;
    const generation = transitRequestGeneration;
    void loadTransport(center, radiusM, key, controller, generation);
  }

  function sync() {
    const el = document.getElementById(ROOT_ID);
    if (!el) { if (root) destroy(); return; }
    if (root && root !== el) destroy();
    if (!map && !initialize(el)) return;
    const payload = el.getAttribute('data-state');
    if (!payload || payload === previousState) return;
    previousState = payload;
    try { renderProperties(JSON.parse(payload)); }
    catch (_) { mapUnavailable(el, 'Map data could not be displayed. Property listings remain available.'); }
  }
  function schedule() {
    if (pendingFrame) return;
    pendingFrame = true;
    requestAnimationFrame(() => { pendingFrame = false; sync(); });
  }
  function boot() {
    const observer = new MutationObserver(records => {
      if (records.some(r => r.type === 'childList' ||
          (r.type === 'attributes' && r.attributeName === 'data-state'))) schedule();
    });
    observer.observe(document.documentElement, {
      childList: true, subtree: true, attributes: true, attributeFilter: ['data-state'],
    });
    window.addEventListener('resize', () => { if (map) map.invalidateSize(); });
    schedule();
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else boot();
})();
