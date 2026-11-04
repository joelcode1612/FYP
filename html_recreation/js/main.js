/* Sitewise landing recreation — interactions.
   Mirrors the production site's behaviour: mobile menu toggle and
   scroll-reveal animations. Smooth scrolling itself is pure CSS. */

(function () {
  'use strict';

  // ---- Mobile navigation ------------------------------------------------
  var menuBtn = document.getElementById('menuBtn');
  var mobileNav = document.getElementById('mobileNav');

  menuBtn.addEventListener('click', function () {
    var open = mobileNav.classList.toggle('open');
    menuBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
  });

  // Close the mobile menu when a link inside it is used.
  mobileNav.addEventListener('click', function (event) {
    if (event.target.tagName === 'A') {
      mobileNav.classList.remove('open');
      menuBtn.setAttribute('aria-expanded', 'false');
    }
  });

  // ---- Scroll-reveal ------------------------------------------------------
  var revealables = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window) {
    var observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add('in');
            observer.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.12 }
    );
    revealables.forEach(function (el) { observer.observe(el); });
  } else {
    revealables.forEach(function (el) { el.classList.add('in'); });
  }
})();
