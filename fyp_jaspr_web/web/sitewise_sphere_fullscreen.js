/* SITEWISE_ADMIN_REVIEW_UI_V1 — no panorama reload or reparenting. */
(() => {
  'use strict';
  const button = document.getElementById('sphere-fullscreen');
  const viewer = document.getElementById('viewer');
  const note = document.getElementById('sphere-fullscreen-note');
  if (!button || !viewer) return;
  let frame = null, parentDoc = null, parentWin = null;
  try {
    frame = window.frameElement;
    if (frame) { parentDoc = window.parent.document; parentWin = window.parent; }
  } catch (_) { frame = null; parentDoc = null; parentWin = null; }
  let fallback = false, changing = false;
  const nativeActive = () => Boolean(document.fullscreenElement || document.webkitFullscreenElement ||
    (parentDoc && frame && (parentDoc.fullscreenElement === frame || parentDoc.webkitFullscreenElement === frame)));
  const active = () => fallback || nativeActive();
  const update = () => {
    const expanded = active();
    button.textContent = expanded ? '⛶ Exit full screen' : '⛶ Full screen';
    button.setAttribute('aria-label', expanded ? 'Exit full screen' : 'Enter full screen');
    button.setAttribute('aria-pressed', String(expanded));
    // Existing viewer's ResizeObserver adjusts the projection and retains yaw,
    // pitch and zoom. No new renderer, iframe or image request is created.
    window.dispatchEvent(new Event('resize'));
  };
  function message(text) { if (note) { note.textContent=text; note.hidden=!text; } }
  function closeFallback() {
    if (!fallback) return;
    fallback=false;
    if (frame) frame.classList.remove('sw-sphere-expanded');
    update();
  }
  async function toggle() {
    if (changing) return;
    changing=true;
    message('');
    try {
      if (fallback) { closeFallback(); return; }
      if (nativeActive()) {
        const doc = document.fullscreenElement || document.webkitFullscreenElement ? document : parentDoc;
        const exit = doc && (doc.exitFullscreen || doc.webkitExitFullscreen);
        if (exit) await Promise.resolve(exit.call(doc));
        return;
      }
      // Prefer native full screen on the original iframe (same-origin).
      const target = frame || document.documentElement;
      const request = target.requestFullscreen || target.webkitRequestFullscreen;
      if (request) {
        try { await Promise.resolve(request.call(target)); if (nativeActive()) return; }
        catch (_) { /* Browser may deny fullscreen; keep same iframe. */ }
      }
      // Only enable CSS fallback on the scoped admin page with our stylesheet.
      if (frame && parentDoc && frame.closest('.sw-admin-review-v2')) {
        fallback=true; frame.classList.add('sw-sphere-expanded');
      } else {
        const childRequest = document.documentElement.requestFullscreen || document.documentElement.webkitRequestFullscreen;
        if (frame && childRequest) {
          try { await Promise.resolve(childRequest.call(document.documentElement)); if (nativeActive()) return; } catch (_) {}
        }
        message('Full screen is unavailable in this browser.');
      }
    } catch (_) { message('Unable to change full screen mode.'); }
    finally { changing=false; update(); button.focus({preventScroll:true}); }
  }
  function escape(event) { if (event.key === 'Escape' && fallback) { event.preventDefault(); closeFallback(); button.focus({preventScroll:true}); } }
  button.addEventListener('click', toggle);
  viewer.addEventListener('dblclick', (event) => { event.preventDefault(); toggle(); });
  document.addEventListener('keydown', escape);
  document.addEventListener('fullscreenchange', update);
  document.addEventListener('webkitfullscreenchange', update);
  if (parentDoc) {
    parentDoc.addEventListener('keydown', escape);
    parentDoc.addEventListener('fullscreenchange', update);
    parentDoc.addEventListener('webkitfullscreenchange', update);
  }
  window.addEventListener('pagehide', () => {
    if (frame) frame.classList.remove('sw-sphere-expanded');
    if (parentDoc) {
      parentDoc.removeEventListener('keydown', escape);
      parentDoc.removeEventListener('fullscreenchange', update);
      parentDoc.removeEventListener('webkitfullscreenchange', update);
    }
  }, {once:true});
  update();
})();

/* SITEWISE_INSPECTION_DISPLAY_V4 BEGIN: classify existing admin DOM for CSS.
 * No text, event handlers, backend state or DOM structure is replaced.
 * Scope to same-origin admin listing review only. */
