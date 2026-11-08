/* Three synthetic rental points, one selected experimental circle.
 * Map tiles are display-only. No POI discovery, scraper, real rental or data rights.
 * Normal user viewport loading only: no prefetching, export or headless pan scans.
 */
(function () {
  'use strict';
  let map = null;
  let markerLayers = [];
  let previewCircle = null;
  const demoCentre = [3.1432, 101.6892];

  globalThis.project1MapUpdate = function (payload) {
    const data = JSON.parse(payload);
    if (!globalThis.L || !document.getElementById('geo-map')) return;
    if (map && map.getContainer() !== document.getElementById('geo-map')) {
      map.remove(); map = null; markerLayers = []; previewCircle = null;
    }
    if (!map) {
      map = L.map('geo-map', { scrollWheelZoom: false }).setView(demoCentre, 13);
      L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
        maxZoom: 18,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap contributors</a>',
      }).addTo(map);
    }
    markerLayers.forEach(layer => map.removeLayer(layer));
    markerLayers = [];
    if (previewCircle) { map.removeLayer(previewCircle); previewCircle = null; }
    const valid = (data.rentals || []).filter(r => r.synthetic && Number.isFinite(r.lat) && Number.isFinite(r.lng));
    const visiblePoints = [];
    valid.forEach(r => {
      const point = [r.lat, r.lng];
      const selected = r.id === data.rentalId;
      const marker = L.circleMarker(point, {
        radius: selected ? 10 : 7,
        color: selected ? '#145b61' : '#344961',
        weight: selected ? 3 : 2,
        fillColor: selected ? '#65b7a5' : '#dce7eb',
        fillOpacity: 0.95,
      }).addTo(map).bindPopup(`${r.id} — synthetic fixture, not an actual rental`);
      markerLayers.push(marker);
      visiblePoints.push(point);
    });
    if (data.synthetic && Number.isFinite(data.lat) && Number.isFinite(data.lng)
        && Number.isFinite(data.radius) && data.radius > 0 && data.radius <= 5000) {
      previewCircle = L.circle([data.lat, data.lng], {
        radius: data.radius, color: '#175c62', fillColor: '#4db1ae',
        fillOpacity: 0.10, weight: 2, dashArray: '6 5',
      }).addTo(map);
    }
    if (visiblePoints.length) {
      const bounds = L.latLngBounds(visiblePoints);
      if (previewCircle) bounds.extend(previewCircle.getBounds());
      map.fitBounds(bounds, { padding: [36, 36], maxZoom: 15 });
    } else {
      map.setView(demoCentre, 13);
    }
    window.setTimeout(function () { map.invalidateSize(); }, 50);
  };
})();
