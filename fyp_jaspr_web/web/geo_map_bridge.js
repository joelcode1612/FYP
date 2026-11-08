/* PROJECT1 — L1 system-generated study zone map bridge.
 *
 * Directive: PROJECT1-GEO-SYSTEM-ZONE-V2-L1-EXECUTE-20261030.
 *
 * SSR-safe design: the Jaspr component renders `<div class="geo-map">` whose
 * `data-geo` attribute carries the current synthetic state as JSON. This bridge
 * reads that attribute (and re-reads it on change) and drives Leaflet. No
 * Dart/JS interop is required, so the static server build never compiles
 * browser-only APIs — only this plain JS file does, and it is a no-op on pages
 * without a `.geo-map` element.
 *
 * HYDRATION HAZARD (handled): Jaspr hydration re-asserts the component's
 * `class` attribute and may replace the container's children after this script
 * has already initialised Leaflet. That leaves a stale `_leaflet_id` on the
 * element ("Map container is already initialized") while the visual container
 * is gone. `ensureMap()` therefore detects an unhealthy map, tears it down,
 * clears the stale id and rebuilds. Renders are also scheduled after hydration
 * settles (0 / 300 / 900 / 1800 ms) in addition to the MutationObserver.
 *
 * Layer semantics (non-negotiable):
 *   - SYSTEM STUDY ZONE: solid teal, read-only, system-owned. The only
 *     calculation footprint. Never a real administrative boundary.
 *   - RADIUS: dashed circle, display-only. It never affects the venue count.
 *   - VENUES: filled dot = inside the zone; hollow dot = outside. All sample.
 *   - ADMIN (L2a): real DOSM ADM1/ADM2 boundaries, drawn from the same bytes
 *     the L2 harness measured. Context only: it never enters the venue count,
 *     never replaces the system zone and never draws an ADM3 feature. A failed
 *     fetch is surfaced as ADMIN_LAYER_UNAVAILABLE, never as an empty area.
 *
 * Map tiles are display-only OSM (attribution required). No POI ingestion,
 * scraping, export, offline prefetch or bulk fetching (OSMF tile policy).
 */
