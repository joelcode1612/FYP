/*
 * SiteWise Combined Explore map.
 * Property coordinates come only from the existing authenticated FastAPI
 * catalogue, serialized by ExplorePage.dart. No static/Excel data is loaded.
 *
 * The four surrounding-area layers (Food Businesses, Nearby Places, Transport,
 * Parking) are the backend's nearby-places payload — the same authenticated
 * endpoint the property detail map uses — pushed by Dart through the
 * `data-nearby` attribute. No client-side Overpass fetch: every record comes
 * from its verified source table (fnb_outlet, pois_master, gtfs_stops,
 * psense_parking), and the chips carry the same honest states the detail map
 * reports (mapped / no data / source unavailable / may be out of date).
 */
(() => {
  'use strict';

  const ROOT_ID = 'swcx-leaflet';
  const BRIDGE_ID = 'swcx-selection-bridge';
  const DEFAULT = [3.139, 101.687];

  // Same category palette and letters as the property-detail map frame, so
  // both surfaces read as one product.
  const NEARBY_LAYERS = [
    { k: 'competitors', l: 'Food Businesses', c: '#d97706', g: 'F' },
    { k: 'demand_generators', l: 'Nearby Places', c: '#0f9d86', g: 'R' },
    { k: 'accessibility', l: 'Transport', c: '#7c3aed', g: 'T' },
    { k: 'parking', l: 'Parking', c: '#475569', g: 'P' }
  ];
  const STATUS_TEXT = {
    likely_open: 'Operating status: likely open',
    possibly_closed: 'Operating status: possibly closed',
    unknown: 'Operating status unverified'
  };
  const SOURCE_TEXT = {
    osm: 'OpenStreetMap-derived, deduplicated for this analysis',
    gtfs: 'official GTFS transit feed',
    catalogue: 'research property catalogue'
  };

  let map = null;
  let root = null;
  let markerLayer = null;
  const propertyMarkers = new Map(); // cached by stable catalogue ID
  let radiusCircle = null;
  let previousState = '';
  let previousNearby = '';
  let previousCenter = null;
  let viewInitialized = false;
  let pendingFrame = false;

  // Nearby-places state: the pushed payload plus the render context it must
  // be drawn against. Layer groups are created lazily per category so
  // toggling one layer never disturbs the others' clusters.
  let nearbyPayload = null;
  let lastRender = null; // { selectedId, radiusM }
  const nearbyGroups = new Map();
  const activeNearby = new Set(NEARBY_LAYERS.map(x => x.k));

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
  function destroy() {
    if (map) { try { map.remove(); } catch (_) { /* detached node */ } }
    // The panes live inside the mount element, which this script owns.
    const mount = root ? root.querySelector(':scope > .swcx-map-mount') : null;
    if (mount) mount.remove();
    map = null;
    root = null;
    markerLayer = null;
    propertyMarkers.clear();
    radiusCircle = null;
    previousState = '';
    previousNearby = '';
    previousCenter = null;
    viewInitialized = false;
    nearbyPayload = null;
    lastRender = null;
    nearbyGroups.clear();
  }
  function mapUnavailable(el, message) {
    if (el.querySelector('.swcx-map-error')) return;
    const e = document.createElement('p');
    e.className = 'swcx-map-error';
    e.textContent = message;
    el.appendChild(e);
  }
  // Leaflet must not mount on the framework-rendered element. The page is a
  // Jaspr client component, and every re-render rewrites the `class` attribute
  // of the elements it owns. That strips the `leaflet-container` class Leaflet
  // adds at init; without it the app-wide `img { max-width: 100% }` rule
  // (styles.css) collapses each tile to 0px width and the basemap disappears
  // while the markers keep painting. Mounting on a child the framework never
  // renders keeps Leaflet's classes, its clipping and its tile sizing intact
  // across re-renders.
  function mountFor(host) {
    let mount = host.querySelector(':scope > .swcx-map-mount');
    if (!mount) {
      mount = document.createElement('div');
      mount.className = 'swcx-map-mount';
      host.appendChild(mount);
    }
    return mount;
  }
  function initialize(el) {
    if (typeof window.L === 'undefined') {
      mapUnavailable(el, 'The map library could not load. Property search and listings remain available.');
      return false;
    }
    const cartoKey = window.SITEWISE_MAP_CONFIG?.cartoBasemapsKey;
    if (!cartoKey) {
      mapUnavailable(el, 'CARTO basemap key missing. Generate map-config.js and rebuild SiteWise.');
      return false;
    }
    try {
      map = L.map(mountFor(el), {
        zoomControl: true,
        preferCanvas: true,
        // Google-Maps-like wheel behaviour: the pointer is the zoom anchor and
        // one wheel notch advances one level. 100px per level damps trackpad
        // bursts without making a mouse wheel feel unresponsive.
        scrollWheelZoom: true,
        wheelDebounceTime: 40,
        wheelPxPerZoomLevel: 100,
      }).setView(DEFAULT, 11);
      L.tileLayer('https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png?key=' + encodeURIComponent(cartoKey), {
        subdomains: 'abcd', maxZoom: 19,
        attribution: '&copy; OpenStreetMap contributors &copy; CARTO',
      }).on('tileerror', () => {
        mapUnavailable(el, 'CARTO tiles could not load. Check key restrictions and network requests.');
      }).addTo(map);
      markerLayer = (typeof L.markerClusterGroup === 'function')
        ? L.markerClusterGroup({ maxClusterRadius: 42, showCoverageOnHover: false })
        : L.layerGroup();
      markerLayer.addTo(map);
      root = el;
      buildLayerChips(mountFor(el));
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

  // -- surrounding-area layers ----------------------------------------------

  function nearbyGroup(key) {
    if (!nearbyGroups.has(key)) {
      const group = (typeof L.markerClusterGroup === 'function')
        ? L.markerClusterGroup({ maxClusterRadius: 42, showCoverageOnHover: false })
        : L.layerGroup();
      nearbyGroups.set(key, group);
    }
    return nearbyGroups.get(key);
  }

  function categoryMeta(key) {
    return nearbyPayload?.categories?.[key] || null;
  }

  function mappedCount(key, radiusM) {
    if (!nearbyPayload || !Array.isArray(nearbyPayload.places)) return 0;
    return nearbyPayload.places.reduce(
      (n, p) => (p && p.category === key &&
        typeof p.distance_m === 'number' && p.distance_m <= radiusM ? n + 1 : n), 0);
  }

  function subtypeLabel(place) {
    const s = String(place.subtype || '').trim();
    if (!s) return '';
    return s.replace(/[_/]+/g, ' ').trim().replace(/\b\w/g, ch => ch.toUpperCase());
  }

  function placePopup(place) {
    const content = document.createElement('div');
    content.className = 'swcx-popup';
    const name = document.createElement('strong');
    name.textContent = place.name || 'Unnamed place';
    content.append(name);
    const kind = String(place.detail || '').trim();
    const label = subtypeLabel(place);
    if (kind && kind !== place.subtype) {
      const d = document.createElement('small');
      d.textContent = label ? `${label} · ${kind}` : kind;
      content.append(d);
    } else if (label) {
      const d = document.createElement('small');
      d.textContent = label;
      content.append(d);
    }
    if (typeof place.distance_m === 'number') {
      const d = document.createElement('small');
      d.textContent = `~${place.distance_m} m straight line`;
      content.append(d);
    }
    if (place.operating_status && STATUS_TEXT[place.operating_status]) {
      const d = document.createElement('small');
      d.textContent = STATUS_TEXT[place.operating_status];
      content.append(d);
    }
    const bits = [];
    if (place.source) bits.push(SOURCE_TEXT[place.source] || String(place.source));
    if (place.observed_at) bits.push(`observed ${String(place.observed_at).slice(0, 10)}`);
    if (place.source === 'gtfs' && place.detail) {
      // GTFS rows carry routes + scheduled departures as their detail line;
      // these are the published timetable, never live arrivals.
      bits.unshift(String(place.detail));
    }
    if (bits.length) {
      const d = document.createElement('small');
      d.textContent = bits.join(' · ');
      content.append(d);
    }
    return content;
  }

  function drawNearby() {
    const radiusM = lastRender?.radiusM ?? 1000;
    for (const layer of NEARBY_LAYERS) {
      const group = nearbyGroup(layer.k);
      group.clearLayers();
      if (map.hasLayer(group)) map.removeLayer(group);
      if (!nearbyPayload || !activeNearby.has(layer.k)) continue;
      const places = Array.isArray(nearbyPayload.places) ? nearbyPayload.places : [];
      let count = 0;
      for (const p of places) {
        if (!p || p.category !== layer.k) continue;
        if (typeof p.distance_m !== 'number' || p.distance_m > radiusM) continue;
        if (!isValidPoint({ lat: p.lat, lon: p.lng })) continue;
        const marker = L.marker([p.lat, p.lng], {
          title: `${layer.l} — ${p.name || 'Unnamed place'}`,
          icon: L.divIcon({
            className: 'swcx-cat-icon',
            html: `<span style="background:${layer.c}" aria-hidden="true">${layer.g}</span>`,
            iconSize: [18, 18],
            iconAnchor: [9, 9],
          }),
        });
        marker.bindPopup(placePopup(p));
        group.addLayer(marker);
        count++;
      }
      if (count > 0) group.addTo(map);
    }
    updateLayerChips(radiusM);
  }

  function buildLayerChips(mount) {
    let bar = mount.querySelector(':scope > .swcx-layers');
    if (!bar) {
      bar = document.createElement('div');
      bar.className = 'swcx-layers';
      const label = document.createElement('span');
      label.className = 'swcx-layers__label';
      label.textContent = 'Surrounding layers';
      bar.append(label);
      for (const layer of NEARBY_LAYERS) {
        const chip = document.createElement('button');
        chip.type = 'button';
        chip.className = 'swcx-layer-chip';
        chip.dataset.layer = layer.k;
        chip.setAttribute('aria-pressed', 'true');
        const dot = document.createElement('span');
        dot.className = 'swcx-layer-chip__dot';
        dot.style.background = layer.c;
        const name = document.createElement('span');
        name.className = 'swcx-layer-chip__name';
        name.textContent = layer.l;
        const count = document.createElement('span');
        count.className = 'swcx-layer-chip__count';
        const tag = document.createElement('span');
        tag.className = 'swcx-layer-chip__tag';
        chip.append(dot, name, count, tag);
        chip.addEventListener('click', () => {
          if (activeNearby.has(layer.k)) activeNearby.delete(layer.k);
          else activeNearby.add(layer.k);
          chip.setAttribute('aria-pressed', String(activeNearby.has(layer.k)));
          drawNearby();
        });
        bar.append(chip);
      }
      mount.append(bar);
    }
    updateLayerChips(lastRender?.radiusM ?? 1000);
  }

  function updateLayerChips(radiusM) {
    if (!root) return;
    const mount = root.querySelector(':scope > .swcx-map-mount');
    if (!mount) return;
    const hasCenter = Boolean(lastRender?.selectedId);
    for (const layer of NEARBY_LAYERS) {
      const chip = mount.querySelector(`.swcx-layer-chip[data-layer="${layer.k}"]`);
      if (!chip) continue;
      const count = chip.querySelector('.swcx-layer-chip__count');
      const tag = chip.querySelector('.swcx-layer-chip__tag');
      const meta = categoryMeta(layer.k);
      const state = meta ? meta.state : null;
      const mapped = mappedCount(layer.k, radiusM);
      count.textContent = !hasCenter
        ? ''
        : nearbyPayload ? String(mapped) : '–';
      tag.textContent = '';
      if (!hasCenter) {
        chip.title = 'Select a property to load its surrounding records';
      } else if (state === 'source_unavailable') {
        tag.textContent = 'source unavailable';
        chip.title = 'This source could not be read just now; other layers are unaffected.';
      } else if (state === 'data_stale') {
        tag.textContent = 'may be out of date';
        chip.title = 'The official GTFS feeds on this host are past their refresh window; markers may not reflect current timetables.';
      } else if (nearbyPayload && mapped === 0) {
        tag.textContent = 'no data';
        chip.title = `No verified ${layer.l.toLowerCase()} within ${radiusM} m of the selected property.`;
      } else if (nearbyPayload && meta?.truncated) {
        tag.textContent = 'nearest only';
        chip.title = 'Large catchment: only the nearest locations per layer are drawn.';
      } else {
        chip.title = `${layer.l} recorded around the selected property (straight-line distances).`;
      }
    }
  }

  function applyNearby(raw) {
    if (!raw) {
      nearbyPayload = null;
      drawNearby();
      return;
    }
    try {
      const parsed = JSON.parse(raw);
      nearbyPayload = parsed && typeof parsed === 'object' ? parsed : null;
    } catch (_) {
      // A malformed push is ignored; the previous state stays honest.
      return;
    }
    drawNearby();
  }

  function renderProperties(data) {
    const points = Array.isArray(data.properties) ? data.properties.filter(isValidPoint) : [];
    const selectedId = data.selectedId == null ? null : String(data.selectedId);
    const center = points.find(p => String(p.id) === selectedId) || null;
    const radiusM = Number(data.radiusM) === 500 ? 500 : 1000;

    // Diff by ID: UI updates must not destroy and reconstruct all markers.
    if (radiusCircle) {
      map.removeLayer(radiusCircle);
      radiusCircle = null;
    }

    const activeIds = new Set();
    const bounds = [];
    for (const p of points) {
      const id = String(p.id);
      const selected = id === selectedId;
      const nearby = Boolean(p.nearby);
      const state = selected ? 'selected' : nearby ? 'near' : 'other';
      const signature = JSON.stringify([
        Number(p.lat), Number(p.lon), p.title, p.address, p.rentRm,
      ]);
      activeIds.add(id);
      let entry = propertyMarkers.get(id);

      if (!entry || entry.signature !== signature) {
        if (entry) markerLayer.removeLayer(entry.marker);
        const marker = L.marker([Number(p.lat), Number(p.lon)], {
          title: String(p.title || p.id),
          icon: propertyIcon(selected, nearby),
        });
        marker.bindPopup('<div class="swcx-popup"><strong>' +
          escapeHtml(p.title || p.id) + '</strong>' +
          '<small>' + escapeHtml(p.address || '') + '</small>' +
          '<small>RM ' + Number(p.rentRm || 0).toLocaleString('en-MY') +
          '/month</small>' +
          '<a href="/entrepreneur/property-detail?id=' +
          encodeURIComponent(id) + '">View details</a></div>');
        marker.on('click', () => pickProperty(id));
        markerLayer.addLayer(marker);
        entry = { marker, signature, state };
        propertyMarkers.set(id, entry);
      } else if (entry.state !== state) {
        entry.marker.setIcon(propertyIcon(selected, nearby));
        entry.state = state;
      }
      bounds.push([Number(p.lat), Number(p.lon)]);
    }

    // Remove only the markers excluded by current search/filter criteria.
    for (const [id, entry] of propertyMarkers) {
      if (!activeIds.has(id)) {
        markerLayer.removeLayer(entry.marker);
        propertyMarkers.delete(id);
      }
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
    lastRender = { selectedId, radiusM };
    drawNearby();
  }

  function sync() {
    const el = document.getElementById(ROOT_ID);
    if (!el) { if (root) destroy(); return; }
    if (root && root !== el) destroy();
    if (!map && !initialize(el)) return;
    const nearby = el.getAttribute('data-nearby') || '';
    if (nearby !== previousNearby) {
      previousNearby = nearby;
      applyNearby(nearby || null);
    }
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
          (r.type === 'attributes' &&
            (r.attributeName === 'data-state' || r.attributeName === 'data-nearby')))) schedule();
    });
    observer.observe(document.documentElement, {
      childList: true, subtree: true, attributes: true,
      attributeFilter: ['data-state', 'data-nearby'],
    });
    window.addEventListener('resize', () => { if (map) map.invalidateSize(); });
    schedule();
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else boot();
})();
