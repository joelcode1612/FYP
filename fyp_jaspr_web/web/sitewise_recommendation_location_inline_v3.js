/* SITEWISE_INLINE_LOCATION_V3
   Browser-only Leaflet adapter. Dart owns filters; this adapter owns map DOM.
   No location is applied to recommendation requests by this script. */
(() => {
  'use strict';
  const selector = '[data-sitewise-inline-location]';
  const gpsSelector = '[data-sitewise-current-location]';
  const fallback = [3.1390, 101.6869]; // Map viewport only, never a selected point.
  let active = null, frame = 0, autoAttempted = false;
  const valid = (lat, lon) => Number.isFinite(lat) && Number.isFinite(lon) &&
    Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && !(lat === 0 && lon === 0);
  const key = (lat, lon) => `${lat.toFixed(6)},${lon.toFixed(6)}`;
  function read(host) {
    const a = host.getAttribute('data-lat') || '';
    const b = host.getAttribute('data-lon') || '';
    if (!a.trim() || !b.trim()) return null;
    const lat = Number(a), lon = Number(b);
    return valid(lat, lon) ? {lat, lng: lon} : null;
  }
  function live(s) { return active === s && s.host.isConnected; }
  function status(s, message, error = false) {
    s.status.textContent = message;
    s.status.classList.toggle('rec2-location__status--error', error);
  }
  function gpsButton(s) {
    return s.host.closest('.rec2-location__field')?.querySelector(gpsSelector);
  }
  function setBusy(s, busy) {
    s.busy = busy;
    const b = gpsButton(s);
    if (b) { b.disabled = busy; b.setAttribute('aria-busy', String(busy)); }
  }
  function cancelGPS(s) {
    if (!s.busy) return;
    s.ticket++;
    setBusy(s, false);
    status(s, 'Location detection cancelled. Choose your point on the map.');
  }
  function center(s, point, zoom) {
    if (!s.map) return;
    s.suppress = true;
    try {
      s.map.stop();
      s.map.setView([point.lat, point.lng], zoom, {animate: false});
      s.lastCenter = s.map.getCenter();
    } finally { s.suppress = false; }
  }
  function showPoint(s, point) {
    s.chosen = point ? key(point.lat, point.lng) : null;
    s.pin.classList.toggle('rec2-location__pin--unselected', !point);
  }
  function publish(s, point, message) {
    if (!live(s) || !valid(point.lat, point.lng)) return;
    const bridge = s.host.closest('#rec2-nearby-picker')?.querySelector('#rec2-location-pick-value');
    if (!bridge) { status(s, 'Location form is not ready. Try again.', true); return; }
    showPoint(s, point);
    bridge.value = s.chosen;
    bridge.dispatchEvent(new Event('input', {bubbles: true}));
    status(s, message || 'Pin selected. Press Apply location to use this point.');
  }
  function locate(s) {
    if (!live(s) || s.busy) return;
    autoAttempted = true;
    if (!window.isSecureContext || !navigator.geolocation) {
      status(s, 'Current location requires HTTPS or localhost. Use the map or address search instead.', true);
      return;
    }
    const ticket = ++s.ticket;
    setBusy(s, true);
    status(s, 'Detecting your current location…');
    navigator.geolocation.getCurrentPosition(position => {
      if (!live(s) || ticket !== s.ticket) return;
      setBusy(s, false);
      const point = {lat: position.coords.latitude, lng: position.coords.longitude};
      if (!valid(point.lat, point.lng)) {
        status(s, 'No usable location was returned. Choose a point manually.', true); return;
      }
      center(s, point, 17);
      const accuracy = position.coords.accuracy;
      publish(s, point, `Current location detected${Number.isFinite(accuracy) ? ` (±${Math.round(accuracy)} m)` : ''}. Drag the map to refine the pin.`);
    }, error => {
      if (!live(s) || ticket !== s.ticket) return;
      setBusy(s, false);
      const msg = error.code === 1 ? 'Location permission was denied.' :
        error.code === 3 ? 'Location detection timed out.' : 'Current location is unavailable.';
      status(s, `${msg} Search for an address or move the map to choose a point.`, true);
    }, {enableHighAccuracy: true, timeout: 12000, maximumAge: 0});
  }
  function mount(host) {
    // No untrusted values are interpolated into this markup.
    host.innerHTML = `<div class="rec2-location__map-shell">
      <div class="rec2-location__map" aria-label="Interactive map. Drag to position the center pin. Use arrow keys when the map is focused."></div>
      <div class="rec2-location__map-instruction" aria-hidden="true">Drag the map to position the pin</div>
      <div class="rec2-location__pin rec2-location__pin--unselected" aria-hidden="true"><svg width="36" height="46" viewBox="0 0 36 46"><path fill="#1554ce" stroke="#fff" stroke-width="2" d="M18 1C8.6 1 1 8.6 1 18c0 12 17 27 17 27s17-15 17-27C35 8.6 27.4 1 18 1Z"/><circle cx="18" cy="17" r="6" fill="#fff"/></svg></div>
    </div><p class="rec2-location__map-status rec2-location__status" role="status" aria-live="polite"></p>`;
    const s = {host, map: null, pin: host.querySelector('.rec2-location__pin'),
      status: host.querySelector('.rec2-location__map-status'), ticket: 0,
      busy: false, suppress: false, seen: undefined, chosen: null, lastCenter: null,
      observer: null};
    active = s;
    const p = read(host);
    s.seen = p ? key(p.lat, p.lng) : null;
    showPoint(s, p);
    const mapNode = host.querySelector('.rec2-location__map');
    if (window.L?.map) {
      s.map = window.L.map(mapNode, {scrollWheelZoom: false, dragging: true,
        touchZoom: true, keyboard: true, zoomControl: true, worldCopyJump: false,
        maxBounds: [[-85, -180], [85, 180]], maxBoundsViscosity: 1})
        .setView(p ? [p.lat, p.lng] : fallback, p ? 16 : 12);
      s.lastCenter = s.map.getCenter();
      const tiles = window.L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
        maxZoom: 19, noWrap: true, attribution: '&copy; OpenStreetMap contributors',
      }).addTo(s.map);
      let tileWarned = false;
      tiles.on('tileerror', () => {
        if (!live(s) || tileWarned) return;
        tileWarned = true;
        if (!s.busy) status(s, 'Some map tiles are unavailable. You can still use address search or coordinates.', true);
      });
      s.map.on('dragstart', () => cancelGPS(s));
      s.map.on('moveend', () => {
        if (s.suppress || !live(s)) return;
        const p = s.map.getCenter();
        const moved = !s.lastCenter || s.lastCenter.distanceTo(p) > 0.05;
        s.lastCenter = p;
        if (!moved) return;
        cancelGPS(s);
        publish(s, p);
      });
      s.map.on('click', ({latlng}) => {
        cancelGPS(s);
        center(s, latlng, s.map.getZoom());
        publish(s, latlng);
      });
      if (window.ResizeObserver) {
        s.observer = new ResizeObserver(() => {
          if (!live(s) || !s.map) return;
          s.suppress = true;
          try { s.map.invalidateSize({pan: false, animate: false}); s.lastCenter = s.map.getCenter(); }
          finally { s.suppress = false; }
        });
        s.observer.observe(mapNode);
      }
      requestAnimationFrame(() => {
        if (!live(s) || !s.map) return;
        s.suppress = true;
        try { s.map.invalidateSize({pan: false}); s.lastCenter = s.map.getCenter(); }
        finally { s.suppress = false; }
      });
    } else {
      host.querySelector('.rec2-location__map-shell').hidden = true;
    }
    status(s, !s.map ? 'Map unavailable. Use current location, address search or coordinates.' :
      p ? 'Selected point. Drag the map to refine it.' : 'Choose your current location, search for an address, or move the map.');
    // Only one automatic attempt per page; reopening never overwrites a saved pin.
    if (!p && !autoAttempted) locate(s);
  }
  function sync(s) {
    const p = read(s.host), next = p ? key(p.lat, p.lng) : null;
    if (next === s.seen) return;
    s.seen = next;
    if (next === s.chosen) return; // Dart acknowledgement of our own input.
    cancelGPS(s);
    showPoint(s, p);
    if (p) {
      center(s, p, 16);
      status(s, 'Point updated. Drag the map to refine the pin.');
    } else {
      status(s, 'Enter valid coordinates or choose a point on the map.');
    }
  }
  function unmount() {
    if (!active) return;
    const s = active; active = null; s.ticket++;
    s.observer?.disconnect();
    s.map?.remove();
    if (s.host.isConnected) s.host.replaceChildren();
  }
  function reconcile() {
    frame = 0;
    const host = document.querySelector(selector);
    if (active && (active.host !== host || !active.status.isConnected)) unmount();
    if (!host) return;
    if (!active) mount(host);
    else sync(active);
  }
  function schedule() { if (!frame) frame = requestAnimationFrame(reconcile); }
  document.addEventListener('click', e => {
    const button = e.target?.closest?.(gpsSelector);
    if (button) {
      e.preventDefault();
      if (!active) reconcile();
      if (active) locate(active);
    } else if (active && e.target?.closest?.('[aria-label="Look up address"]')) {
      cancelGPS(active);
    }
  });
  document.addEventListener('input', e => {
    if (active && ['rec2-nearby-latitude', 'rec2-nearby-longitude', 'rec2-nearby-address'].includes(e.target?.id)) cancelGPS(active);
  });
  const observer = new MutationObserver(records => {
    if (records.some(r => r.type === 'attributes' || !active || !active.host.isConnected || !active.status.isConnected ||
      (r.target !== active.host && !active.host.contains(r.target)))) schedule();
  });
  observer.observe(document.documentElement, {childList: true, subtree: true, attributes: true,
    attributeFilter: ['data-lat', 'data-lon']});
  schedule();
})();