(() => {
  'use strict';
  let frame, doc, path;
  try {
    frame = window.frameElement;
    if (!frame) return;
    doc = window.parent.document;
    path = window.parent.location.pathname.replace(/\/+$/, '');
    if (!['/admin/listing-detail', '/admin/verification-detail', '/admin/listings'].includes(path)) return;
  } catch (_) { return; }
  const clean = (v) => (v || '').replace(/\s+/g, ' ').trim().toLowerCase();
  const words = (el) => clean(el && el.textContent);
  const textNodes = (el) => Array.from(el.querySelectorAll('h1,h2,h3,h4,h5,span,strong,p,div,small,label,dt,dd,button,a'));
  function matchText(el, predicate) {
    const hits = textNodes(el).filter(n => predicate(words(n)));
    // Smallest matching element, so a wrapping div is never mistaken for a label.
    return hits.find(n => !hits.some(other => other !== n && n.contains(other))) || null;
  }
  const isTitle = t => t === '360° property inspection' || t === '360° panorama (sitewise)' || t === '360° inspection viewer';
  function findPanel() {
    // The actual local inspection panel may be a section or an ordinary card.
    // Never classify the entire main column, page shell, or decision sidebar.
    for (let n = frame.parentElement; n && n !== doc.body; n = n.parentElement) {
      if (n.matches('.vd-main,.vd-layout,.vd,.sw-admin-review-v2,.app-shell')) break;
      if (matchText(n, isTitle)) return n;
    }
    const card = frame.closest('.card,.vd-panel');
    return card && !card.matches('.vd-main,.vd-layout,.vd') ? card : null;
  }
  function mark() {
    if (!frame.isConnected) return false;
    const panel = findPanel();
    if (!panel) return false;
    frame.classList.add('sw-inspect-frame');
    panel.classList.add('sw-inspect-panel');
    let n = frame.parentElement;
    if (n && n !== panel) {
      n.classList.add('sw-inspect-stage');
      for (n = n.parentElement; n && n !== panel; n = n.parentElement) {
        n.classList.add('sw-inspect-stage-path');
      }
    }
    const title = matchText(panel, isTitle);
    const eyebrow = matchText(panel, t => t === 'inspection evidence');
    const review = matchText(panel, t => t === 'panorama review');
    if (title) title.classList.add('sw-inspect-heading');
    if (eyebrow) eyebrow.classList.add('sw-inspect-eyebrow');
    if (review) review.classList.add('sw-inspect-review-title');
    const descriptions = [
      'review the submitted interior panorama before recording a decision.',
      'drag to look around. use the viewer controls to zoom or reset.',
      'this decision is separate from listing and ownership verification.'
    ];
    for (const phrase of descriptions) {
      const el = matchText(panel, t => t === phrase);
      if (el) el.classList.add('sw-inspect-description');
    }
    const header = title && title.parentElement;
    if (header && header !== panel && !header.contains(frame) && (!eyebrow || header.contains(eyebrow))) header.classList.add('sw-inspect-header');
    const status = matchText(panel, t => ['approved','pending','under review','rejected','not submitted','pending review','information requested'].includes(t));
    if (status) {
      status.classList.add('sw-inspect-badge');
      status.classList.remove('is-approved','is-pending','is-rejected');
      const val = words(status);
      status.classList.add(val === 'approved' ? 'is-approved' : val === 'rejected' ? 'is-rejected' : 'is-pending');
    }
    const rows = [];
    for (const name of ['resolution','publication']) {
      const label = matchText(panel, t => t === name || t === name + ':');
      if (!label) continue;
      const row = label.parentElement;
      if (!row || row === panel || row.contains(frame) || row.querySelector('button,a,input,textarea,select') || (review && row.contains(review))) continue;
      // Only a local label/value pair. Do not turn a whole section into a card.
      if (row.children.length !== 2 || !words(row).startsWith(name) || words(row) === words(label)) continue;
      label.classList.add('sw-inspect-meta-label');
      row.classList.add('sw-inspect-meta-item');
      const value = Array.from(row.children).find(el => el !== label && !el.contains(label));
      if (value) value.classList.add('sw-inspect-meta-value');
      rows.push(row);
    }
    if (rows.length === 2 && rows[0].parentElement === rows[1].parentElement) {
      const group = rows[0].parentElement;
      if (group !== panel && !group.contains(frame) && group.children.length === 2) group.classList.add('sw-inspect-meta');
    }
    const reviewBlock = review && review.parentElement;
    if (reviewBlock && reviewBlock !== panel && !reviewBlock.contains(frame) && reviewBlock.querySelector('button,a')) reviewBlock.classList.add('sw-inspect-review');
    for (const btn of panel.querySelectorAll('button,a')) {
      const t = words(btn);
      if (['expand viewer','full screen','fullscreen','view full screen'].includes(t)) btn.classList.add('sw-inspect-expand');
      if (['publish to buyers','publish 360° tour','unpublish','approve','approve panorama','reject','reject panorama','confirm rejection','re-review (approve)'].includes(t)) btn.classList.add('sw-inspect-action');
      if (['publish to buyers','publish 360° tour'].includes(t)) btn.classList.add('sw-inspect-publish');
    }
    return true;
  }
  // The iframe may finish before Jaspr hydration. Observe only the panel once
  // discovered; reconnect on a replacement via the next iframe load. No polling.
  let observer;
  function start() {
    if (!mark()) return;
    const panel = findPanel();
    if (!panel) return;
    if (observer) observer.disconnect();
    observer = new MutationObserver(() => mark());
    observer.observe(panel, {childList:true,subtree:true,characterData:true});
  }
  start();
  if (doc.readyState === 'loading') doc.addEventListener('DOMContentLoaded', start, {once:true});
  window.addEventListener('pagehide', () => { if (observer) observer.disconnect(); }, {once:true});
})();
/* SITEWISE_INSPECTION_DISPLAY_V4 END */
