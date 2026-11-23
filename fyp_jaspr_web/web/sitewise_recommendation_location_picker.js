/* SiteWise recommendations: click-to-select coordinate map.
   The overlay belongs to this file, outside Jaspr-managed DOM. */
(() => {
  'use strict';
  const triggerSelector = '[data-sitewise-location-picker]';
  let overlay = null;
  let map = null;
  let marker = null;
  let lastFocus = null;

  const valid = (lat, lon) =>
    Number.isFinite(lat) && Number.isFinite(lon) &&
    Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && !(lat === 0 && lon === 0);

  function close() {
    if (!overlay) return;
    if (map) { map.remove(); map = null; }
    marker = null;
    overlay.remove(); overlay = null;
    document.removeEventListener('keydown', onKey, true);
    document.body.classList.remove('rec2-location-modal-open');
    if (lastFocus && lastFocus.isConnected) lastFocus.focus();
  }

  function onKey(e) {
    if (e.key === 'Escape') { e.preventDefault(); close(); }
    if (e.key !== 'Tab' || !overlay) return;
    const buttons = Array.from(overlay.querySelectorAll('button:not([disabled])'));
    if (buttons.length === 0) return;
    const first = buttons[0], last = buttons[buttons.length - 1];
    if (e.shiftKey && document.activeElement === first) {e.preventDefault(); last.focus();}
    else if (!e.shiftKey && document.activeElement === last) {e.preventDefault(); first.focus();}
  }

  function open(button) {
    if (overlay) close();
    if (!window.L || !window.L.map) {
      window.alert('Map tiles are unavailable. Enter latitude and longitude directly instead.');
      return;
    }
    const startLat = Number(button.getAttribute('data-lat'));
    const startLon = Number(button.getAttribute('data-lon'));
    const hasStart = valid(startLat, startLon) &&
      button.getAttribute('data-lat') !== '' && button.getAttribute('data-lon') !== '';
    let chosen = hasStart ? {lat: startLat, lng: startLon} : null;
    lastFocus = button;
    overlay = document.createElement('div');
    overlay.className = 'rec2-location-backdrop';
    overlay.innerHTML = `
      <section class="rec2-location-dialog" role="dialog" aria-modal="true" aria-labelledby="rec2-location-dialog-title">
        <header class="rec2-location-dialog__head">
          <div><h2 id="rec2-location-dialog-title">Pick a location</h2>
          <p>Click or tap the map to choose where to search for properties.</p></div>
          <button type="button" class="rec2-location-dialog__close" aria-label="Close map">×</button>
        </header>
        <div class="rec2-location-dialog__map" id="rec2-location-dialog-map" aria-label="Map of Malaysia. Tap a position to choose a search point."></div>
        <div class="rec2-location-dialog__bottom">
          <p class="rec2-location-dialog__coords" aria-live="polite">${chosen ? `${chosen.lat.toFixed(6)}, ${chosen.lng.toFixed(6)}` : 'No location selected yet'}</p>
          <div class="rec2-location-dialog__buttons">
            <button type="button" class="rec2-location-dialog__cancel">Cancel</button>
            <button type="button" class="rec2-location-dialog__apply" ${chosen ? '' : 'disabled'}>Use this point</button>
          </div>
        </div>
      </section>`;
    document.body.appendChild(overlay);
    document.body.classList.add('rec2-location-modal-open');
    document.addEventListener('keydown', onKey, true);
    overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
    overlay.querySelector('.rec2-location-dialog__close').addEventListener('click', close);
    overlay.querySelector('.rec2-location-dialog__cancel').addEventListener('click', close);
    const apply = overlay.querySelector('.rec2-location-dialog__apply');
    const coords = overlay.querySelector('.rec2-location-dialog__coords');
    apply.addEventListener('click', () => {
      if (!chosen) return;
      const input = document.getElementById('rec2-location-pick-value');
      if (!input) {close(); return;}
      input.value = `${chosen.lat.toFixed(6)},${chosen.lng.toFixed(6)}`;
      input.dispatchEvent(new Event('input', {bubbles: true}));
      close();
    });
    overlay.querySelector('.rec2-location-dialog__close').focus();
    const center = chosen ? [chosen.lat, chosen.lng] : [3.1390, 101.6869];
    map = window.L.map('rec2-location-dialog-map', {scrollWheelZoom: false})
      .setView(center, chosen ? 14 : 7);
    window.L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '&copy; OpenStreetMap contributors',
    }).addTo(map);
    function select(lat, lon) {
      if (!valid(lat, lon)) return;
      chosen = {lat, lng: lon};
      if (marker) marker.setLatLng([lat, lon]);
      else marker = window.L.marker([lat, lon]).addTo(map);
      coords.textContent = `${lat.toFixed(6)}, ${lon.toFixed(6)}`;
      apply.disabled = false;
    }
    if (chosen) select(chosen.lat, chosen.lng);
    map.on('click', ({latlng}) => select(latlng.lat, latlng.lng));
    window.requestAnimationFrame(() => { if (map) map.invalidateSize(); });
  }

  document.addEventListener('click', (e) => {
    const trigger = e.target && e.target.closest && e.target.closest(triggerSelector);
    if (!trigger) return;
    e.preventDefault();
    open(trigger);
  });
})();
