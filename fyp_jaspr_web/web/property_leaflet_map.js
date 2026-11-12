/* First-party reusable map for the SiteWise property detail and analysis pages.
 * Leaflet + CARTO Voyager / OpenStreetMap. Reference markers are research
 * rental properties (U), NOT F&B competitors. Not a road-network catchment.
 *
 * Two radius modes, chosen by the ?radius query parameter:
 *   legacy (no radius)   — 500 m + 1 km shown together, "Both" default. The
 *                          property-detail behaviour, unchanged.
 *   single (?radius=NNN) — one selectable straight-line radius among
 *                          500 / 1000 / 2000 / 3000 m. The Full Analysis page.
 * The circles are straight-line buffers, never travel-time or road-network
 * catchments, and no walking time is ever derived from them.
 *
 * Five layers are offered: Properties, Food Businesses, Nearby Places,
 * Transport, Parking. The page passes their data as a compact JSON array in
 * the ?layers parameter. Each entry carries `m` — whether the layer has stored
 * coordinates. Only a mapped layer can be drawn as pins: the other four exist
 * in this deployment as counts-within-a-radius on the property's feature
 * vector, so they are reported as numbers with an explicit "counts only" tag
 * rather than positioned markers the data cannot justify.
 */
(() => {
  'use strict';
  const q = new URLSearchParams(window.location.search);
  const lat = Number(q.get('lat'));
  const lon = Number(q.get('lon'));
  const propertyId = q.get('id') || 'Selected property';
  const alertEl = document.getElementById('map-alert');
  const nearbyLabel = document.getElementById('nearby-label');
  const tabsEl = document.getElementById('radius-tabs');
  const legendEl = document.getElementById('map-legend');
  const layersEl = document.getElementById('layer-toggles');
  const recenterBtn = document.getElementById('recenter');
  const fullscreenBtn = document.getElementById('fullscreen');
  const showAlert = message => { alertEl.textContent = message; alertEl.hidden = false; };
  // Two independent notices share one bar: a tile failure must not erase the
  // explanation of why a layer has no pins, and vice versa.
  const notices = { layers: '', tiles: '' };
  const paintNotice = () => {
    const parts = [notices.layers, notices.tiles].filter(Boolean);
    alertEl.textContent = parts.join(' ');
    alertEl.hidden = parts.length === 0;
  };
  const clearAlert = () => { alertEl.hidden = true; alertEl.textContent = ''; };
  const valid = Number.isFinite(lat) && Number.isFinite(lon) &&
    lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180 &&
    !(lat === 0 && lon === 0);
  if (!valid || typeof L === 'undefined') {
    showAlert(valid ? 'The map could not open. Please refresh this page.' : 'The map location is not available for this property.');
    nearbyLabel.textContent = 'Map unavailable';
    return;
  }
  const cartoKey = window.SITEWISE_MAP_CONFIG?.cartoBasemapsKey;
  if (!cartoKey) {
    showAlert('The map is unavailable right now. Please try again later.');
    nearbyLabel.textContent = 'Map unavailable';
    return;
  }
  document.getElementById('location-id').textContent = ` · ${propertyId}`;

  // -- layers ---------------------------------------------------------------
  // Fallback mirrors the backend's five layers so the control still renders
  // when the page has no insights payload (for example, an unscored listing).
  const DEFAULT_LAYERS = [
    { k: 'properties', l: 'Properties', c: '#1d4ed8', m: true },
    { k: 'competitors', l: 'Food Businesses', c: '#d97706', m: false },
    { k: 'demand_generators', l: 'Nearby Places', c: '#0f9d86', m: false },
    { k: 'accessibility', l: 'Transport', c: '#7c3aed', m: false },
    { k: 'parking', l: 'Parking', c: '#475569', m: false }
  ];
  let layers = DEFAULT_LAYERS;
  try {
    const parsed = JSON.parse(q.get('layers') || 'null');
    if (Array.isArray(parsed) && parsed.length) {
      layers = parsed
        .filter(x => x && typeof x.k === 'string')
        .map(x => ({
          k: x.k,
          l: typeof x.l === 'string' ? x.l : x.k,
          c: typeof x.c === 'string' ? x.c : '#1d4ed8',
          m: x.m === true,
          a: typeof x.a === 'number' ? x.a : null,
          b: typeof x.b === 'number' ? x.b : null,
          n: typeof x.n === 'number' ? x.n : null
        }));
    }
  } catch (err) {
    layers = DEFAULT_LAYERS;
  }
  const active = new Set(layers.map(x => x.k));

  // -- radius mode ----------------------------------------------------------
  const singleRadii = ['500', '1000', '2000', '3000'];
  const requested = q.get('radius');
  const single = requested !== null && singleRadii.includes(requested);
  const choices = single ? singleRadii : ['500', '1000', 'both'];
  const labelFor = { '500': '500 m', '1000': '1 km', '2000': '2 km', '3000': '3 km', 'both': 'Both' };
  let radius = single ? requested : 'both';
  // Reference markers are kept up to the largest radius this mode can show, so
  // selecting a bigger circle reveals more of them rather than empty space.
  const maxDisplayM = single ? 3000 : 1000;
  const zoomFor = { '500': 15, '1000': 14, '2000': 13, '3000': 12, 'both': 14.5 };

  const map = L.map('map', { zoomControl: true, preferCanvas: true, minZoom: 5, maxZoom: 19 });
  const tile = L.tileLayer('https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png?key=' + encodeURIComponent(cartoKey), {
    maxZoom: 20,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a> contributors &copy; <a href="https://carto.com/" target="_blank" rel="noopener">CARTO</a>'
  }).addTo(map);
  let tileErrors = 0;
  tile.on('tileerror', () => {
    if (++tileErrors < 3) return;
    notices.tiles = 'The map background could not load. Some location markers may still appear.';
    paintNotice();
  });
  const origin = [lat, lon];
  map.setView(origin, zoomFor[radius] ?? 14.5);

  // The selected property is the subject of the page, so it is drawn larger
  // than any reference marker and is never clustered.
  const selectedPopup = () => {
    const el = document.createElement('div');
    const strong = document.createElement('strong');
    strong.textContent = 'Selected property';
    const name = document.createElement('div');
    name.textContent = propertyId;
    const note = document.createElement('div');
    note.textContent = 'You are viewing this property.';
    el.append(strong, name, note);
    return el;
  };
  L.circleMarker(origin, { radius: 11, color: '#fff', weight: 3, fillColor: '#1d4ed8', fillOpacity: 1 })
    .addTo(map)
    .bindPopup(selectedPopup());

  const rings = L.layerGroup().addTo(map);
  const markers = (typeof L.markerClusterGroup === 'function')
    ? L.markerClusterGroup({ chunkedLoading: true, maxClusterRadius: 50, disableClusteringAtZoom: 17 })
    : L.layerGroup();
  markers.addTo(map);

  let nearby = [];
  const meters = (a, b) => {
    const toR = Math.PI / 180;
    const dLat = (b.lat - a.lat) * toR, dLon = (b.lon - a.lon) * toR;
    const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * toR) * Math.cos(b.lat * toR) * Math.sin(dLon / 2) ** 2;
    return 2 * 6371008.8 * Math.atan2(Math.sqrt(h), Math.sqrt(Math.max(0, 1 - h)));
  };

  const addReferenceMarker = entry => {
    // Legacy "Both" distinguishes the 500 m ring from the 1 km ring by colour.
    // In single-radius mode every marker already lies inside the one selected
    // circle, so a fixed 500 m split would read as a second, unlabelled band.
    const isClose = !single || entry.dist <= 500;
    const marker = L.circleMarker([entry.lat, entry.lon], {
      radius: 5.5, weight: 1.5, color: '#fff', fillOpacity: .9,
      fillColor: isClose ? '#0f9d86' : '#8a6bc7'
    });
    const content = document.createElement('div');
    const name = document.createElement('strong'); name.textContent = entry.id;
    const title = document.createElement('div'); title.textContent = entry.title;
    const distance = document.createElement('div'); distance.textContent = `${Math.round(entry.dist)} m away · research reference property`;
    content.append(name, title, distance);
    marker.bindPopup(content);
    markers.addLayer(marker);
  };

  // A permanent label on the ring itself, so the circle is readable without a
  // legend lookup. It sits due east of the centre rather than due north: the
  // northern edge of the outer ring is frequently clipped by the toolbar, which
  // hid the label entirely at the default zoom.
  const pointOnRing = (radiusM, bearingDeg) => {
    const R = 6371008.8;
    const br = (bearingDeg * Math.PI) / 180;
    const latR = (lat * Math.PI) / 180;
    const dLat = (radiusM * Math.cos(br)) / R;
    const dLon = (radiusM * Math.sin(br)) / (R * Math.cos(latR));
    return [lat + (dLat * 180) / Math.PI, lon + (dLon * 180) / Math.PI];
  };
  const addRingLabel = (radiusM, text, color) => {
    const marker = L.marker(pointOnRing(radiusM, 90), {
      interactive: false,
      keyboard: false,
      icon: L.divIcon({
        className: 'sw-ring-label',
        html: `<span style="background:${color}">${text}</span>`,
        iconSize: [0, 0]
      })
    });
    marker.addTo(rings);
  };

  const radiusMeters = () => (single ? Number(radius) : radius === '500' ? 500 : 1000);

  const renderRings = () => {
    rings.clearLayers();
    if (single) {
      const rM = Number(radius);
      L.circle(origin, { radius: rM, color: '#1d4ed8', weight: 2, fillColor: '#1d4ed8', fillOpacity: .06, interactive: false }).addTo(rings);
      addRingLabel(rM, labelFor[radius], '#1d4ed8');
      return;
    }
    if (radius !== '500') {
      L.circle(origin, { radius: 1000, color: '#8a6bc7', weight: 2, fillColor: '#8a6bc7', fillOpacity: .07, dashArray: '6 5', interactive: false }).addTo(rings);
      addRingLabel(1000, '1 km', '#8a6bc7');
    }
    if (radius !== '1000') {
      L.circle(origin, { radius: 500, color: '#0f9d86', weight: 2, fillColor: '#0f9d86', fillOpacity: .09, interactive: false }).addTo(rings);
      addRingLabel(500, '500 m', '#0f9d86');
    }
  };

  const renderLegend = () => {
    legendEl.innerHTML = '';
    const key = (color, text) => {
      const k = document.createElement('span');
      k.className = 'key';
      k.style.background = color;
      legendEl.append(k, document.createTextNode(` ${text} `));
    };
    key('#1d4ed8', 'Selected property');
    if (active.has('properties')) {
      key('#0f9d86', 'Within 500 m');
      key('#8a6bc7', '500 m–1 km');
    }
    for (const layer of layers) {
      if (layer.k === 'properties' || !active.has(layer.k)) continue;
      const text = layer.m
        ? layer.l
        : `${layer.l} (${countText(layer)})`;
      key(layer.c, text);
    }
  };

  const countText = layer => {
    const parts = [];
    if (typeof layer.a === 'number') parts.push(`${layer.a} within 500 m`);
    if (typeof layer.b === 'number') parts.push(`${layer.b} within 1 km`);
    return parts.length ? parts.join(' · ') : 'No information available';
  };

  const renderNotice = () => {
    // Tile failures have their own slot; this line is only about layers.
    const unmapped = layers.filter(x => active.has(x.k) && !x.m);
    if (!unmapped.length) {
      notices.layers = '';
      return paintNotice();
    }
    const names = unmapped.map(x => x.l);
    const listed = names.length === 1
      ? names[0]
      : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
    notices.layers =
      `For ${listed}, we have nearby totals but not exact map locations. ` +
      'See the numbers in the map key below.';
    paintNotice();
  };

  const render = () => {
    renderRings();
    markers.clearLayers();
    const limit = radiusMeters();
    const visible = nearby.filter(x => x.dist <= limit + 1e-6);
    if (active.has('properties')) {
      for (const entry of visible) addReferenceMarker(entry);
    }
    renderLegend();
    renderNotice();

    const shown = active.has('properties') ? visible.length : 0;
    if (!active.has('properties')) {
      nearbyLabel.textContent = 'Turn on Properties to see nearby property locations';
    } else if (single) {
      nearbyLabel.textContent = `${shown} other property locations within ${labelFor[radius]} · availability not confirmed`;
    } else {
      const inner = visible.filter(x => x.dist <= 500).length;
      nearbyLabel.textContent = `${inner} within 500 m · ${visible.length - inner} from 500 m–1 km`;
    }

    // The Properties chip shows the count the map actually drew, which is the
    // only place that number can come from — the backend does not store it.
    const badge = layersEl.querySelector('[data-count="properties"]');
    if (badge) badge.textContent = active.has('properties') ? String(shown) : '';
  };

  // -- controls -------------------------------------------------------------
  const buildChips = () => {
    layersEl.innerHTML = '';
    const label = document.createElement('span');
    label.className = 'layers__label';
    label.textContent = 'Show on map';
    layersEl.append(label);

    for (const layer of layers) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'chip';
      b.dataset.layer = layer.k;
      b.dataset.mapped = String(layer.m);
      b.setAttribute('aria-pressed', String(active.has(layer.k)));

      const dot = document.createElement('span');
      dot.className = 'chip__dot';
      dot.style.background = layer.c;
      const name = document.createElement('span');
      name.textContent = layer.l;
      b.append(dot, name);

      if (layer.k === 'properties') {
        const count = document.createElement('span');
        count.className = 'chip__count';
        count.dataset.count = 'properties';
        b.append(count);
      } else {
        // The chip badge follows the selected radius; the legend always shows
        // both totals.
        const c = radius === '1000' ? layer.b : layer.a;
        if (typeof c === 'number') {
          const count = document.createElement('span');
          count.className = 'chip__count';
          count.textContent = String(c);
          b.append(count);
        }
        if (!layer.m) {
          const tag = document.createElement('span');
          tag.className = 'chip__tag';
          tag.textContent = 'totals only';
          b.append(tag);
        }
      }

      b.addEventListener('click', () => {
        if (active.has(layer.k)) active.delete(layer.k); else active.add(layer.k);
        b.setAttribute('aria-pressed', String(active.has(layer.k)));
        render();
      });
      layersEl.append(b);
    }
  };

  tabsEl.innerHTML = '';
  for (const c of choices) {
    const b = document.createElement('button');
    b.type = 'button';
    b.dataset.radius = c;
    b.textContent = labelFor[c];
    b.setAttribute('aria-pressed', String(c === radius));
    b.addEventListener('click', () => {
      radius = c;
      tabsEl.querySelectorAll('button').forEach(x => x.setAttribute('aria-pressed', String(x === b)));
      // Only the single-radius mode fits the view to the chosen circle; the
      // legacy 500 m / 1 km / Both tabs keep the original zoom as before.
      if (single) map.setView(origin, zoomFor[radius] ?? 14.5);
      buildChips();
      render();
    });
    tabsEl.append(b);
  }

  recenterBtn.addEventListener('click', () => {
    map.setView(origin, zoomFor[radius] ?? 14.5);
  });

  fullscreenBtn.addEventListener('click', () => {
    if (document.fullscreenElement) {
      document.exitFullscreen?.();
    } else if (document.documentElement.requestFullscreen) {
      document.documentElement.requestFullscreen().catch(() => {
        showAlert('Fullscreen is not available in this browser.');
      });
    }
  });
  document.addEventListener('fullscreenchange', () => {
    fullscreenBtn.setAttribute('aria-pressed', String(Boolean(document.fullscreenElement)));
    setTimeout(() => map.invalidateSize(), 60);
  });

  buildChips();
  render();

  fetch('/property_reference_955.json', { credentials: 'same-origin' })
    .then(r => { if (!r.ok) throw new Error('Research reference file unavailable'); return r.json(); })
    .then(list => {
      if (!Array.isArray(list)) throw new Error('Invalid reference dataset');
      nearby = list.filter(p => p && typeof p.lat === 'number' && typeof p.lon === 'number' && p.id !== propertyId)
        .map(p => ({ ...p, dist: meters({ lat, lon }, p) }))
        .filter(p => p.dist <= maxDisplayM + 1e-6)
        .sort((a, b) => a.dist - b.dist);
      render();
    })
    .catch(() => { nearbyLabel.textContent = 'Nearby property locations could not be loaded'; });
  // Straight-line buffers only, not verified storefront position or travel time.
  setTimeout(() => map.invalidateSize(), 0);
})();