(function () {
  'use strict';

  var ZONE_WATERMARK = 'SYNTHETIC SYSTEM ZONE \u2014 NOT A REAL BOUNDARY';
  var TILE_URL = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  var MAX_INIT_ATTEMPTS = 40; // ~10s cap; prevents an unbounded retry spin
  var ADMIN_STATUS = {
    AVAILABLE: 'L2A_OPEN_DATA_AVAILABLE',
    LOADING: 'LOADING',
    READY: 'READY',
    HIDDEN: 'HIDDEN',
    UNAVAILABLE: 'UNAVAILABLE'
  };
  var maps = new WeakMap();
  var attempts = new WeakMap();
  var jsonCache = {};

  function loadJson(url) {
    if (!url) return Promise.reject(new Error('NO_URL'));
    if (!jsonCache[url]) {
      jsonCache[url] = fetch(url, { cache: 'force-cache' }).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status + ' for ' + url);
        return r.json();
      });
      jsonCache[url].catch(function () { delete jsonCache[url]; });
    }
    return jsonCache[url];
  }

  function parse(el) {
    var raw = el.getAttribute('data-geo');
    if (!raw) return null;
    try { return JSON.parse(raw); } catch (e) { return null; }
  }

  function isNum(v) { return typeof v === 'number' && isFinite(v); }

  /** A map is healthy only if the element still looks like a Leaflet map. */
  function mapHealthy(el, m) {
    return !!m &&
      m._container === el &&
      el.classList.contains('leaflet-container') &&
      !!el.querySelector('.leaflet-map-pane');
  }

  function teardown(el, m) {
    try { if (m && m.remove) m.remove(); } catch (e) { /* ignore */ }
    try { maps.delete(el); } catch (e) { /* ignore */ }
    try { delete el._leaflet_id; } catch (e) { /* ignore */ }
    try { el.__adminKey = null; el.__adminLayers = null; el.__adminBadge = null; } catch (e) { /* ignore */ }
    try { el.__adminUserFit = false; el.__adminFitKey = null; } catch (e) { /* ignore */ }
    // Remove any orphaned Leaflet DOM that survived a container reset.
    var panes = el.querySelectorAll('.leaflet-pane, .leaflet-control-container');
    for (var i = 0; i < panes.length; i++) {
      if (panes[i].parentNode) panes[i].parentNode.removeChild(panes[i]);
    }
  }

  function ensureMap(el, data) {
    var existing = maps.get(el);
    if (existing && mapHealthy(el, existing)) return existing;
    if (existing) {
      // Hydration or a re-render clobbered the map: rebuild from scratch.
      teardown(el, existing);
    } else if (el._leaflet_id) {
      // Stale id with no live map — clear it so L.map() can run again.
      teardown(el, null);
    }

    if (!window.L) {
      var n = (attempts.get(el) || 0) + 1;
      attempts.set(el, n);
      if (n > MAX_INIT_ATTEMPTS) {
        el.setAttribute('data-geo-error', 'MAP_LIBRARY_UNAVAILABLE');
        return null;
      }
      window.setTimeout(function () { render(el); }, 250);
      return null;
    }

    var c = data.demoCentre || {};
    var centre = [isNum(c.lat) ? c.lat : 3.14, isNum(c.lng) ? c.lng : 101.69];
    var m = L.map(el, {
      scrollWheelZoom: false,
      keyboard: true,
      attributionControl: true,
    }).setView(centre, 15);

    // Administrative pane sits below the study-zone overlay, so the system zone
    // stays visually dominant and a boundary line can never be read as the
    // calculation footprint.
    if (!m.getPane('adminPane')) {
      var ap = m.createPane('adminPane');
      ap.style.zIndex = 350;
    }

    L.tileLayer(TILE_URL, {
      maxZoom: 18,
      maxNativeZoom: 18,
      attribution:
        '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap contributors</a>',
    }).addTo(m);

    // Persistent watermark control (every synthetic zone is labelled in the
    // map as well as in the page text).
    var wm = L.control({ position: 'bottomright' });
    wm.onAdd = function () {
      var d = document.createElement('div');
      d.className = 'geo-watermark';
      d.textContent = ZONE_WATERMARK;
      d.setAttribute('aria-hidden', 'true');
      return d;
    };
    wm.addTo(m);

    // L2a administrative status + fit control (separate from the zone).
    var adminControl = L.control({ position: 'topright' });
    adminControl.onAdd = function () {
      var d = document.createElement('div');
      d.className = 'geo-admin-badge';
      d.setAttribute('role', 'status');
      d.setAttribute('aria-live', 'polite');
      d.textContent = 'Administrative boundaries (L2a): pending';
      el.__adminBadge = d;
      return d;
    };
    adminControl.addTo(m);

    var fitControl = L.control({ position: 'bottomleft' });
    fitControl.onAdd = function () {
      var wrap = document.createElement('div');
      wrap.className = 'geo-admin-fit';
      var b = document.createElement('button');
      b.type = 'button';
      b.textContent = 'Fit administrative boundary';
      b.setAttribute('aria-label',
        'Zoom the map to the selected administrative jurisdiction');
      b.addEventListener('click', function () {
        if (el.__adminBounds && el.__adminBounds.isValid()) {
          el.__adminUserFit = true;
          el.__adminFitKey = el.__adminKey;
          m.fitBounds(el.__adminBounds, { padding: [30, 30], maxZoom: 12 });
        }
      });
      wrap.appendChild(b);
      return wrap;
    };
    fitControl.addTo(m);

    attempts.set(el, 0);
    maps.set(el, m);
    return m;
  }

  function clearLayers(el, m) {
    var prev = el.__geoLayers;
    if (prev) { prev.forEach(function (l) { try { m.removeLayer(l); } catch (e) {} }); }
    el.__geoLayers = [];
  }

  function toLatLngs(points) {
    return (points || []).map(function (p) { return [p[0], p[1]]; });
  }

  function updateAdminBadge(el, text) {
    if (el.__adminBadge) el.__adminBadge.textContent = text;
  }

  // The accessible summary is server-rendered for the available state; keep it
  // from claiming a boundary is drawn when the viewer hid it or it failed.
  // Only the existing leading text node is rewritten so the framework keeps
  // ownership of the element and its later region updates.
  function adminSummaryNode() {
    var li = document.querySelector('.geo-admin-summary');
    if (!li) return null;
    for (var i = 0; i < li.childNodes.length; i++) {
      var n = li.childNodes[i];
      if (n.nodeType === 3 && n.nodeValue && n.nodeValue.indexOf('Administrative boundary') !== -1) return n;
    }
    return null;
  }

  function setAdminSummary(el, text) {
    var node = adminSummaryNode();
    if (!node) return;
    if (el.__adminSummaryNode !== node) {
      el.__adminSummaryNode = node;
      el.__adminSummaryBase = node.nodeValue;
    }
    node.nodeValue = text == null ? el.__adminSummaryBase : text;
  }

  /**
   * L2a administrative overlay. Real DOSM ADM1/ADM2 boundaries for the
   * selected jurisdiction, drawn from the pinned bytes. Independent of every
   * calculation: this function only adds layers and never touches membership.
   */
  function renderAdmin(el, m, data) {
    var admin = data.admin;
    var j = (admin && admin.jurisdiction) || {};
    var key = [admin && admin.status, admin && admin.visible, j.dosmState].join('|');
    if (el.__adminKey === key) return;

    if (el.__adminLayers) {
      el.__adminLayers.forEach(function (l) { try { m.removeLayer(l); } catch (e) { /* ignore */ } });
      el.__adminLayers = null;
    }
    el.__adminBounds = null;
    el.__adminKey = key;
    el.__adminUserFit = false;
    el.__adminFitKey = null;
    // The summary baseline is per jurisdiction, so a visibility toggle can
    // restore it; only a region change discards it.
    var summaryScope = j.dosmState || '';
    if (el.__adminSummaryScope !== summaryScope) {
      el.__adminSummaryScope = summaryScope;
      el.__adminSummaryBase = null;
      el.__adminSummaryNode = null;
    }

    if (!admin || admin.status !== ADMIN_STATUS.AVAILABLE) {
      el.setAttribute('data-admin-state', ADMIN_STATUS.UNAVAILABLE);
      updateAdminBadge(el, 'Administrative boundaries (L2a): not available for this region \u2014 nothing drawn.');
      setAdminSummary(el,
        'Administrative boundary (L2a): UNAVAILABLE for this region \u2014 nothing is drawn. ' +
        'This is not evidence that no boundary exists.');
      return;
    }
    if (admin.visible === false) {
      el.setAttribute('data-admin-state', ADMIN_STATUS.HIDDEN);
      updateAdminBadge(el, 'Administrative boundaries (L2a): hidden by the viewer.');
      setAdminSummary(el, null);
      setAdminSummary(el,
        (el.__adminSummaryBase || '') +
        ' The layer is currently hidden by the viewer, so no boundary is drawn.');
      return;
    }

    el.setAttribute('data-admin-state', ADMIN_STATUS.LOADING);
    updateAdminBadge(el, 'Administrative boundaries (L2a): loading DOSM open data\u2026');

    var src = admin.source || {};
    var adm1Url = src.adm1 && src.adm1.url;
    var adm2Url = src.adm2 && src.adm2.url;

    Promise.all([loadJson(adm1Url), loadJson(adm2Url)]).then(function (res) {
      if (!mapHealthy(el, m) || el.__adminKey !== key) return;
      var states = (res[0].features || []).filter(function (f) {
        return f.properties && f.properties.state === j.dosmState;
      });
      var districts = (res[1].features || []).filter(function (f) {
        return f.properties && f.properties.state === j.dosmState;
      });
      if (!states.length || !districts.length) {
        el.setAttribute('data-admin-state', ADMIN_STATUS.UNAVAILABLE);
        el.setAttribute('data-admin-error', 'NO_FEATURES_FOR_STATE:' + j.dosmState);
        updateAdminBadge(el, 'Administrative boundaries (L2a): the dataset has no ' +
          'features for ' + j.dosmState + ' \u2014 nothing drawn.');
        setAdminSummary(el,
          'Administrative boundary (L2a): the pinned DOSM dataset contains no features ' +
          'for ' + j.dosmState + ', so no boundary is drawn. This is not evidence that ' +
          'no boundary exists.');
        return;
      }
      var layers = [];
      var bounds = null;

      states.forEach(function (f) {
        var layer = L.geoJSON(f, {
          pane: 'adminPane',
          style: {
            color: '#243746', weight: 2.5, opacity: 0.9,
            fill: true, fillColor: '#243746', fillOpacity: 0.03,
            dashArray: '9 6',
          },
        }).addTo(m);
        layer.bindTooltip(
          'State / federal territory: ' + j.dosmState +
          ' (DOSM ADM1, code ' + j.codeState + ') \u2014 context only',
          { sticky: true }
        );
        layers.push(layer);
        bounds = bounds ? bounds.extend(layer.getBounds()) : layer.getBounds();
      });

      districts.forEach(function (f) {
        var p = f.properties || {};
        var layer = L.geoJSON(f, {
          pane: 'adminPane',
          style: { color: '#55697a', weight: 1.4, opacity: 0.9, fill: false, dashArray: '4 4' },
        }).addTo(m);
        layer.bindTooltip(
          'District: ' + p.district + ' (' + p.code_state_district +
          ') \u2014 DOSM ADM2, context only',
          { sticky: true }
        );
        layer.bindPopup(
          '<strong>' + p.district + '</strong><br>' +
          'DOSM district code: ' + p.code_state_district + '<br>' +
          'State: ' + p.state + '<br>' +
          '<em>Administrative context only \u2014 not the study zone and not counted.</em>',
          { ariaHidden: false }
        );
        layers.push(layer);
        bounds = bounds ? bounds.extend(layer.getBounds()) : layer.getBounds();
      });

      el.__adminLayers = layers;
      el.__adminBounds = bounds;
      el.setAttribute('data-admin-state', ADMIN_STATUS.READY);
      el.setAttribute('data-admin-districts', String(districts.length));
      el.setAttribute('data-admin-states', String(states.length));
      el.setAttribute('data-admin-licence', (admin.licence && admin.licence.name) || '');
      el.setAttribute('data-admin-source-sha256', (src.adm2 && src.adm2.sha256) || '');
      updateAdminBadge(el,
        'Administrative boundaries (L2a, DOSM open data): ' + j.dosmState +
        ' \u00b7 ' + districts.length + ' districts. Context only \u2014 never counted.');
      setAdminSummary(el, null);
    }).catch(function (err) {
      if (!mapHealthy(el, m) || el.__adminKey !== key) return;
      el.setAttribute('data-admin-state', ADMIN_STATUS.UNAVAILABLE);
      el.setAttribute('data-admin-error', String((err && err.message) || err));
      updateAdminBadge(el,
        'Administrative boundaries (L2a): UNAVAILABLE \u2014 not drawn. ' +
        'This is not evidence that no boundary exists.');
      setAdminSummary(el,
        'Administrative boundary (L2a): UNAVAILABLE \u2014 the pinned DOSM dataset did not load, ' +
        'so no boundary is drawn. This is not evidence that no boundary exists. ' +
        'Context only; never counted; the lower tier (ADM3) remains withheld.');
    });
  }

  function render(el) {
    try {
      var data = parse(el);
      if (!data) return;
      var m = ensureMap(el, data);
      if (!m) return;

      clearLayers(el, m);
      var layers = [];
      var pts = [];

      // --- 1. SYSTEM STUDY ZONE (solid teal, read-only) -------------------
      var zone = data.systemZone;
      if (zone && zone.visible !== false && (zone.polygons || []).length) {
        zone.polygons.forEach(function (poly) {
          var outer = toLatLngs(poly.outer);
          if (!outer.length) return;
          var holes = (poly.holes || []).map(toLatLngs).filter(function (h) {
            return h.length > 2;
          });
          var shape = L.polygon([outer].concat(holes), {
            color: '#0f5f5a',
            weight: 3,
            fillColor: '#2fa39a',
            fillOpacity: 0.22,
            // Solid outline distinguishes the zone from the dashed radius.
          }).addTo(m);
          shape.bindTooltip(ZONE_WATERMARK, {
            permanent: true,
            direction: 'center',
            className: 'geo-zone-label',
          });
          shape.bindPopup(
            '<strong>System study zone</strong><br>' +
            'ID: ' + (zone.zoneId || '') + '<br>' +
            'Rental: ' + (zone.rentalId || '') + '<br>' +
            'Rule: ' + (zone.ruleVersion || '') + '<br>' +
            'Digest: ' + (zone.hash || '') + '<br>' +
            '<em>Synthetic fixture \u2014 not an administrative boundary.</em>',
            { ariaHidden: false }
          );
          layers.push(shape);
          outer.forEach(function (p) { pts.push(p); });
        });
      }

      // --- 2. DISPLAY-ONLY radius circle (dashed) -------------------------
      var radius = data.radius;
      if (radius && radius.active && isNum(radius.lat) && isNum(radius.lng) &&
          isNum(radius.radius) && radius.radius > 0 && radius.radius <= 5000) {
        var circle = L.circle([radius.lat, radius.lng], {
          radius: radius.radius,
          color: '#8a5a00',
          fillColor: '#f0b429',
          fillOpacity: 0.06,
          weight: 2,
          dashArray: '7 6',
        }).addTo(m);
        circle.bindTooltip('Display-only radius \u2014 does not affect the count', {
          direction: 'top',
        });
        layers.push(circle);
        pts.push([radius.lat, radius.lng]);
      }

      // --- 3. SAMPLE venues (filled = inside, hollow = outside) ----------
      (data.venues || []).forEach(function (v) {
        if (v.visible === false) return;
        if (!v.sample || !isNum(v.lat) || !isNum(v.lng)) return;
        var inside = !!v.inside;
        var marker = L.circleMarker([v.lat, v.lng], {
          radius: inside ? 11 : 9,
          color: inside ? '#0b4f3f' : '#6b6b6b',
          weight: 3,
          fillColor: inside ? '#2f9e6b' : '#ffffff',
          fillOpacity: inside ? 0.95 : 0.95,
          alt: v.id + (inside ? ' \u2014 inside' : ' \u2014 outside') +
               ' the system zone (synthetic sample)',
        }).addTo(m).bindPopup(
          '<strong>' + v.id + '</strong><br>' +
          (v.category || '') + '<br>' +
          (inside ? 'INSIDE' : 'OUTSIDE') + ' the system study zone<br>' +
          '<em>Synthetic sample venue \u2014 not a real competitor.</em>',
          { ariaHidden: false }
        );
        layers.push(marker);
        pts.push([v.lat, v.lng]);
      });

      // --- 4. Selected rental marker -------------------------------------
      var rental = data.rental;
      if (rental && isNum(rental.lat) && isNum(rental.lng)) {
        var rm = L.circleMarker([rental.lat, rental.lng], {
          radius: 10,
          color: '#145b61',
          weight: 3,
          fillColor: '#65b7a5',
          fillOpacity: 1.0,
          alt: rental.id + ' \u2014 synthetic rental fixture, not an actual rental',
        }).addTo(m).bindPopup(
          '<strong>' + rental.id + '</strong><br>' +
          (rental.region || '') + '<br>' +
          '<em>Synthetic rental fixture \u2014 not an actual rental.</em>',
          { ariaHidden: false }
        );
        layers.push(rm);
        pts.push([rental.lat, rental.lng]);
      }

      // A viewer-chosen administrative fit survives later re-renders of the
      // same jurisdiction; switching region returns to the study-zone view.
      var adminData = data.admin;
      var aj = (adminData && adminData.jurisdiction) || {};
      var adminKey = [adminData && adminData.status, adminData && adminData.visible, aj.dosmState].join('|');
      var keepAdminFit = el.__adminUserFit === true && el.__adminFitKey === adminKey &&
        el.__adminBounds && el.__adminBounds.isValid();
      if (keepAdminFit) {
        m.fitBounds(el.__adminBounds, { padding: [30, 30], maxZoom: 12 });
      } else if (pts.length) {
        m.fitBounds(L.latLngBounds(pts), { padding: [40, 40], maxZoom: 16 });
      }
      renderAdmin(el, m, data);
      el.__geoLayers = layers;
      el.removeAttribute('data-geo-error');
      window.setTimeout(function () { try { m.invalidateSize(); } catch (e) {} }, 50);
    } catch (e) {
      el.setAttribute('data-geo-error', 'RENDER_FAILED:' + String(e && e.message));
    }
  }

  function mount(el) { render(el); }

  function init() {
    document.querySelectorAll('.geo-map[data-geo]').forEach(mount);
  }

  function onReady(fn) {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', fn);
    } else {
      fn();
    }
  }
  onReady(init);

  // Re-render after hydration settles (hydration can run after this script and
  // replace the container), then keep observing for later data changes.
  [300, 900, 1800, 3000].forEach(function (delay) {
    window.setTimeout(init, delay);
  });

  // Re-render when the component updates `data-geo`, when the map container's
  // children/classes are rewritten by hydration, and when the element is
  // (re)created during hydration.
  var observer = new MutationObserver(function (mutations) {
    var targets = new Set();
    mutations.forEach(function (mutation) {
      var node = mutation.target;
      if (mutation.type === 'attributes' && mutation.attributeName === 'data-geo') {
        if (node.classList && node.classList.contains('geo-map')) targets.add(node);
      } else if (mutation.type === 'childList') {
        mutation.addedNodes.forEach(function (n) {
          if (n.nodeType === 1 && n.classList && n.classList.contains('geo-map') &&
              n.hasAttribute('data-geo')) {
            targets.add(n);
          }
        });
        // Hydration wiped/replaced the map pane: the container itself is the
        // target here.
        if (node.classList && node.classList.contains('geo-map')) targets.add(node);
      }
    });
    targets.forEach(function (el) {
      // Debounce to let the current render pass finish.
      if (el.__geoPending) return;
      el.__geoPending = true;
      window.setTimeout(function () {
        el.__geoPending = false;
        render(el);
      }, 60);
    });
  });
  observer.observe(document.documentElement, {
    subtree: true,
    attributes: true,
    attributeFilter: ['data-geo', 'class'],
    childList: true,
  });
})();
