/* First-party reusable map for the SiteWise property detail and analysis pages.
 * Leaflet + OpenFreeMap Positron. Reference markers are research
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
 * Transport, Parking. The page passes their recorded counts as a compact JSON
 * array in the ?layers parameter. Each entry carries `m` — whether the layer
 * is served from a coordinate-carrying source table (all five are; every
 * marker comes from the nearby-places payload). Recorded research counts and
 * mapped locations stay separate registers, and the chips show both.
 *
 * Individual verified locations arrive separately: the page fetches
 * /api/v1/catalog/properties/{id}/nearby-places through the authenticated API
 * and pushes the payload in with `postMessage` (a string-prefixed JSON body,
 * same-origin only). Each place carries its own category, subtype, operating
 * status where the source records one, and straight-line distance from the
 * property's scored coordinate. Recorded totals and mapped locations are kept
 * apart on purpose: they can legitimately differ (closed or unverified
 * outlets, deduplication, coordinate gates), and the chips show both numbers
 * instead of forcing one onto the other. When no message arrives (another
 * host page, a failed fetch), the map settles back to its recorded-counts
 * state after a short grace period and never invents pins from absence.
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
  const paintNotice = message => {
    alertEl.textContent = message;
    alertEl.hidden = !message;
  };
  const valid = Number.isFinite(lat) && Number.isFinite(lon) &&
    lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180 &&
    !(lat === 0 && lon === 0);
  if (!valid || typeof L === 'undefined') {
    showAlert(valid ? 'The map could not open. Please refresh this page.' : 'The map location is not available for this property.');
    nearbyLabel.textContent = 'Map unavailable';
    return;
  }
  document.getElementById('location-id').textContent = ` · ${propertyId}`;

  // -- layers ---------------------------------------------------------------
  // Fallback mirrors the backend's five layers so the control still renders
  // when the page has no insights payload (for example, an unscored listing).
  const DEFAULT_LAYERS = [
    { k: 'properties', l: 'Properties', c: '#1d4ed8', m: true },
    { k: 'competitors', l: 'Food Businesses', c: '#d97706', m: true },
    { k: 'demand_generators', l: 'Nearby Places', c: '#0f9d86', m: true },
    { k: 'accessibility', l: 'Transport', c: '#7c3aed', m: true },
    { k: 'parking', l: 'Parking', c: '#475569', m: true }
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
  const layerColor = key => (layers.find(x => x.k === key) || {}).c || '#1d4ed8';

  // -- individual nearby locations (postMessage) ----------------------------
  // Colours follow the design brief: food orange, education blue, transport
  // purple, retail teal, office indigo, healthcare red, parking slate. A
  // possibly-closed food outlet is grey — the distinction the source data
  // actually supports, not an invented certainty.
  const SUBTYPE_STYLES = {
    competitors: { c: '#d97706', g: 'F', l: 'Food business' },
    SCHOOL: { c: '#2563eb', g: 'E', l: 'School' },
    UNIVERSITY_COLLEGE: { c: '#2563eb', g: 'E', l: 'University / college' },
    MALL: { c: '#0f9d86', g: 'R', l: 'Mall' },
    SUPERMARKET: { c: '#0f9d86', g: 'R', l: 'Supermarket' },
    RETAIL: { c: '#0f9d86', g: 'R', l: 'Retail shop' },
    OFFICE: { c: '#4f46e5', g: 'O', l: 'Office' },
    OFFICE_BUILDING: { c: '#4f46e5', g: 'O', l: 'Office building' },
    HOSPITAL: { c: '#dc2626', g: 'H', l: 'Hospital / clinic' },
    BUS: { c: '#7c3aed', g: 'T', l: 'Bus stop' },
    KTM: { c: '#7c3aed', g: 'T', l: 'KTM rail stop' },
    LRT: { c: '#7c3aed', g: 'T', l: 'LRT station' },
    MRT: { c: '#7c3aed', g: 'T', l: 'MRT station' },
    MONORAIL: { c: '#7c3aed', g: 'T', l: 'Monorail station' },
    parking: { c: '#475569', g: 'P', l: 'Parking' }
  };
  const CLOSED_STYLE = { c: '#94a3b8', g: 'F', l: 'Food business (possibly closed)' };
  const humanize = value => String(value || '')
    .replace(/[_/]+/g, ' ').trim().replace(/\b\w/g, ch => ch.toUpperCase());

  let placesPayload = null;
  let placesSettled = false;

  const styleFor = place => {
    if (place.category === 'competitors' && place.operating_status === 'possibly_closed') {
      return CLOSED_STYLE;
    }
    return SUBTYPE_STYLES[place.subtype] || SUBTYPE_STYLES[place.category] ||
      { c: layerColor(place.category), g: '•', l: humanize(place.subtype) || layerLabel(place.category) };
  };
  const layerLabel = key => (layers.find(x => x.k === key) || {}).l || key;

  const applyPlaces = payload => {
    const list = Array.isArray(payload && payload.places) ? payload.places : null;
    if (!list) return;
    const kept = [];
    for (const p of list) {
      if (!p || typeof p.lat !== 'number' || typeof p.lng !== 'number' ||
          !Number.isFinite(p.lat) || !Number.isFinite(p.lng) ||
          typeof p.distance_m !== 'number' ||
          (p.lat === 0 && p.lng === 0)) continue;
      kept.push(p);
    }
    placesPayload = {
      places: kept,
      categories: (payload.categories && typeof payload.categories === 'object')
        ? payload.categories : {},
      fetchedRadius: typeof payload.radius_m === 'number' ? payload.radius_m : null
    };
    for (const layer of layers) {
      if (layer.k !== 'properties') placeGroups[layer.k] = groupFor(layer.k);
    }
    placesSettled = true;
    buildChips();
    render();
  };

  window.addEventListener('message', e => {
    // Same-origin only: the payload comes from our own page, never a third party.
    if (e.origin !== window.location.origin) return;
    const raw = e.data;
    if (typeof raw !== 'string' || !raw.startsWith('sitewiseNearbyPlaces:')) return;
    try {
      applyPlaces(JSON.parse(raw.slice('sitewiseNearbyPlaces:'.length)));
    } catch (err) {
      // A malformed push is ignored; the recorded-counts state stays honest.
    }
  });

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
  const origin = [lat, lon];
  map.setView(origin, zoomFor[radius] ?? 14.5);
  window.SitewiseBasemap.mount(map);

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

  // One cluster group per nearby-location category, so toggling a layer
  // removes exactly its own markers and the others keep their clusters.
  const placeGroups = {};
  const groupFor = key => placeGroups[key] ?? ((typeof L.markerClusterGroup === 'function')
    ? L.markerClusterGroup({ chunkedLoading: true, maxClusterRadius: 50, disableClusteringAtZoom: 17 })
    : L.layerGroup());

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

  const STATUS_TEXT = {
    likely_open: 'Operating status: likely open',
    possibly_closed: 'Operating status: possibly closed',
    unknown: 'Operating status unverified'
  };
  const SOURCE_TEXT = {
    osm: 'OpenStreetMap-derived, deduplicated for this analysis',
    gtfs: 'official GTFS transit feed'
  };

  const placePopup = (place, style) => {
    const content = document.createElement('div');
    const name = document.createElement('strong');
    name.textContent = place.name || 'Unnamed place';
    const kind = document.createElement('div');
    const kindText = style.l + (place.detail && place.detail !== place.subtype
      ? ` · ${humanize(place.detail)}` : '');
    kind.textContent = kindText;
    const distance = document.createElement('div');
    distance.textContent = `~${place.distance_m} m straight line`;
    content.append(name, kind, distance);
    if (place.operating_status && STATUS_TEXT[place.operating_status]) {
      const status = document.createElement('div');
      status.textContent = STATUS_TEXT[place.operating_status];
      if (place.operating_status === 'possibly_closed') status.className = 'sw-pop__closed';
      content.append(status);
      if (place.status_evidence) {
        const evidence = document.createElement('div');
        evidence.className = 'sw-pop__muted';
        evidence.textContent = String(place.status_evidence).slice(0, 140);
        content.append(evidence);
      }
    }
    if (place.coords_verified === false) {
      const approximate = document.createElement('div');
      approximate.className = 'sw-pop__muted';
      approximate.textContent = 'Location approximate — awaiting coordinate verification';
      content.append(approximate);
    }
    const sourceBits = [];
    if (place.source) {
      sourceBits.push(SOURCE_TEXT[place.source] || humanize(place.source));
    }
    if (place.observed_at) sourceBits.push(`observed ${String(place.observed_at).slice(0, 10)}`);
    if (sourceBits.length) {
      const source = document.createElement('div');
      source.className = 'sw-pop__muted';
      source.textContent = `Source: ${sourceBits.join(' · ')}`;
      content.append(source);
    }
    return content;
  };

  const addPlaceMarker = (place, group) => {
    const style = styleFor(place);
    const closed = place.category === 'competitors' &&
      place.operating_status === 'possibly_closed';
    const marker = L.marker([place.lat, place.lng], {
      icon: L.divIcon({
        className: 'sw-place-icon',
        html: `<span${closed ? ' class="is-closed"' : ''} style="background:${style.c}">${style.g}</span>`,
        iconSize: [18, 18],
        iconAnchor: [9, 9],
        popupAnchor: [0, -9]
      }),
      title: `${style.l} — ${place.name || 'Unnamed place'}`
    });
    marker.bindPopup(placePopup(place, style));
    group.addLayer(marker);
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

  // -- §6/§7 honesty helpers ------------------------------------------------
  // Recorded counts (insights features) and mapped locations (nearby-places
  // payload) are deliberately separate numbers. Recorded exists only for the
  // measured 500 m / 1 km radii; mapped exists wherever verified coordinates
  // were returned for the current radius.
  const mappedFor = layer => {
    if (!placesPayload || layer.k === 'properties') return 0;
    const limit = radiusMeters();
    return placesPayload.places.reduce(
      (n, p) => (p.category === layer.k && p.distance_m <= limit ? n + 1 : n), 0);
  };
  const recordedFor = layer => {
    if (layer.k === 'properties') return null;
    if (single) {
      if (radius === '500') return layer.a;
      if (radius === '1000') return layer.b;
      return null; // 2 km / 3 km were never measured as recorded counts
    }
    if (radius === '500') return layer.a;
    if (radius === '1000') return layer.b;
    return layer.a; // "Both" keeps the closer ring's recorded count on the chip
  };
  const radiusPhrase = () => {
    if (single || radius !== 'both') return labelFor[radius];
    return '500 m and 1 km';
  };
  const listNames = items => {
    const names = items.map(x => x.l);
    return names.length === 1
      ? names[0]
      : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
  };
  // User-facing names for notices: full words, correct F&B capitalisation,
  // no internal category or source vocabulary.
  const PLAIN_NAMES = {
    competitors: 'food and beverage businesses',
    demand_generators: 'nearby places',
    accessibility: 'public transport stops',
    parking: 'parking facilities',
  };
  const plainNames = items => {
    const words = items.map(x => PLAIN_NAMES[x.k] || x.l.toLowerCase());
    return words.length === 1
      ? words[0]
      : `${words.slice(0, -1).join(', ')} and ${words[words.length - 1]}`;
  };
  const presentStyles = layer => {
    if (!placesPayload || !active.has(layer.k)) return [];
    const limit = radiusMeters();
    const seen = new Map();
    for (const p of placesPayload.places) {
      if (p.category !== layer.k || p.distance_m > limit) continue;
      const s = styleFor(p);
      const id = `${s.c}|${s.l}`;
      if (!seen.has(id)) seen.set(id, s);
    }
    return [...seen.values()].slice(0, 5);
  };

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
      const mapped = mappedFor(layer);
      if (mapped > 0) {
        // The subtypes actually inside the current radius get their own keys,
        // so e.g. a school and a hospital are never one anonymous teal dot.
        const styles = presentStyles(layer);
        for (const s of styles) key(s.c, s.l);
      } else {
        const text = layer.m
          ? layer.l
          : `${layer.l} (${countText(layer)})`;
        key(layer.c, text);
      }
    }
  };

  const countText = layer => {
    const parts = [];
    if (typeof layer.a === 'number') parts.push(`${layer.a} within 500 m`);
    if (typeof layer.b === 'number') parts.push(`${layer.b} within 1 km`);
    return parts.length ? parts.join(' · ') : 'No information available';
  };

  const categoryState = layer => {
    if (!placesPayload || !placesPayload.categories) return null;
    const meta = placesPayload.categories[layer.k];
    return meta && typeof meta.state === 'string' ? meta.state : null;
  };

  const renderNotice = () => {
    // Tile failures have their own slot; this line is only about layers.
    const parts = [];
    if (placesPayload) {
      const truncated = Object.values(placesPayload.categories)
        .some(c => c && c.truncated);
      if (truncated) {
        parts.push('Large catchment: only the nearest locations per layer are drawn.');
      }
    }
    // A failing source is never converted into an empty map: the layer keeps
    // its chip, says it could not be read, and the other layers are unaffected.
    const unavailable = layers.filter(x =>
      active.has(x.k) && x.k !== 'properties' && categoryState(x) === 'source_unavailable');
    if (unavailable.length) {
      parts.push(
        `We could not load nearby ${listNames(unavailable)} just now. ` +
        'Other map layers are unaffected.');
    }
    const stale = layers.filter(x =>
      active.has(x.k) && categoryState(x) === 'data_stale');
    if (stale.length) {
      parts.push(`${listNames(stale)} timetable data may be out of date.`);
    }
    const totalsOnly = layers.filter(x =>
      active.has(x.k) && x.k !== 'properties' &&
      categoryState(x) !== 'source_unavailable' &&
      mappedFor(x) === 0 && (recordedFor(x) ?? 0) > 0);
    if (totalsOnly.length) {
      parts.push(
        `${plainNames(totalsOnly)} ${totalsOnly.length === 1 ? 'has' : 'have'} ` +
        `been counted nearby, but ${totalsOnly.length === 1 ? 'its' : 'their'} ` +
        `exact locations are not available on the map within ${radiusPhrase()}.`);
    }
    // §7: the recorded research count and the mapped locations are separate
    // registers (recorded = the analysis feature vector's curated register;
    // mapped = every verified coordinate returned for this radius), so they
    // can differ in either direction — say so instead of hiding either number.
    const mismatched = layers.filter(x =>
      active.has(x.k) && x.k !== 'properties' &&
      mappedFor(x) > 0 && (recordedFor(x) ?? 0) > 0 &&
      mappedFor(x) !== recordedFor(x));
    if (mismatched.length) {
      parts.push(
        `${plainNames(mismatched)}: the counted total and the number of ` +
        'locations shown on the map come from different sources, so the two ' +
        'numbers may differ. The map chips show both.');
    }
    paintNotice(parts.join(' '));
  };

  const drawPlaces = () => {
    const limit = radiusMeters();
    for (const layer of layers) {
      if (layer.k === 'properties') continue;
      const group = placeGroups[layer.k];
      if (!group) continue;
      group.clearLayers();
      let count = 0;
      if (placesPayload && active.has(layer.k)) {
        for (const p of placesPayload.places) {
          if (p.category !== layer.k || p.distance_m > limit) continue;
          addPlaceMarker(p, group);
          count++;
        }
      }
      if (count > 0 && !map.hasLayer(group)) group.addTo(map);
      else if (count === 0 && map.hasLayer(group)) map.removeLayer(group);
    }
  };

  const render = () => {
    renderRings();
    markers.clearLayers();
    const limit = radiusMeters();
    const visible = nearby.filter(x => x.dist <= limit + 1e-6);
    if (active.has('properties')) {
      for (const entry of visible) addReferenceMarker(entry);
    }
    drawPlaces();
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
      b.dataset.mapped = String(layer.m || mappedFor(layer) > 0);
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
        // Recorded R (insights features) and mapped M (nearby-places) are
        // shown together when both exist and differ: "8/11" reads as 8
        // locations mapped of 11 recorded, and the full sentence lives in
        // the notice bar. Before the places push settles, the chip shows
        // only the recorded count — never a premature "totals only".
        const m = mappedFor(layer);
        const r = recordedFor(layer);
        const count = document.createElement('span');
        count.className = 'chip__count';
        if (m > 0 && typeof r === 'number' && r > 0 && r !== m) {
          count.textContent = `${m}/${r}`;
          b.title = `${m} locations shown on the map of ${r} counted within ${radiusPhrase()}`;
        } else if (m > 0) {
          count.textContent = String(m);
          b.title = typeof r === 'number' && r > 0
            ? `${m} locations shown on the map within ${radiusPhrase()}; ${r} counted`
            : `${m} locations shown on the map within ${radiusPhrase()}; no total is available`;
        } else if (typeof r === 'number') {
          count.textContent = String(r);
          if (r > 0) b.title = `${r} counted within ${radiusPhrase()}`;
        }
        if (m > 0 || typeof r === 'number') b.append(count);
        if (m > 0) {
          const tag = document.createElement('span');
          tag.className = 'chip__tag';
          tag.textContent = categoryState(layer) === 'data_stale'
            ? 'may be out of date'
            : 'mapped';
          b.append(tag);
        } else if (placesSettled && categoryState(layer) === 'source_unavailable') {
          const tag = document.createElement('span');
          tag.className = 'chip__tag';
          tag.textContent = 'source unavailable';
          b.append(tag);
        } else if (placesSettled && typeof r === 'number' && r > 0) {
          const tag = document.createElement('span');
          tag.className = 'chip__tag';
          tag.textContent = 'totals only';
          b.append(tag);
        } else if (placesSettled && typeof r === 'number' && r === 0) {
          // A measured zero is a real result, not missing information.
          const tag = document.createElement('span');
          tag.className = 'chip__tag';
          tag.textContent = 'none found';
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
  // If no places push arrives (another host page, a failed fetch), settle the
  // chips into their recorded-counts state so "totals only" is never a lie of
  // impatience — and never silently wrong either.
  setTimeout(() => {
    if (!placesSettled) {
      placesSettled = true;
      buildChips();
      renderNotice();
    }
  }, 4000);
  // Straight-line buffers only, not verified storefront position or travel time.
  setTimeout(() => map.invalidateSize(), 0);
})();
