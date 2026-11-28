/* SITEWISE_LOCATION_PICKER_CURRENT_V2 — browser location with manual fallback. */
(() => {
  'use strict';
  const triggerSelector = '[data-sitewise-location-picker]';
  let overlay = null;
  let map = null;
  let lastFocus = null;
  const valid = (lat, lon) => Number.isFinite(lat) && Number.isFinite(lon) &&
    Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && !(lat === 0 && lon === 0);

  function close() {
    if (!overlay) return;
    if (map) { map.remove(); map = null; }
    overlay.remove(); overlay = null;
    document.removeEventListener('keydown', onKey, true);
    document.body.classList.remove('rec2-location-modal-open');
    if (lastFocus && lastFocus.isConnected) lastFocus.focus();
    lastFocus = null;
  }

  function onKey(e) {
    if (e.key === 'Escape') { e.preventDefault(); close(); return; }
    if (e.key !== 'Tab' || !overlay) return;
    const nodes = Array.from(overlay.querySelectorAll(
      'button:not([disabled]), a[href], [tabindex]:not([tabindex="-1"])'
    )).filter(el => el.tabIndex >= 0 && el.getClientRects().length);
    if (!nodes.length) return;
    const first = nodes[0], last = nodes[nodes.length - 1];
    if (!overlay.contains(document.activeElement)) {
      e.preventDefault(); (e.shiftKey ? last : first).focus();
    } else if (e.shiftKey && document.activeElement === first) {
      e.preventDefault(); last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault(); first.focus();
    }
  }

  function open(button) {
    if (overlay) close();
    const L = window.L;
    if (!L || !L.map) {
      window.alert('The map is unavailable. Enter an address or coordinates instead.');
      return;
    }
    const rawLat = button.getAttribute('data-lat');
    const rawLon = button.getAttribute('data-lon');
    const startLat = Number(rawLat), startLon = Number(rawLon);
    const hasStart = rawLat != null && rawLon != null && rawLat.trim() !== '' &&
      rawLon.trim() !== '' && valid(startLat, startLon);
    let chosen = hasStart ? {lat: startLat, lng: startLon} : null;
    let marker = null, accuracyCircle = null, requestId = 0;
    lastFocus = button;
    overlay = document.createElement('div');
    const instance = overlay;
    overlay.className = 'rec2-location-backdrop';
    overlay.innerHTML = `
      <section class="rec2-location-dialog" role="dialog" aria-modal="true" aria-labelledby="rec2-location-dialog-title" aria-describedby="rec2-location-dialog-help">
        <header class="rec2-location-dialog__head">
          <div><h2 id="rec2-location-dialog-title">Choose search location</h2>
          <p id="rec2-location-dialog-help">Use your current location or choose a different point on the map.</p></div>
          <button type="button" class="rec2-location-dialog__close" aria-label="Close map">×</button>
        </header>
        <div class="rec2-location-dialog__toolbar">
          <button type="button" class="rec2-location-dialog__locate">&#9678; Use my location</button>
          <p class="rec2-location-dialog__status" role="status" aria-live="polite"></p>
        </div>
        <div class="rec2-location-dialog__map" id="rec2-location-dialog-map" aria-label="Interactive map. Use arrow keys to pan, plus and minus to zoom, or click a point."></div>
        <div class="rec2-location-dialog__bottom">
          <div class="rec2-location-dialog__selection">
            <strong class="rec2-location-dialog__selection-title">Selected location</strong>
            <p class="rec2-location-dialog__coords" aria-live="polite">No point selected</p>
            <button type="button" class="rec2-location-dialog__center">Select map centre</button>
          </div>
          <div class="rec2-location-dialog__buttons">
            <button type="button" class="rec2-location-dialog__cancel">Cancel</button>
            <button type="button" class="rec2-location-dialog__apply" disabled>Use this location</button>
          </div>
        </div>
      </section>`;
    document.body.appendChild(overlay);
    document.body.classList.add('rec2-location-modal-open');
    document.addEventListener('keydown', onKey, true);
    overlay.addEventListener('click', e => { if (e.target === instance) close(); });
    overlay.querySelector('.rec2-location-dialog__close').addEventListener('click', close);
    overlay.querySelector('.rec2-location-dialog__cancel').addEventListener('click', close);
    const apply = overlay.querySelector('.rec2-location-dialog__apply');
    const coords = overlay.querySelector('.rec2-location-dialog__coords');
    const status = overlay.querySelector('.rec2-location-dialog__status');
    const locate = overlay.querySelector('.rec2-location-dialog__locate');
    const center = overlay.querySelector('.rec2-location-dialog__center');
    apply.addEventListener('click', () => {
      if (!chosen) return;
      const input = document.getElementById('rec2-location-pick-value');
      if (!input) { close(); return; }
      input.value = `${chosen.lat.toFixed(6)},${chosen.lng.toFixed(6)}`;
      input.dispatchEvent(new Event('input', {bubbles: true}));
      close();
    });
    const localMap = L.map('rec2-location-dialog-map', {scrollWheelZoom: true, keyboard: true})
      .setView(chosen ? [chosen.lat, chosen.lng] : [3.1390, 101.6869], chosen ? 16 : 12);
    map = localMap;
    const alive = () => overlay === instance && map === localMap;
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19, attribution: '&copy; OpenStreetMap contributors',
    }).addTo(localMap).on('tileerror', () => {
      if (!alive()) return;
      // Do not erase location-permission feedback with every failed tile.
      instance.querySelector('.rec2-location-dialog__map').classList.add('rec2-map-tile-error');
    });
    const pin = L.divIcon({className: 'rec2-location-pin', html: '<span aria-hidden="true"></span>', iconSize: [30, 38], iconAnchor: [15, 36]});
    function select(lat, lon, source, accuracy) {
      if (!valid(lat, lon) || !alive()) return;
      chosen = {lat, lng: lon};
      if (accuracyCircle) { accuracyCircle.remove(); accuracyCircle = null; }
      if (marker) marker.setLatLng([lat, lon]);
      else marker = L.marker([lat, lon], {icon: pin, title: 'Selected search location', keyboard: false, interactive: false}).addTo(localMap);
      if (Number.isFinite(accuracy) && accuracy > 0) {
        accuracyCircle = L.circle([lat, lon], {radius: accuracy, color: '#1d4ed8', weight: 1, fillOpacity: .10, interactive: false}).addTo(localMap);
        marker.setZIndexOffset(1000);
      }
      coords.textContent = `${source} · ${lat.toFixed(6)}, ${lon.toFixed(6)}`;
      apply.disabled = false;
    }
    function cancelPending() {
      requestId++;
      locate.disabled = false;
      locate.removeAttribute('aria-busy');
    }
    function manual(lat, lon) {
      cancelPending();
      select(lat, lon, 'Map point');
      status.textContent = 'Point selected. Confirm to use it as your search location.';
    }
    if (chosen) select(chosen.lat, chosen.lng, 'Previous point');
    localMap.on('click', ({latlng}) => manual(latlng.lat, latlng.lng));
    center.addEventListener('click', () => {
      const point = localMap.getCenter().wrap();
      manual(point.lat, point.lng);
    });
    localMap.on('dragstart', () => {
      if (locate.disabled) { cancelPending(); status.textContent = 'Move the map or select a point. Use my location to locate again.'; }
    });
    function locateUser() {
      const token = ++requestId;
      const current = () => alive() && token === requestId;
      if (!navigator.geolocation || !window.isSecureContext) {
        status.textContent = 'Location access is unavailable. Choose a point on the map or enter an address.';
        return;
      }
      locate.disabled = true;
      locate.setAttribute('aria-busy', 'true');
      status.textContent = 'Finding your location… Allow location access if your browser asks.';
      function finish(message) {
        if (!current()) return;
        locate.disabled = false;
        locate.removeAttribute('aria-busy');
        status.textContent = message;
      }
      try {
        navigator.geolocation.getCurrentPosition(position => {
          if (!current()) return;
          const {latitude, longitude, accuracy} = position.coords;
          if (!valid(latitude, longitude)) { finish('Location could not be determined. Choose a map point instead.'); return; }
          const approximate = Number.isFinite(accuracy) && accuracy > 1000;
          localMap.setView([latitude, longitude], approximate ? 13 : 16);
          select(latitude, longitude, 'Your current location', accuracy);
          const detail = Number.isFinite(accuracy) ? ` Estimated accuracy: ${Math.round(accuracy)} m.` : '';
          finish((approximate ? 'Approximate location found. Adjust the point if needed.' : 'Location found. Confirm or adjust the point.') + detail);
        }, error => {
          if (!current()) return;
          finish(error.code === 1 ? 'Location permission was denied. Allow access in your browser or choose a map point.' : error.code === 3 ? 'Location request timed out. Try again or choose a map point.' : 'Your location is unavailable. Choose a map point or try again.');
        }, {enableHighAccuracy: true, timeout: 12000, maximumAge: 60000});
      } catch (_) { finish('Location access is unavailable. Choose a map point instead.'); }
    }
    locate.addEventListener('click', locateUser);
    overlay.querySelector('.rec2-location-dialog__close').focus();
    window.requestAnimationFrame(() => { if (alive()) localMap.invalidateSize(); });
    locateUser();
  }
  document.addEventListener('click', e => {
    const trigger = e.target && e.target.closest && e.target.closest(triggerSelector);
    if (!trigger) return;
    e.preventDefault(); open(trigger);
  });
})();
