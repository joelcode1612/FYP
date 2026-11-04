# Sitewise Landing — Static HTML Recreation

A plain HTML/CSS/JS recreation of the Sitewise marketing landing page
(the page served at `/` by the Jaspr app in `fyp_jaspr_web`), built for
demonstration purposes. It reuses only the project's own public copy and its
brand-mark image; the interactive map scene and 360° panorama are replaced
with lightweight CSS placeholders.

## Files

```
html_recreation/
├── index.html          # the whole landing page (semantic markup)
├── css/styles.css      # design tokens + layout, responsive
├── js/main.js          # mobile menu toggle + scroll-reveal
└── assets/sitewise-mark-64.png   # copied from the project's public assets
```

## Run it

Option A — just open it:

    double-click index.html   (works from file://)

Option B — serve it (recommended so fonts/asset caching behave like production):

    cd C:\Users\Lenovo\AndroidStudioProjects\FYP\html_recreation
    python -m http.server 8300
    # open http://localhost:8300

## What matches the original

* The exact design tokens (`--lnd-*` palette, Archivo font, Material Symbols)
* The fixed top bar: brand mark + wordmark + tagline, four section links,
  Sign in / Sign up actions, mobile ☰ menu
* Hero copy: eyebrow, headline with emphasised phrase, lead, both CTAs, note
* Role cards (Entrepreneurs / Property Owners)
* The four numbered "How it works" steps
* The four "Location intelligence" feature cards
* The worked assessment example: score ring (86), drivers incl. the
  trade-off item, factor weights, site profile
* Recommendation cards, 360° tour placeholder band, CTA band
* The full footer (Explore / Get started / Note / base line)
* Responsive behaviour (3 breakpoints) and scroll-reveal animations
