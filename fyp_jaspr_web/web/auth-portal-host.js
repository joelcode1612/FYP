/* Resizes the signup portal iframe to the active form's measured height.
   The portal (web/auth-portal.html) posts its height after load, on form
   switches, and on resize. Keeps all four forms fully visible without an
   inner scrollbar; same-origin only. */
(function () {
  'use strict';
  window.addEventListener('message', function (event) {
    if (event.origin !== window.location.origin) return;
    var data = event.data;
    if (!data || data.type !== 'sitewise:portal-height') return;
    var frame = document.getElementById('suPortalFrame');
    if (!frame || typeof data.height !== 'number') return;
    var height = Math.max(560, Math.ceil(data.height));
    frame.style.height = height + 'px';
  });
})();
