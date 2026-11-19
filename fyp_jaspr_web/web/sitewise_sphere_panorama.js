/* SiteWise: standalone touch/mouse/keyboard panorama viewer.
 * Uses the existing first-party /vendor/three.min.js, no CDN or API key.
 * Source URL is passed as a fragment (#image=...) to keep signed image query
 * strings out of server access logs. Requires a real equirectangular image.
 */
(() => {
  'use strict';
  const root = document.getElementById('viewer');
  const status = document.getElementById('status');
  const showError = (message) => { status.textContent = message; status.hidden = false; };
  if (!root || !window.THREE) {
    showError('360° viewer could not start. Your browser may not support WebGL.');
    return;
  }
  const args = new URLSearchParams(location.hash.slice(1));
  const supplied = (args.get('image') || '').trim();
  let imageUrl;
  try {
    // A file path, data URI, or javascript: URL is NOT a published panorama.
    imageUrl = new URL(supplied, location.origin);
    if (!supplied || !['http:', 'https:'].includes(imageUrl.protocol) || supplied.startsWith('//')) {
      throw new Error('Invalid panorama URL');
    }
  } catch (_) {
    showError('No browser-accessible 360° panorama is available for this property.');
    return;
  }

  const T = window.THREE;
  let renderer;
  try {
    renderer = new T.WebGLRenderer({ alpha: false, antialias: true, powerPreference: 'low-power' });
    renderer.setClearColor(0x0b0f19, 1);
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  } catch (_) {
    showError('360° viewer needs WebGL support. Try a browser with hardware acceleration.');
    return;
  }
  root.appendChild(renderer.domElement);
  const scene = new T.Scene();
  const camera = new T.PerspectiveCamera(80, 1, 0.1, 1100);
  const geometry = new T.SphereGeometry(500, 64, 40);
  geometry.scale(-1, 1, 1); // Look outward from inside the textured sphere.
  let mesh = null;
  let yaw = 0;
  let pitch = 0;
  let fov = 80;
  const clamp = (x, min, max) => Math.min(max, Math.max(min, x));
  const radians = (degrees) => degrees * Math.PI / 180;
  function paint() {
    const lat = radians(pitch);
    const lon = radians(yaw);
    camera.lookAt(new T.Vector3(
      Math.cos(lat) * Math.sin(lon),
      Math.sin(lat),
      Math.cos(lat) * Math.cos(lon)
    ));
    renderer.render(scene, camera);
  }
  function resize() {
    const width = Math.max(1, root.clientWidth);
    const height = Math.max(1, root.clientHeight);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
    renderer.setSize(width, height, false);
    paint();
  }
  function zoom(nextFov) {
    fov = clamp(nextFov, 34, 95);
    camera.fov = fov;
    camera.updateProjectionMatrix();
    paint();
  }
  document.getElementById('zoom-in').addEventListener('click', () => zoom(fov - 10));
  document.getElementById('zoom-out').addEventListener('click', () => zoom(fov + 10));
  document.getElementById('reset').addEventListener('click', () => {
    yaw = 0; pitch = 0; zoom(80);
  });

  // Track each pointer separately. One finger/mouse rotates; two fingers zoom.
  const pointers = new Map();
  let pinchDistance = 0;
  function spacing() {
    const pair = [...pointers.values()];
    if (pair.length < 2) return 0;
    return Math.hypot(pair[0].x - pair[1].x, pair[0].y - pair[1].y);
  }
  root.addEventListener('pointerdown', (event) => {
    if (event.pointerType === 'mouse' && event.button !== 0) return;
    root.setPointerCapture(event.pointerId);
    pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
    pinchDistance = spacing();
    root.classList.add('dragging');
    event.preventDefault();
  });
  root.addEventListener('pointermove', (event) => {
    const old = pointers.get(event.pointerId);
    if (!old) return;
    pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
    if (pointers.size >= 2) {
      const distance = spacing();
      if (distance > 0 && pinchDistance > 0) zoom(fov * pinchDistance / distance);
      pinchDistance = distance;
    } else {
      // Unlimited yaw: passing +360° or -360° wraps naturally on the sphere.
      yaw -= (event.clientX - old.x) * 0.22;
      pitch = clamp(pitch + (event.clientY - old.y) * 0.22, -85, 85);
      paint();
    }
    event.preventDefault();
  });
  function release(event) {
    pointers.delete(event.pointerId);
    if (root.hasPointerCapture(event.pointerId)) root.releasePointerCapture(event.pointerId);
    pinchDistance = spacing();
    if (pointers.size === 0) root.classList.remove('dragging');
  }
  root.addEventListener('pointerup', release);
  root.addEventListener('pointercancel', release);
  root.addEventListener('lostpointercapture', release);
  root.addEventListener('wheel', (event) => {
    event.preventDefault();
    zoom(fov + Math.sign(event.deltaY) * 3);
  }, { passive: false });
  root.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowLeft') yaw += 5;
    else if (event.key === 'ArrowRight') yaw -= 5;
    else if (event.key === 'ArrowUp') pitch = clamp(pitch + 5, -85, 85);
    else if (event.key === 'ArrowDown') pitch = clamp(pitch - 5, -85, 85);
    else if (event.key === '+' || event.key === '=') zoom(fov - 7);
    else if (event.key === '-') zoom(fov + 7);
    else if (event.key.toLowerCase() === 'r' || event.key === 'Home') {
      yaw = 0; pitch = 0; zoom(80);
    } else return;
    event.preventDefault();
    paint();
  });

  const loader = new T.TextureLoader();
  loader.setCrossOrigin('anonymous');
  loader.load(imageUrl.href, (texture) => {
    if (T.SRGBColorSpace) texture.colorSpace = T.SRGBColorSpace;
    else if (T.sRGBEncoding) texture.encoding = T.sRGBEncoding;
    mesh = new T.Mesh(geometry, new T.MeshBasicMaterial({ map: texture }));
    scene.add(mesh);
    status.hidden = true;
    resize();
  }, undefined, () => {
    showError('Could not load this 360° photo. Check its URL and image CORS settings.');
  });
  if (window.ResizeObserver) new ResizeObserver(resize).observe(root);
  else window.addEventListener('resize', resize);
  // Avoid a long-lived animation loop: redraw on actual interactions only.
  window.addEventListener('pagehide', () => {
    if (mesh) {
      if (mesh.material.map) mesh.material.map.dispose();
      mesh.material.dispose();
    }
    geometry.dispose();
    renderer.dispose();
  }, { once: true });
})();
