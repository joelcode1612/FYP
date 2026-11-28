/* Shared OpenFreeMap background for the Leaflet property maps. */
(() => {
  'use strict';

  const STYLES = {
    Standard: 'https://tiles.openfreemap.org/styles/liberty',
    Light: 'https://tiles.openfreemap.org/styles/positron',
    Detailed: 'https://tiles.openfreemap.org/styles/bright',
  };
  const mounted = new WeakSet();
  const duplicateClasses = [
    'restaurant', 'cafe', 'fast_food', 'food_court', 'bakery', 'ice_cream',
    'shop', 'mall', 'supermarket', 'school', 'college', 'university',
    'office', 'hospital', 'bus', 'rail', 'parking',
  ];
  const duplicateSubclasses = [
    ...duplicateClasses, 'bus_stop', 'station', 'subway_entrance',
  ];
  const ATTRIBUTION =
    '<a href="https://openfreemap.org/" target="_blank" rel="noopener">OpenFreeMap</a>' +
    ' · © <a href="https://openmaptiles.org/" target="_blank" rel="noopener">OpenMapTiles</a>' +
    ' · © <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a> contributors';

  function mount(map) {
    if (mounted.has(map)) return;
    mounted.add(map);

    let layer;
    let timeout;
    let unloaded = false;
    let hasTiles = false;

    const appearance = L.DomUtil.create('label', 'sitewise-basemap-appearance');
    const icon = L.DomUtil.create('span', 'sitewise-basemap-icon', appearance);
    icon.setAttribute('aria-hidden', 'true');
    const select = L.DomUtil.create('select', '', appearance);
    select.setAttribute('aria-label', 'Map appearance');
    for (const name of Object.keys(STYLES)) select.add(new Option(name, name));
    select.addEventListener('change', load);
    L.DomEvent.disableClickPropagation(appearance);
    L.DomEvent.disableScrollPropagation(appearance);
    // Keep arrow keys inside the native control rather than panning the map.
    L.DomEvent.on(appearance, 'keydown', L.DomEvent.stopPropagation);
    const appearanceControl = L.control({ position: 'topright' });
    appearanceControl.onAdd = () => appearance;
    appearanceControl.addTo(map);

    const notice = L.DomUtil.create('div', 'sitewise-basemap-notice');
    notice.hidden = true;
    const message = L.DomUtil.create('span', '', notice);
    message.setAttribute('role', 'status');
    const retry = L.DomUtil.create('button', '', notice);
    retry.type = 'button';
    retry.textContent = 'Retry';
    retry.setAttribute('aria-label', 'Retry loading the map background');
    retry.addEventListener('click', () => load());
    L.DomEvent.disableClickPropagation(notice);
    L.DomEvent.disableScrollPropagation(notice);
    const control = L.control({ position: 'bottomleft' });
    control.onAdd = () => notice;
    control.addTo(map);
    map.attributionControl?.addAttribution(ATTRIBUTION);

    function showFailure() {
      clearTimeout(timeout);
      message.textContent = 'Map background unavailable.';
      retry.hidden = false;
      notice.hidden = false;
    }

    function load() {
      clearTimeout(timeout);
      hasTiles = false;
      if (!notice.hidden) {
        message.textContent = 'Loading map background…';
        retry.hidden = true;
      }
      if (typeof L.maplibreGL !== 'function') {
        showFailure();
        return;
      }

      const style = STYLES[select.value];
      const renderer = layer?.getMaplibreMap();
      if (renderer) {
        renderer.setStyle(style, { diff: false });
        waitForTiles();
        return;
      }

      const attempt = L.maplibreGL({
        style,
        pane: 'tilePane',
        interactive: false,
        attributionControl: false,
      });
      layer = attempt;
      try {
        attempt.addTo(map);
      } catch (_) {
        // The adapter can append its container before WebGL initialization
        // fails. Let Leaflet detach the partially added layer and its events.
        if (!attempt.getMaplibreMap()) {
          attempt.onRemove = () => attempt.getContainer()?.remove();
        }
        map.removeLayer(attempt);
        layer = null;
        showFailure();
        return;
      }

      const gl = attempt.getMaplibreMap();
      const current = () => !unloaded && layer === attempt;
      function showBackground() {
        hasTiles = true;
        clearTimeout(timeout);
        notice.hidden = true;
      }
      gl.on('style.load', () => {
        if (select.value === 'Standard') {
          // Leaflet zoom 15 corresponds to MapLibre zoom 14 in the adapter.
          if (gl.getLayer('highway-name-minor')) {
            gl.setLayerZoomRange('highway-name-minor', 14, 24);
          }
          if (gl.getLayer('landuse_residential')) {
            gl.addLayer({
              id: 'sitewise-commercial-landuse',
              type: 'fill',
              source: 'openmaptiles',
              'source-layer': 'landuse',
              filter: ['==', ['get', 'class'], 'commercial'],
              paint: { 'fill-color': '#edd9c7', 'fill-opacity': 0.35 },
            }, 'landuse_residential');
          }
        }
        for (const symbol of gl.getStyle().layers) {
          if (symbol['source-layer'] !== 'poi' || !symbol.layout?.['icon-image']) continue;
          // SiteWise already marks these categories. Leave the basemap's
          // text, roads, station infrastructure and other symbols intact.
          gl.setPaintProperty(symbol.id, 'icon-opacity', [
            'case',
            ['any',
              ['match', ['get', 'class'], duplicateClasses, true, false],
              ['match', ['get', 'subclass'], duplicateSubclasses, true, false],
            ],
            0,
            symbol.paint?.['icon-opacity'] ?? 1,
          ]);
        }
      });
      gl.on('sourcedata', event => {
        if (current() && event.sourceId === 'openmaptiles' &&
            event.tile?.hasData?.() && gl.isStyleLoaded()) showBackground();
      });
      gl.on('idle', () => {
        if (current() && (!hasTiles || !notice.hidden) &&
            gl.queryRenderedFeatures().some(feature => feature.source === 'openmaptiles')) {
          showBackground();
        }
      });
      gl.on('error', event => {
        if (!current()) return;
        if (!hasTiles && (!event.sourceId || event.sourceId === 'openmaptiles')) {
          showFailure();
        } else if (event.sourceId === 'openmaptiles') {
          // A different tile may still finish as the user pans or zooms.
          clearTimeout(timeout);
          timeout = setTimeout(showFailure, 1000);
        }
      });
      gl.on('webglcontextlost', () => { if (current()) showFailure(); });
      waitForTiles();
    }

    function waitForTiles() {
      timeout = setTimeout(() => {
        if (!unloaded && !hasTiles) showFailure();
      }, 12000);
    }

    map.once('unload', () => {
      unloaded = true;
      clearTimeout(timeout);
      control.remove();
      appearanceControl.remove();
    });
    load();
  }

  window.SitewiseBasemap = { mount };
})();
