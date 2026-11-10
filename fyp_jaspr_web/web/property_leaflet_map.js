/* First-party reusable map for the SiteWise property detail and analysis pages.
 * Leaflet + CARTO Voyager / OpenStreetMap. Reference markers are research
 * rental properties (U), NOT F&B competitors. Not a road-network catchment.
 */
(() => {
  'use strict';
  const q = new URLSearchParams(window.location.search);
  const lat = Number(q.get('lat'));
  const lon = Number(q.get('lon'));
  const propertyId = q.get('id') || 'Selected property';
  const alertEl = document.getElementById('map-alert');
  const nearbyLabel = document.getElementById('nearby-label');
  const showAlert = message => { alertEl.textContent = message; alertEl.hidden = false; };
  const valid = Number.isFinite(lat) && Number.isFinite(lon) &&
    lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180 &&
    !(lat === 0 && lon === 0);
  if (!valid || typeof L === 'undefined') {
    showAlert(valid ? 'Map library did not load. Check the browser connection.' : 'No valid coordinates for this property.');
    nearbyLabel.textContent = 'Map unavailable';
    return;
  }
  const cartoKey = window.SITEWISE_MAP_CONFIG?.cartoBasemapsKey;
  if (!cartoKey) {
    showAlert('CARTO basemap key missing. Generate map-config.js and rebuild SiteWise.');
    nearbyLabel.textContent = 'Map unavailable';
    return;
  }
  document.getElementById('location-id').textContent = ` · ${propertyId}`;

  const map = L.map('map', { zoomControl:true, preferCanvas:true, minZoom:5, maxZoom:19 });
  const tile = L.tileLayer('https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png?key=' + encodeURIComponent(cartoKey), {
    maxZoom:20,
    attribution:'&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a> contributors &copy; <a href="https://carto.com/" target="_blank" rel="noopener">CARTO</a>'
  }).addTo(map);
  let tileErrors = 0;
  tile.on('tileerror', () => { if (++tileErrors >= 3) showAlert('Basemap tiles could not load. The position and distance overlays may still be visible.'); });
  const origin = [lat, lon];
  map.setView(origin, 14.5);
  L.circleMarker(origin, {radius:10, color:'#fff',weight:3,fillColor:'#1d4ed8',fillOpacity:1})
    .addTo(map).bindPopup(`<strong>Selected property</strong><div id="selected-id"></div>`);
  // This popup uses textContent rather than interpolation of property IDs.
  map.eachLayer(layer => {
    if (typeof layer.getPopup === 'function' && layer.getPopup()) {
      const el = document.createElement('div');
      const strong = document.createElement('strong');
      strong.textContent = 'Selected property';
      const name = document.createElement('div');
      name.textContent = propertyId;
      el.append(strong, name);
      layer.bindPopup(el);
    }
  });

  const rings = L.layerGroup().addTo(map);
  const nearMarkers = L.layerGroup().addTo(map);
  let radius = 'both';
  let nearby = [];
  const meters = (a,b) => {
    const toR = Math.PI/180;
    const dLat=(b.lat-a.lat)*toR, dLon=(b.lon-a.lon)*toR;
    const h=Math.sin(dLat/2)**2 + Math.cos(a.lat*toR)*Math.cos(b.lat*toR)*Math.sin(dLon/2)**2;
    return 2*6371008.8*Math.atan2(Math.sqrt(h),Math.sqrt(Math.max(0,1-h)));
  };
  const render = () => {
    rings.clearLayers(); nearMarkers.clearLayers();
    if (radius !== '500') L.circle(origin, {radius:1000,color:'#8a6bc7',weight:2,fillColor:'#8a6bc7',fillOpacity:.07,dashArray:'6 5',interactive:false}).addTo(rings);
    if (radius !== '1000') L.circle(origin, {radius:500,color:'#0f9d86',weight:2,fillColor:'#0f9d86',fillOpacity:.09,interactive:false}).addTo(rings);
    for (const entry of nearby) {
      if (radius === '500' && entry.dist > 500) continue;
      const isClose = entry.dist <= 500;
      const marker = L.circleMarker([entry.lat,entry.lon], {
        radius:5.5,weight:1.5,color:'#fff',fillOpacity:.9,
        fillColor:isClose?'#0f9d86':'#8a6bc7'
      });
      const content = document.createElement('div');
      const name = document.createElement('strong');name.textContent=entry.id;
      const title = document.createElement('div');title.textContent=entry.title;
      const distance = document.createElement('div');distance.textContent=`${Math.round(entry.dist)} m away · research reference property`;
      content.append(name,title,distance);
      marker.bindPopup(content).addTo(nearMarkers);
    }
    const inner=nearby.filter(x=>x.dist<=500).length;
    const outer=nearby.length-inner;
    nearbyLabel.textContent = `${inner} within 500 m · ${outer} from 500 m–1 km`;
  };
  document.querySelectorAll('[data-radius]').forEach(b => b.addEventListener('click', () => {
    radius=b.dataset.radius;
    document.querySelectorAll('[data-radius]').forEach(x=>x.setAttribute('aria-pressed',String(x===b)));
    render();
  }));
  render();
  fetch('/property_reference_955.json', {credentials:'same-origin'})
    .then(r => {if(!r.ok) throw new Error('Research reference file unavailable');return r.json();})
    .then(list => {
      if (!Array.isArray(list)) throw new Error('Invalid reference dataset');
      nearby=list.filter(p=>p&&typeof p.lat==='number'&&typeof p.lon==='number'&&p.id!==propertyId)
        .map(p=>({...p,dist:meters({lat,lon},p)}))
        .filter(p=>p.dist<=1000+1e-6)
        .sort((a,b)=>a.dist-b.dist);
      render();
    })
    .catch(()=>{nearbyLabel.textContent='Reference property markers unavailable';});
  // Straight-line buffers only, not verified storefront position or travel time.
  setTimeout(()=>map.invalidateSize(),0);
})();
