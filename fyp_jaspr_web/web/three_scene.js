/* Sitewise hero — mount when the client router creates the landing page,
   and dispose when it removes it. Fall back to CSS when WebGL is unavailable. */
(function () {
  'use strict';

  var mountedHost = null;

  /* The most recent mounted scene. Hydration can replace #concept3dScene after
     we mount, so a later start() must tear down the previous renderer instead
     of leaving a detached canvas and a second RAF loop running forever. */
  var active = null;

  function start() {
    if (active && active.dispose) {
      try { active.dispose(); } catch (e) { /* already gone */ }
    }
    active = null;
          'use strict';
          const host = document.getElementById('concept3dScene');
          if (!host) return;
          const fallback = document.getElementById('modelFallback');
          const image = document.getElementById('heroImage');
          const sceneSticky = document.getElementById('sceneSticky');
          const reducedMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    
          let THREERef = window.THREE, renderer, scene, camera, root, raf = 0, running = false;
          let pageVisible = !document.hidden, inView = true, io = null, resizeObs = null;
          let autoRotate = !reducedMotion;
          let isNightMode = false;
    
          let theta = Math.PI / 4, phi = 1.02, radius = 11.4;
          let targetTheta = theta, targetPhi = phi, targetRadius = radius;
          const target = { x: 0, y: 1.15, z: 0 };
          const goalTarget = { x: 0, y: 1.15, z: 0 };
    
          let pointerParallaxX = 0, pointerParallaxY = 0, smoothParallaxX = 0, smoothParallaxY = 0;
          let dragging = false, pointerX = 0, pointerY = 0;
          let hemiLight, keyLight, warmLight;
    
          const controls = document.getElementById('modelControls');
          const parallaxSurface = document.querySelector('.scene-sticky');
          const parallaxElements = Array.from(document.querySelectorAll('[data-parallax-depth]'));
          const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
    
          // Center 3D building cleanly between the left copy and right glass card stack
          const modelHorizontalOffset = () => window.innerWidth > 1050 ? 0.35 : 0;
          const modelBaseScale = () => window.innerWidth > 1050 ? 0.92 : (window.innerWidth > 760 ? 0.80 : 0.56);
    
          function showFallback() {
            if (fallback) fallback.hidden = false;
            if (image) image.classList.remove('hidden');
            host.classList.add('hidden');
            if (controls) controls.classList.add('hidden');
          }
          if (!THREERef) { showFallback(); return; }
          const T = THREERef;
    
          function mat(color, roughness = .72, metalness = 0, opts = {}) {
            return new T.MeshStandardMaterial({ color, roughness, metalness, ...opts });
          }
          const M = {
            road: mat(0x334155, .93), roadLine: mat(0xf8fafc, .7), curb: mat(0xf1f5f9, .9),
            pavement: mat(0xcbd5e1, .9), tile: mat(0x94a3b8, .92),
            concrete: mat(0xe2e8f0, .8), white: mat(0xf8fafc, .75), dark: mat(0x1e293b, .52), black: mat(0x0f172a, .45),
            wood: mat(0x64748b, .68), woodLight: mat(0x94a3b8, .64),
            glass: mat(0x60a5fa, .22, .1, { emissive: 0x1e3a8a, emissiveIntensity: .42 }),
            glassWarm: mat(0x38bdf8, .25, .05, { emissive: 0x0284c7, emissiveIntensity: .55 }),
            metal: mat(0x64748b, .45, .55),
            gold: mat(0x2563eb, .34, .25, { emissive: 0x1d4ed8, emissiveIntensity: .32 }),
            green: mat(0x0d9488, 1), leaf: mat(0x10b981, 1), leaf2: mat(0x34d399, 1), trunk: mat(0x475569, 1),
            planter: mat(0xe2e8f0, .9), seat: mat(0x0f172a, .7), neighbor: mat(0xcbd5e1, .85), neighborGlass: mat(0x64748b, .28, .1)
          };
    
          function labelTexture(text) {
            const c = document.createElement('canvas'); c.width = 512; c.height = 160;
            const ctx = c.getContext('2d');
            ctx.fillStyle = '#0b0f19'; ctx.fillRect(0, 0, 512, 160);
            ctx.fillStyle = '#3b82f6'; ctx.fillRect(0, 0, 14, 160);
            ctx.font = '900 90px Arial, sans-serif'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
            ctx.fillStyle = '#f8fafc'; ctx.fillText(text, 264, 84);
            const tx = new T.CanvasTexture(c); tx.colorSpace = T.SRGBColorSpace;
            return tx;
          }
    
          try {
            scene = new T.Scene();
            const aspect = Math.max(host.clientWidth, 1) / Math.max(host.clientHeight, 1);
            const fr = 5.5;
            camera = new T.OrthographicCamera(-fr * aspect, fr * aspect, fr, -fr, .1, 100);
            renderer = new T.WebGLRenderer({ antialias: true, alpha: true, powerPreference: 'high-performance' });
            renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
            renderer.setSize(Math.max(host.clientWidth, 1), Math.max(host.clientHeight, 1));
            renderer.setClearColor(0x000000, 0);
            renderer.shadowMap.enabled = true;
            renderer.shadowMap.type = T.PCFSoftShadowMap;
            renderer.outputColorSpace = T.SRGBColorSpace;
            renderer.toneMapping = T.ACESFilmicToneMapping;
            renderer.toneMappingExposure = 1.14;
            host.appendChild(renderer.domElement);
    
            hemiLight = new T.HemisphereLight(0xf8fafc, 0x475569, 2.15);
            scene.add(hemiLight);
            keyLight = new T.DirectionalLight(0xe0f2fe, 3.1);
            keyLight.position.set(-5, 10, 7);
            keyLight.castShadow = true;
            keyLight.shadow.mapSize.set(1024, 1024);
            keyLight.shadow.camera.left = -8; keyLight.shadow.camera.right = 8;
            keyLight.shadow.camera.top = 8; keyLight.shadow.camera.bottom = -8;
            keyLight.shadow.bias = -.0002;
            scene.add(keyLight);
    
            const fillLight = new T.DirectionalLight(0xdbeafe, 1.25);
            fillLight.position.set(6, 7, -5);
            scene.add(fillLight);
    
            warmLight = new T.PointLight(0x38bdf8, 1.4, 9);
            warmLight.position.set(0, 2.1, 1.2);
            scene.add(warmLight);
    
            root = new T.Group();
            root.position.x = modelHorizontalOffset();
            scene.add(root);
    
            function box(w, h, d, material, x, y, z, parent = root, opts = {}) {
              const mesh = new T.Mesh(new T.BoxGeometry(w, h, d), material);
              mesh.position.set(x, y, z);
              mesh.castShadow = opts.castShadow !== false;
              mesh.receiveShadow = opts.receiveShadow !== false;
              parent.add(mesh);
              return mesh;
            }
            function cylinder(rt, rb, h, material, x, y, z, segments = 10, parent = root) {
              const m = new T.Mesh(new T.CylinderGeometry(rt, rb, h, segments), material);
              m.position.set(x, y, z);
              m.castShadow = true; m.receiveShadow = true;
              parent.add(m);
              return m;
            }
    
            // Base road & plaza
            box(10.4, .28, 8.5, M.road, 0, .14, 0);
            box(10.2, .055, 8.3, M.curb, 0, .305, 0);
            box(8.15, .13, 5.78, M.pavement, 0, .39, -.47);
            box(7.94, .018, 5.57, M.tile, 0, .465, -.47, root, { castShadow: false });
            for (let x = -3.6; x <= 3.6; x += .6) box(.012, .008, 5.3, M.curb, x, .479, -.47, root, { castShadow: false, receiveShadow: false });
            for (let z = -3.0; z <= 2.05; z += .55) box(7.65, .008, .012, M.curb, 0, .48, z, root, { castShadow: false, receiveShadow: false });
            for (let i = 0; i < 5; i++) box(.18, .012, .65, M.roadLine, -.72 + i * .29, .341, 3.67, root, { castShadow: false, receiveShadow: false });
            for (let i = 0; i < 8; i++) box(.44, .012, .045, M.roadLine, -3.55 + i * .94, .341, 2.95, root, { castShadow: false, receiveShadow: false });
    
            function neighbour(x, z, w, d, h, variant = 0) {
              const baseY = .48 + h / 2;
              box(w, h, d, variant % 2 ? M.neighbor : M.concrete, x, baseY, z);
              const winmat = variant % 2 ? M.neighborGlass : M.glass;
              for (let yy = .48 + h * .25; yy < .48 + h - .12; yy += .38) {
                for (let xx = x - w / 2 + .16; xx < x + w / 2 - .08; xx += .27) {
                  box(.105, .15, .018, winmat, xx, yy, z + d / 2 + .012, root, { castShadow: false });
                }
              }
              box(w + .08, .08, d + .08, variant % 2 ? M.dark : M.white, x, .48 + h + .035, z);
            }
            neighbour(-3.15, -2.15, .72, .72, 1.0, 0); neighbour(-3.75, -.7, .48, .62, .76, 1);
            neighbour(3.2, -2.25, .7, .68, 1.22, 1); neighbour(3.68, -.65, .45, .6, .88, 0);
    
            // Main Commercial F&B Unit
            box(3.55, .14, 2.75, M.dark, 0, .54, -.28);
            box(3.36, .1, 2.56, M.concrete, 0, .64, -.28);
            const frontZ = 1.0;
            box(3.2, 1.20, .12, M.dark, 0, 1.29, -1.48);
            box(.13, 1.2, 2.35, M.dark, -1.59, 1.29, -.27);
            box(.13, 1.2, 2.35, M.dark, 1.59, 1.29, -.27);
            box(3.03, .08, 2.25, M.woodLight, 0, .72, -.27);
            for (let x = -1.28; x <= 1.28; x += .52) {
              box(.45, .96, .035, M.glassWarm, x, 1.28, frontZ, root, { castShadow: false });
              box(.045, 1.13, .075, M.black, x + .235, 1.28, frontZ + .025);
            }
            box(3.2, .07, .08, M.black, 0, 1.84, frontZ + .012);
            box(.42, .99, .045, M.glass, 0, 1.22, frontZ + .045, root, { castShadow: false });
            box(.025, .18, .025, M.gold, .15, 1.2, frontZ + .08, root, { castShadow: false });
    
            box(3.25, 1.08, 2.42, M.concrete, 0, 2.47, -.28);
            box(3.34, .12, 2.5, M.dark, 0, 1.93, -.28);
            box(3.18, .84, .05, M.glass, 0, 2.47, frontZ, root, { castShadow: false });
            for (let x = -1.48; x <= 1.48; x += .42) box(.055, .88, .09, M.dark, x, 2.47, frontZ + .025);
            box(3.63, .19, 2.78, M.dark, 0, 3.08, -.28);
            box(3.45, .07, 2.6, M.white, 0, 3.19, -.28);
    
            // Rooftop HVAC & Exhaust MEP
            for (const [x, z, w, d, h] of [[-.88, -.65, .66, .55, .32], [.2, -.72, .72, .5, .42], [.94, -.1, .42, .55, .28]]) {
              box(w, h, d, M.metal, x, 3.19 + h / 2, z);
              box(w * .82, .03, d * .78, M.white, x, 3.19 + h + .015, z);
            }
            box(1.02, .35, .08, M.black, 0, 1.99, 1.12);
            const sign = new T.Mesh(new T.PlaneGeometry(.93, .29), new T.MeshBasicMaterial({ map: labelTexture('F&B') }));
            sign.position.set(0, 1.99, 1.166);
            root.add(sign);
            box(3.58, .085, .56, M.woodLight, 0, 1.82, 1.3);
    
            function patioTable(x, z) {
              cylinder(.29, .29, .07, M.woodLight, x, .72, z, 18);
              cylinder(.055, .065, .48, M.dark, x, .46, z, 10);
              for (let a = 0; a < 4; a++) {
                const ang = a * Math.PI / 2;
                box(.24, .055, .24, M.seat, x + Math.cos(ang) * .43, .54, z + Math.sin(ang) * .43);
              }
              cylinder(.04, .045, .18, M.gold, x, .85, z, 10);
            }
            patioTable(-1.55, 2.0); patioTable(.05, 2.35); patioTable(1.55, 2.0);
    
            function tree(x, z, scale = 1) {
              const g = new T.Group(); g.position.set(x, .36, z); g.scale.setScalar(scale); root.add(g);
              const tr = new T.Mesh(new T.CylinderGeometry(.075, .11, .68, 7), M.trunk); tr.position.y = .34; tr.castShadow = true; g.add(tr);
              const colors = [M.leaf, M.leaf2, M.green];
              for (let i = 0; i < 3; i++) {
                const crown = new T.Mesh(new T.ConeGeometry(.48 - i * .07, .72, 7), colors[i]);
                crown.position.y = .74 + i * .3; crown.castShadow = true; g.add(crown);
              }
              box(.52, .08, .52, M.planter, x, .48, z, root, { castShadow: false });
            }
            tree(-3.45, 1.65, .8); tree(3.45, 1.55, .82); tree(-3.7, -2.45, .68); tree(3.7, -2.55, .7);
    
            const ring = new T.Mesh(new T.TorusGeometry(.34, .035, 8, 44), M.gold);
            ring.rotation.x = -Math.PI / 2; ring.position.set(0, .505, 2.95); root.add(ring);
            const pinStem = new T.Mesh(new T.ConeGeometry(.12, .36, 16), M.gold); pinStem.position.set(0, .77, 2.95); root.add(pinStem);
            const pinBall = new T.Mesh(new T.SphereGeometry(.105, 16, 12), M.gold); pinBall.position.set(0, .94, 2.95); root.add(pinBall);
    
            const ground = new T.Mesh(new T.PlaneGeometry(200, 200), new T.ShadowMaterial({ opacity: .10 }));
            ground.rotation.x = -Math.PI / 2; ground.position.y = -.018; ground.receiveShadow = true; scene.add(ground);
    
            function updateCamera() {
              theta += (targetTheta - theta) * 0.08;
              phi += (targetPhi - phi) * 0.08;
              radius += (targetRadius - radius) * 0.08;
              target.x += (goalTarget.x - target.x) * 0.08;
              target.y += (goalTarget.y - target.y) * 0.08;
              target.z += (goalTarget.z - target.z) * 0.08;
    
              const viewTheta = theta + smoothParallaxX * 0.14;
              const viewPhi = clamp(phi + smoothParallaxY * 0.06, 0.38, 1.48);
              const x = target.x + radius * Math.sin(viewPhi) * Math.sin(viewTheta);
              const y = target.y + radius * Math.cos(viewPhi);
              const z = target.z + radius * Math.sin(viewPhi) * Math.cos(viewTheta);
              camera.position.set(x, y, z);
              camera.lookAt(target.x, target.y, target.z);
              camera.updateProjectionMatrix();
            }
    
            function resize() {
              if (!renderer || !camera) return;
              const w = Math.max(host.clientWidth, 1), h = Math.max(host.clientHeight, 1);
              renderer.setSize(w, h, false);
              const a = w / h;
              const frame = (window.innerWidth <= 760 ? 6.2 : (window.innerWidth <= 1050 ? 5.8 : fr));
              camera.left = -frame * a; camera.right = frame * a; camera.top = frame; camera.bottom = -frame;
              camera.updateProjectionMatrix();
              if (root) root.position.x = modelHorizontalOffset();
            }
    
            function tick() {
              raf = 0;
              if (!running) return;
              // Stop scheduling work while the hero is off-screen or the tab is
              // hidden; `ensureLoop()` resumes it when either condition clears.
              if (!pageVisible || !inView) return;
              raf = requestAnimationFrame(tick);
              smoothParallaxX += (pointerParallaxX - smoothParallaxX) * 0.05;
              smoothParallaxY += (pointerParallaxY - smoothParallaxY) * 0.05;
              for (const el of parallaxElements) {
                const depth = Number(el.dataset.parallaxDepth) || .5;
                el.style.setProperty('--sitewise-parallax-x', (smoothParallaxX * 12 * depth).toFixed(2) + 'px');
                el.style.setProperty('--sitewise-parallax-y', (smoothParallaxY * 8 * depth).toFixed(2) + 'px');
              }
              if (autoRotate && !dragging) targetTheta += .0014;
              const t = performance.now() * 0.001;
              root.position.x = modelHorizontalOffset();
              root.position.y = .03 + Math.sin(t * .75) * .03;
              root.scale.setScalar(modelBaseScale());
              updateCamera();
              renderer.render(scene, camera);
            }

            function ensureLoop() {
              if (!running || raf) return;
              if (!pageVisible || !inView) return;
              raf = requestAnimationFrame(tick);
            }

            function onVisibility() {
              pageVisible = !document.hidden;
              if (pageVisible && inView) ensureLoop();
            }
            document.addEventListener('visibilitychange', onVisibility);

            function dispose() {
              running = false;
              if (raf) { cancelAnimationFrame(raf); raf = 0; }
              if (io) { io.disconnect(); io = null; }
              if (resizeObs) { resizeObs.disconnect(); resizeObs = null; }
              window.removeEventListener('resize', resize);
              document.removeEventListener('visibilitychange', onVisibility);
              if (scene) {
                const disposed = new Set();
                scene.traverse(function (object) {
                  if (object.geometry && !disposed.has(object.geometry)) {
                    disposed.add(object.geometry);
                    object.geometry.dispose();
                  }
                  const materials = Array.isArray(object.material) ? object.material : [object.material];
                  materials.forEach(function (material) {
                    if (!material || disposed.has(material)) return;
                    disposed.add(material);
                    Object.values(material).forEach(function (value) {
                      if (value && value.isTexture && !disposed.has(value)) {
                        disposed.add(value);
                        value.dispose();
                      }
                    });
                    material.dispose();
                  });
                });
              }
              delete window.setSitewiseCameraPreset;
              if (renderer) {
                renderer.dispose();
                const cv = renderer.domElement;
                if (cv && cv.parentNode) cv.parentNode.removeChild(cv);
              }
              renderer = null;
            }
    
            const PRESETS = {
              overview: { theta: Math.PI / 4, phi: 1.02, radius: 11.4, y: 1.15 },
              frontage: { theta: 0.08, phi: 1.22, radius: 8.8, y: 1.35 },
              patio: { theta: -0.45, phi: 1.08, radius: 9.2, y: 0.95 },
              rooftop: { theta: 0.68, phi: 0.65, radius: 9.4, y: 2.35 }
            };
    
            window.setSitewiseCameraPreset = function (presetKey) {
              const p = PRESETS[presetKey] || PRESETS.overview;
              autoRotate = presetKey === 'overview';
              const autoBtn = controls && controls.querySelector('[data-model-action="auto"]');
              if (autoBtn) autoBtn.setAttribute('aria-pressed', String(autoRotate));
              targetTheta = p.theta;
              targetPhi = p.phi;
              targetRadius = p.radius;
              goalTarget.y = p.y;
              document.querySelectorAll('[data-cam-preset]').forEach(btn => {
                btn.classList.toggle('active', btn.dataset.camPreset === presetKey);
              });
            };
    
            function toggleLightingMode(btn) {
              isNightMode = !isNightMode;
              if (sceneSticky) sceneSticky.classList.toggle('night-mode', isNightMode);
              if (btn) {
                btn.setAttribute('aria-pressed', String(isNightMode));
                btn.textContent = isNightMode ? '☾ Evening' : '☀ Day';
              }
              hemiLight.intensity = isNightMode ? 0.65 : 2.15;
              keyLight.intensity = isNightMode ? 1.1 : 3.1;
              warmLight.intensity = isNightMode ? 3.8 : 1.4;
              M.glassWarm.emissiveIntensity = isNightMode ? 1.45 : 0.55;
              M.glass.emissiveIntensity = isNightMode ? 0.95 : 0.42;
            }
    
            const canvas = renderer.domElement;
            canvas.addEventListener('pointerdown', e => {
              dragging = true; pointerX = e.clientX; pointerY = e.clientY;
              canvas.setPointerCapture(e.pointerId);
              autoRotate = false;
              const b = controls && controls.querySelector('[data-model-action="auto"]');
              if (b) b.setAttribute('aria-pressed', 'false');
            });
            canvas.addEventListener('pointermove', e => {
              if (!dragging) return;
              const dx = e.clientX - pointerX, dy = e.clientY - pointerY;
              pointerX = e.clientX; pointerY = e.clientY;
              targetTheta -= dx * .008;
              targetPhi = clamp(targetPhi + dy * .007, .38, 1.48);
            });
            const stopDrag = () => { dragging = false; };
            canvas.addEventListener('pointerup', stopDrag);
            canvas.addEventListener('pointercancel', stopDrag);
    
            if (controls) {
              controls.addEventListener('click', e => {
                const b = e.target.closest('button[data-model-action]');
                if (!b) return;
                const act = b.dataset.modelAction;
                if (act === 'zoom-in') targetRadius = clamp(targetRadius * .86, 7.5, 16.5);
                if (act === 'zoom-out') targetRadius = clamp(targetRadius * 1.15, 7.5, 16.5);
                if (act === 'auto') { autoRotate = !autoRotate; b.setAttribute('aria-pressed', String(autoRotate)); }
                if (act === 'lighting') toggleLightingMode(b);
                if (act === 'reset') window.setSitewiseCameraPreset('overview');
              });
            }
    
            (parallaxSurface || host).addEventListener('pointermove', e => {
              if (dragging || (e.pointerType && e.pointerType !== 'mouse')) return;
              const r = (parallaxSurface || host).getBoundingClientRect();
              if (!r.width || !r.height) return;
              pointerParallaxX = clamp(((e.clientX - r.left) / r.width - .5) * 2, -1, 1);
              pointerParallaxY = clamp(((e.clientY - r.top) / r.height - .5) * 2, -1, 1);
            }, { passive: true });
    
            if ('ResizeObserver' in window) {
              resizeObs = new ResizeObserver(resize);
              resizeObs.observe(host);
            } else {
              window.addEventListener('resize', resize);
            }

            if ('IntersectionObserver' in window) {
              io = new IntersectionObserver(function (entries) {
                inView = entries[0].isIntersecting;
                if (inView) ensureLoop();
              }, { threshold: 0 });
              io.observe(host);
            }

            running = true;
            active = { dispose: dispose };
            resize();
            ensureLoop();
          } catch (err) {
            console.warn('3D scene fallback:', err);
            showFallback();
          }
  }

  function reconcile() {
    var host = document.getElementById('concept3dScene');
    if (host === mountedHost) return;
    mountedHost = host;
    if (active && active.dispose) active.dispose();
    active = null;
    if (host) start();
  }
  var scheduled = false;
  new MutationObserver(function () {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(function () {
      scheduled = false;
      reconcile();
    });
  }).observe(document.body, { childList: true, subtree: true });
  reconcile();
})();

/* Glass cards: focus the 3D camera on the card target view (guarded). */
(function () {
  document.addEventListener('click', function (event) {
      var card = event.target.closest && event.target.closest('.glass-card');
      if (!card) return;
      Array.prototype.forEach.call(document.querySelectorAll('.glass-card'), function (c) { c.classList.remove('active'); });
      card.classList.add('active');
      var focus = card.getAttribute('data-card-focus');
      if (focus && window.setSitewiseCameraPreset) window.setSitewiseCameraPreset(focus);
  });
})();
