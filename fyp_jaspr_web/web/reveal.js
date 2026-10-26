/* Sitewise — letter-reveal trigger.
 *
 * `LetterRevealHeading` renders the character spans in the component tree, so
 * this script never touches markup. It only toggles two classes on headings
 * using the `.lr--scroll` variant:
 *
 *   .is-armed    -> characters start hidden (see styles.css)
 *   .is-visible  -> characters transition in, staggered by `--i`
 *
 * Above-the-fold headings use `.lr--load` and animate through CSS alone, so
 * they are never armed and cannot flash.
 *
 * Design notes:
 *  - One observer for the whole page, created once. It unobserves each heading
 *    after it reveals, so scrolling back up does not restart the animation and
 *    no animation loop is left running.
 *  - Headings already on screen when this runs are left visible (not armed):
 *    arming them would produce a visible "hide then reveal" flicker.
 *  - Progressive enhancement: no IntersectionObserver, reduced motion, or any
 *    thrown error leaves the headings plainly readable.
 *  - Runs on `load` + 250 ms so Jaspr's first client render has settled and
 *    cannot wipe the classes.
 */
(function () {
  'use strict';

  var SELECTOR = '.lr--scroll';

  function init() {
    if (!('IntersectionObserver' in window)) return;
    if (
      window.matchMedia &&
      window.matchMedia('(prefers-reduced-motion: reduce)').matches
    ) {
      return;
    }

    var targets = Array.prototype.slice.call(
      document.querySelectorAll(SELECTOR)
    );
    if (!targets.length) return;

    var io = new IntersectionObserver(
      function (entries) {
        for (var i = 0; i < entries.length; i++) {
          var entry = entries[i];
          if (!entry.isIntersecting) continue;
          entry.target.classList.add('is-visible');
          io.unobserve(entry.target);
        }
      },
      { threshold: 0.2, rootMargin: '0px 0px -8% 0px' }
    );

    var viewportHeight = window.innerHeight || document.documentElement.clientHeight;

    try {
      for (var t = 0; t < targets.length; t++) {
        var el = targets[t];
        var rect = el.getBoundingClientRect();
        // Already on screen: leave it visible rather than hiding and
        // re-revealing it, which would read as a flicker.
        if (rect.top < viewportHeight && rect.bottom > 0) continue;
        el.classList.add('is-armed');
        io.observe(el);
      }
    } catch (err) {
      // Never leave a heading hidden because of an error.
      for (var u = 0; u < targets.length; u++) {
        targets[u].classList.remove('is-armed');
      }
    }
  }

  function boot() {
    window.setTimeout(init, 250);
  }

  if (document.readyState === 'complete') boot();
  else window.addEventListener('load', boot);
})();
