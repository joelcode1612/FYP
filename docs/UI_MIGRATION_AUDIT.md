# UI Migration Audit — source design → Jaspr web target

Audit and implementation record for the source-to-target UI migration.
**Source:** `C:\Users\Lenovo\WorkBuddy AI\new UI design` (37 HTML pages, 8 stylesheets)
**Target:** `fyp_jaspr_web` (27 page files, 28 routes, `web/styles.css`)

This document supersedes the "six shared components" status: those were the starting
point, not the scope. Everything below was found by auditing the repository, not by
matching class names.

---

## 1. Source-to-target mapping

Mapping rules applied: source and target class names are **not** required to match;
each source element was mapped to the target component that performs the same function
and then styled to the source's computed appearance using the target's tokens.

### 1.1 Component / CSS vocabulary

| Source (CSS class) | Source location | Target implementation | Status |
|---|---|---|---|
| `:root` tokens | `theme.css` | `styles.css :root` (`--action`, `--success`, …) | Verified (values already applied) |
| `.btn` + `.primary` / `.accent` / `.sm` / `.lg` / `.icon-btn` | `theme.css` §2 | `.btn`, `.btn--primary`, `.btn--accent`, `.btn--secondary`, `.btn.sm`, `.btn.lg`, `.btn.icon-btn` | Verified |
| `.pillnav`, `.pillnav-link.is-active`, `.pillnav-icon`, `.pillnav-account`, `.pillnav-avatar` | `shared/pill-nav.css` | `.app-pill`, `.app-pill__link--active`, `.icon-btn`, `.avatar-menu__trigger`, `.avatar` | Verified |
| `.brand`, `.brand-icon`, `.brand small` | `theme.css` / `pill-nav.css` | `.brand`, `.brand__mark`, `.brand__name`, `.brand__sub` | Verified |
| `.hero`, `.hero-grid`, `.hero-eyebrow`, `.hero-actions`, `.hero-proof`, `.hero-visual`, `.plate`, `.float-card` | `theme.css` §3 | same names in the landing section | Verified |
| `.section-head`, `.eyebrow` | `theme.css` §4 | `.section-head`, `.eyebrow` | Verified |
| `.panel`, `.panel > h2`, `.panel:hover` | `theme.css` §5 / `app.css` | `.panel`, `.panel--flush`, `.panel > h2` | Verified |
| `.card`, `.card .kicker`, `.card h4`, `.card p` | `theme.css` §5 | `.card`, `.kicker`, `.card h4`, `.card p` | Verified |
| `.metric-card` (`.k`/`.v`/`.n`) | `app.css` | `.metric-card` + `.metrics` (alias `.stat-grid`) | Verified |
| `.pgrid`, `.pcard` + `.pcard-media/.cover/.body/.addr/.pcard-price/.pcard-attrs/.badges/.actions` | `app.css` + `cards.js` | same names in `PropertyCard` | Verified |
| `.badge` + `-det/-ml/-warn/-danger/-muted` | `app.css` | `.badge` + `-det/-info/-warn/-danger/-muted` | Verified (see note) |
| `.st` + `-muted/-info/-det/-warn/-danger` | `owner.css` | `.st` + same tones | Verified |
| `.prov`, `.prov-admin/-model/-demo` | `app.css` | `.prov` + same tones | Verified (ported) |
| `.v-missing`, `.v-zero`, `.v-unavailable`, `.v-note` | `app.css` | same names | Verified (ported) |
| `.notice`, `.notice-warn/-info/-danger` | `app.css` | same names | Verified (ported) |
| `.disclaimer` | `app.css` | `.disclaimer` | Verified (ported) |
| `.tag`, `.tag.det/.ml/.warn/.danger` | `theme.css` §5 | same names | Verified (ported) |
| `.empty` (dashed border, white) | `app.css` | `.empty` + `.empty__title/__body/__action` | Verified |
| `.loading`, `.spinner` | `app.css` | same names | Verified (ported) |
| `.filters`, `.frow`, `.field`, `.field label`, `.field .hint`, `.field .err`, `.checkpill`, `.chips`, `.chip`, `.actions-row` | `app.css` | same names | Verified |
| `.detail-grid`, `.analysis`, `.kv`, `.gallery` | `app.css` | same names | Verified (ported) |
| `.a-card`, `.stat-row`, `.stat` | `app.css` | same names | Verified (ported) |
| `.rec-item`, `.rec-rank`, `.rec-score` | `app.css` | same names | Verified (ported) |
| `.contrib`, `.contrib-row`, `.bar` | `app.css` | same names | Verified (ported) |
| `.compare-table` | `app.css` | `.compare-table` | Verified (ported) |
| `.tour-stage`, `.tour-controls`, `.tour-hint` | `app.css` | same names | Verified (ported) |
| `.report-grid`, `.finding` + `.good/.limit/.unknown` | `app.css` | same names | Verified (ported) |
| `.map-layout`, `.map-pane`, `.map-legend`, `.layer-bar`, `.layer-toggle` | `app.css` | same names | Verified (ported) |
| `.quick` | `app.css` | `.quick` | Verified (ported) |
| `.rows`, `.row-card`, `.form-section`, `.grid-2`, `.grid-3`, `.timeline`, `.stations`, `.station`, `.progress-track`, `.owner-note`, `.uploader` | `owner.css` | same names | Verified (ported) |
| `.split`, `.queue`, `.queue-item`, `.evidence`, `.audit-table`, `.tabs`, `.tab`, `.decision-bar` | `admin.css` | same names | Verified (ported) |
| `.auth-page`, `.auth-card`, `.auth-field`, `.auth-submit`, … | `auth.css` | same names | Verified (ported) |
| `.bento*`, `.kpi`, `.blist`, `.brow`, `.schart`, `.qgrid`, `.qtile` | `bento.css` | same names (ported in an earlier pass) | Verified |
| `.skeleton`, `.sk*` | `app.css` motion block | `.skeleton` + `--text/--title/--row/--block` | Partial — target's `.skeleton` is the block, the source's is the grid wrapper. Same visual family; not renamed. |

**Note on `.badge-ml`.** The source's blue tone is `ml`; the target's `pillToneClass`
generates `info` for the same wash. The rendered result is identical, so **no alias was
added** — an alias for an identical appearance is the kind of duplication this audit is
meant to remove.

### 1.2 Page-by-page coverage (all 27 pages)

| # | Route | Source page | Structure | Verified |
|---|---|---|---|---|
| 1 | `/` | `sitewise-roles/index.html` | Hero rebuilt to `.hero-grid`/`.hero-eyebrow`/`.hero-proof`/`.hero-visual`/`.float-card`; lower sections token-level only | 1440 + 390 |
| 2 | `/login` | `entrepreneur/login.html` | Rebuilt on `.auth-page`/`.auth-card` (role rows replace the credential fields) | 1440 + 390 |
| 3 | `/entrepreneur` | `entrepreneur/index.html` | Bento grid; duplicate page head removed | 1440 + 390 |
| 4 | `/entrepreneur/explore` | `explore.html` + `map.html` (merged) | Rebuilt: `.filters` → count → `.pgrid` → "Map & surroundings" (`.map-layout` + `.a-card`) | 1440 + 390 |
| 5 | `/entrepreneur/property-detail` | `entrepreneur/property.html` | Rebuilt: `.detail-grid` + `.kv` + `.prov` + gallery + "What is not shown" | 1440 + 390 |
| 6 | `/entrepreneur/compare` | `entrepreneur/compare.html` | Rebuilt: `.compare-table` with labelled states + notices | 1440 + 390 |
| 7 | `/entrepreneur/saved` | `entrepreneur/favourites.html` | `.pgrid` + source empty state | 1440 + 390 |
| 8 | `/entrepreneur/recommendations` | `entrepreneur/recommendations.html` | Rebuilt: `.rec-item` rows with inline reasons | 1440 + 390 |
| 9 | `/entrepreneur/preferences` | `entrepreneur/preferences.html` | Rebuilt: `.quick` explainer + `.filters` form | 1440 + 390 |
| 10 | `/entrepreneur/profile` | `entrepreneur/profile.html` | Rebuilt: `.detail-grid` + labelled fields | 1440 + 390 |
| 11 | `/entrepreneur/report` | `entrepreneur/report.html` | Rebuilt: `.report-grid` + three graded `.finding` groups | 1440 + 390 |
| 12 | `/entrepreneur/tour` | `entrepreneur/tour.html` | Rebuilt: `.tour-stage` + controls + "at a glance" `.kv` | 1440 + 390 |
| 13 | `/owner` | `owner/index.html` | Rebuilt to the bento grid: `bento-head` + `bento-kpis` + `bento` (portfolio-health hero, recent-listings wide card, 3 "How listing works" step cards). Duplicate page head removed. | 1440 + 390 |
| 14 | `/owner/properties` | `owner/properties.html` | Rebuilt: `.filters` + `.rows`/`.row-card` | 1440 + 390 |
| 15 | `/owner/property-detail` | `owner/property-status.html` | Rebuilt: `.detail-grid` + `.kv` + management panel | 1440 + 390 |
| 16 | `/owner/add-property` | `owner/property-edit.html` | `.form-section` groups + `.field` labels (was `.card` + `.overline`) | 1440 + 390 |
| 17 | `/owner/tours` | `owner/tours.html` | Rebuilt: `.rows`/`.row-card` + `.owner-note` | 1440 + 390 |
| 18 | `/owner/tour-preview` | — (target-only) | Source vocabulary only | 1440 + 390 |
| 19 | `/owner/profile` | `owner/profile.html` | Rebuilt: `.detail-grid` + workspace/notifications panels | 1440 + 390 |
| 20 | `/admin` | `admin/index.html` | Rebuilt to the bento grid: `bento-head` + `bento-kpis` + `bento` (verification-health hero, audit-activity wide card, 3 work-queue cards). Duplicate page head removed. | 1440 + 390 |
| 21 | `/admin/users` | `admin/users.html` | `.table` restyled to `.audit-table` metrics | 1440 + 390 |
| 22 | `/admin/user-detail` | — (target-only) | Source vocabulary only | 1440 + 390 |
| 23 | `/admin/verification` | `admin/review.html` (split) | Source vocabulary + `.table` metrics | 1440 + 390 |
| 24 | `/admin/verification-detail` | — (target-only) | Source vocabulary only | 1440 + 390 |
| 25 | `/admin/listings` | `admin/review.html` (split) | `.pgrid` of source cards | 1440 + 390 |
| 26 | `/admin/listing-detail` | — (target-only) | Source vocabulary only | 1440 + 390 |
| 27 | `/admin/profile` | — (target-only) | Source vocabulary only | 1440 + 390 |

"Source vocabulary only" = the page renders entirely with the source's component
classes, tokens and typography, but keeps its own (target-only) page composition because
the source has no counterpart page to copy.

---

## 2. Previously unmigrated elements discovered and fixed

1. **`threesixty` icon** — not a Material Symbols ligature; the literal word rendered in
   the owner nav pill. Renamed to `360` after measuring glyph width.
2. **Pill-nav icon boxes had zero width** (`.app-pill__nav` flex-shrank them to 0px).
   The source's pill row is label-only, so the icons were removed — which also removes
   the collision with the broken ligature.
3. **`classes: 'btn secondary'`** in `FilterPanel` — matched no rule, so the reset
   control rendered with no variant styling.
4. **Duplicate page heads** on the owner and admin dashboards (their own `PageHead` on
   top of `AppLayout`'s). Added `AppLayout.showPageHead`.
5. **`SearchInput` nested a `.field` inside a `Field`** — duplicated label and gap.
6. **Empty state had an icon badge the source does not have**; `EmptyState.icon` removed
   and the box restyled to the source's dashed border on white.
7. **Checkboxes inherited the text-input box** (`.field input { width:100%; height:40px }`)
   — the filter panel's verification pill rendered as a tall empty rectangle.
8. **`.kv` three-track grid** wrapped values mid-word in the narrow detail column; now
   flex with wrap so the provenance chip drops to its own line.
9. **`.auth-submit` was `display: inline`** — width/height ignored, CTA collapsed.
10. **`.map-canvas` had no `position: relative`** — `.visual__grid` escaped to the
    viewport and drew a grid over the whole page.
11. **Detail pages spun forever on an unknown id** — `FutureBuilder.hasData` is false
    both while pending and when the future completes with `null`.
12. **`.rec-item` and `.btn.sm` each defined twice** (old target rule + new source rule)
    — duplicates removed rather than merged.
13. **Card actions had no primary "View details" button** (the source card leads with
    one) and carried leading icons that clipped inside a 3-column card.
14. **`.field .hint`** (the source's in-field hint) had no rule; `.field__hint` did.
15. **`.quick`, `.prov`, `.v-*`, `.notice`, `.disclaimer`, `.tag`, `.kv`, `.gallery`,
    `.detail-grid`, `.a-card`, `.stat-row`, `.rec-*`, `.contrib*`, `.compare-table`,
    `.tour-*`, `.finding`, `.map-*`, `.layer-toggle`, `.rows`, `.row-card`,
    `.form-section`, `.timeline`, `.stations`, `.progress-track`, `.uploader`,
    `.split`, `.queue*`, `.evidence`, `.audit-table`, `.tabs/.tab`, `.auth-*`** had no
    target rule at all — every one is now ported with token-mapped values.
16. **Anchor-based bento cards rendered body text link-blue.** The admin work-queue
    cards are `<a class="bento-card">`, so their inner `<p>` inherited
    `a { color: var(--action) }`. Added `.bento-card p { color: var(--muted) }`.
    The card's headline number had no styling because `.queue-count` is declared
    only under `.card` (not `.bento-card`); added `.bento-card .queue-count`.
    The bento-head description also got a real muted style (`.bh-title p`).
17. **Owner and admin dashboards still used the pre-bento `.metrics`/`.grid-3`/
    `.rows`/`.card` layout** while the entrepreneur dashboard had already moved to
    the bento grid. Rebuilt both to the same `bento-head` → `bento-kpis` → `bento`
    structure (mirroring `entrepreneur/dashboard_page.dart`), with `showPageHead:false`
    so the layout's own header is not duplicated. Verified by the route suite and a
    computed-style probe (admin card body `rgb(100,116,139)` = `--muted`, not blue).

---

## 3. Modified files and reasons

| File | Reason |
|---|---|
| `web/styles.css` | Buttons to the source's pill spec; pill nav ported; brand lockup; empty state; `.panel` to the source's padded column + `.panel--flush`; card typography; `.table` to `.audit-table` metrics; **ported 40+ missing component families** (see §1.1); auth surface; **bento-card body text + queue-count + bento-head description fixes** (§2 #16) |
| `lib/components/ui.dart` | Brand gains the role line; `PageHead` gains a `badges` slot; `EmptyState` drops the source-less icon; `SectionCard` emits `panel--flush`; `SearchInput` un-nests; `StepCard` → `.stepno`/`.step-icon`; `StatCard` gains `.n`; `StatusBadge.forTour` gains `dot`; `toneForVerification` moved here |
| `lib/components/property_card.dart` | Leads with the source's primary "View details" action; icons removed from toggles |
| `lib/components/filter_panel.dart` | Fixed the `btn secondary` variant; added the keyword field; restructured to the source's flat `keyword + 2 × .frow` layout |
| `lib/layouts/app_layout.dart` | `showPageHead`; brand role line; pill links are label-only |
| `lib/data/navigation.dart` | `workspaceLabelFor`; icon renamed to `360` |
| `lib/data/icon_variants.dart` | `threesixty` → `360` with the reason recorded |
| `lib/pages/entrepreneur/explore_page.dart` | Rebuilt: filters + grid + Map & surroundings |
| `lib/pages/entrepreneur/property_detail_page.dart` | Rebuilt to the source detail workspace |
| `lib/pages/entrepreneur/compare_page.dart` | `.compare-table` with labelled states |
| `lib/pages/entrepreneur/recommendations_page.dart` | `.rec-item` rows |
| `lib/pages/entrepreneur/report_page.dart` | `.report-grid` + graded findings |
| `lib/pages/entrepreneur/tour_page.dart` | `.tour-stage` |
| `lib/pages/entrepreneur/preferences_page.dart` | `.quick` + `.filters` |
| `lib/pages/entrepreneur/profile_page.dart` | `.detail-grid` |
| `lib/pages/entrepreneur/saved_page.dart` | Source empty state + compare toggle |
| `lib/pages/entrepreneur/dashboard_page.dart` | Duplicate page head removed |
| `lib/pages/owner/dashboard_page.dart` | **Rebuilt to the bento grid** (`bento-head` + `bento-kpis` + `bento`): portfolio-health hero, recent-listings wide card, 3 step cards; duplicate page head removed |
| `lib/pages/owner/properties_page.dart` | `.rows`/`.row-card` + filters |
| `lib/pages/owner/property_detail_page.dart` | `.detail-grid` + `.kv` |
| `lib/pages/owner/tours_page.dart` | `.rows`/`.row-card` |
| `lib/pages/owner/profile_page.dart` | `.detail-grid` |
| `lib/pages/owner/add_property_page.dart` | `.form-section` + `.field` |
| `lib/pages/admin/dashboard_page.dart` | **Rebuilt to the bento grid** (`bento-head` + `bento-kpis` + `bento`): verification-health hero, audit-activity wide card, 3 work-queue cards; duplicate page head removed |
| `lib/pages/landing_page.dart` | Hero to the source structure |
| `lib/pages/login_page.dart` | Rebuilt on the source auth card |

---

## 4. Verification actually performed

| Check | Command | Result |
|---|---|---|
| Format | `dart format --output=none --set-exit-if-changed lib/` | **0 files changed** |
| Static analysis | `dart analyze lib/` | **2 issues, both `info`-level pre-existing lints** in `entrepreneur/explore_page.dart` (none introduced by this work) |
| Compile | `dart compile js lib/main.server.dart` | **zero errors** |
| Build | `dart run jaspr_cli:jaspr build` | **28/28 routes generated, exit 0** |
| Route/structure audit | `node tool/verify_pages.js http://127.0.0.1:8124` | **28/28 routes pass at 1440px and 28/28 at 390px** — expected bento/source classes present, no horizontal overflow, no unresolved icon ligature |
| Bento card computed-style probe | `node tool/probe_bento.js` | `/admin` anchor-card body `rgb(100,116,139)` (`--muted`, not link-blue), queue-count `rgb(11,15,25)` bold 800; both dashboards donut-rendered, **0 horizontal overflow** |
| CSS integrity | `node tool/css_check.py` | braces **741/741 balanced**, **0 top-level duplicate selectors**, **0 missing tokens** |
| Visual comparison | `node tool/shot.js` + side-by-side reading | screenshots of every page family compared against the source at 1440px; the mismatches listed in §2 were found this way and re-checked after the fix |

`flutter test` remains unrunnable in this environment (it fails at harness start:
`WebSocketException: Invalid WebSocket upgrade request` and a `reg.exe` sandbox block),
and no Flutter test file was modified.

---

## 5. Remaining gaps (documented, not hidden)

**Dashboards are now fully bento.** `/entrepreneur`, `/owner` and `/admin` all share the
same `bento-head` → `bento-kpis` → `bento` structure (the owner and admin rebuilds are new
in this pass). The "partial" items below are the role **sub-pages** (listings, verification,
users, detail routes, profile) and the landing sections below the hero — not the dashboards.

| Gap | Status | Why |
|---|---|---|
| `admin/{users,verification,listings,*_detail,profile}`, `owner/tour-preview`, `owner/add-property`, `entrepreneur/saved`, landing sections below the hero | **Partial** | Token/vocabulary-level only: correct buttons, badges, panels, table metrics and type, but the page composition is the target's own rather than the source's `.split`/`.queue`/`.audit-table`/`.evidence` and `.section`+`.grid-*` layouts. The target-only detail routes have no source page to copy. |
| Admin audit log | **Blocked by data** | `AdminCubit` exposes no audit store, so the source's audit table is rendered as its own empty state instead of invented rows. |
| Interactive map tiles | **Blocked by architecture** | No map SDK exists in either tree; the stylised Klang Valley projection (with real zoom and pin projection) is the honest stand-in. |
| Listing photographs / 360° frames | **Blocked by data** | `CommercialProperty` has no `coverImage`; captures are mobile-only. Placeholders are labelled as such. |
| 12 source pages with no route | **Out of scope** | `admin/{tours,monitoring,activity}`, `entrepreneur/{explanation,signup,forgot-password}`, `owner/tour-capture`, `dashboards/*` ×3, `roles/*` ×5. Creating them would mean new pages. |
| Dark mode | **Not applicable** | The target has none, so there was nothing to preserve. |

---

## 6. Verification tooling

`fyp_jaspr_web/tool/` — kept in the repository so these checks are repeatable:

| Script | Purpose |
|---|---|
| `verify_pages.js` | Per-route audit of expected source classes, horizontal overflow and icon ligatures at 1440px and 390px |
| `shot.js` | Full-page screenshots (freezes CSS animations so `fullPage` does not time out) |
| `dump.js` | Rendered-DOM outline of a page — required because the source is JS-rendered |
| `audit_classes.py` | Classes emitted by Dart with no rule, rules never referenced, source-only vocabulary |
| `css_check.py` | Brace balance, duplicate selectors (top-level vs `@media`), missing tokens |
| `icon_probe.js` | Which Material Symbols ligature names actually resolve in the font |

Operational notes: `jaspr build` deletes `build/jaspr` first, so any static server
serving that directory must be stopped or the build fails with
`PathAccessException … errno 32`. Detail routes are pre-rendered without query params,
so browser checks must wait for hydration. After a CSS-only change,
`cp web/styles.css build/jaspr/styles.css` avoids a full rebuild.

## 7. App-icon replacement and photographic signup hero (2026-10-26)

### 7.1 New app icon (uploaded artwork)

The user-supplied 1254×1254 icon (rounded-square isometric map tile on black)
was extracted by `tool/make_app_icon.py`:

* `detect_tile()` finds the tile bounds by modal voting on row/column extents.
* `tile_region()` crops with 3px padding so the SDF squircle's straight edges
  fall inside the canvas (without this the edges became a pale band), inpaints
  the JPEG halo, and pulls alpha in 1px so no traced outline survives.
* `rounded_master()` — transparent-corner squircle, used as the web brand mark
  (`sitewise-mark-64.png`).
* `square_master()` — outside-of-squircle corners filled via `cv2.inpaint`
  (TELEA), propagating the artwork's own navy rim outward; a global rim-average
  fill left a faint seam because the rim shade varies around the tile, and a
  Jacobi diffusion converged too slowly. Used for launcher icons.
* Emits: `web/assets/sitewise-icon{,-16,-32,-48,-64,-180,-192,-512}.png`,
  `sitewise-mark-64.png`, Android `mipmap-*/ic_launcher.png` (48–192),
  19 iOS AppIcon sizes from `Contents.json`, macOS `app_icon_16..1024`.

Consumers switched from glyph/SVG logos to the icon:

| Surface | File | Old | New |
|---|---|---|---|
| Nav brand (app/marketing layouts) | `lib/components/ui.dart` | Material `location_on` glyph | `<img>` `sitewise-mark-64.png` |
| Landing nav | `lib/pages/landing_page.dart` | inline SVG arcs + pin | `<img>` `sitewise-mark-64.png` |
| Auth pages | `lib/components/auth_icons.dart` | inline SVG pin | `<img>` `sitewise-mark-64.png` |
| Signup topbar | `lib/pages/signup_page.dart` | inline SVG shield | `<img>` `sitewise-mark-64.png` |
| Favicon / touch icon | `lib/main.server.dart` | data-URI SVG | `sitewise-icon-32.png` / `sitewise-icon-180.png` |

### 7.2 Photographic signup hero

`web/assets/signup-city.jpg` (958×890) is extracted from the user's mockup by
`tool/extract_signup_bg.py`: harmonic + SHIFTMAP inpaint removes the
composited copy while the route-line/pin artwork is preserved; benefit-icon
discs are force-filled harmonically so the exemplar inpainter cannot pull
blue building texture into them. `signup_page._heroArt()` now renders an
`<img class="su-hero__art" src="assets/signup-city.jpg">` instead of the
inline skyline SVG (`object-fit: cover`, bottom-anchored); the existing
bottom fade mask and `.su-hero::after` white scrim keep the headline legible.

### 7.3 Verification performed

* `tool/_diag_icon.py` — numeric probes: rounded master corners alpha 0,
  edge feather ≈8px; square master corners uniform navy, no bright rim wrap.
* `tool/verify_icon.js` — headless Chromium: every `<img>` has
  `naturalWidth > 0` on `/`, `/login`, `/signup` at 1440px and 390px;
  0 broken images, 0 console errors. Screenshots in `tool/_diag/`.
* `tool/probe_signup.js` — full functional pass (validation, password toggle,
  account-type cards, concept select, demo alert).
* `tool/verify_pages.js` — 62 route checks, 0 problems.

## 8. Sign-in page redesign (2026-10-26, evening)

`lib/pages/login_page.dart` was rewritten as a Jaspr port of the updated
sign-in design (`sitewise_login.html`, supplied out-of-repo; top navbar
**removed per the brief**). No parallel auth system, routes, or shared
components were created — the page keeps the same `/login` route, the same
client-side validation logic (email format + required password), the same
demo-build submit posture, and the same `/forgot` + `/signup` links.

* Backdrop: the reference's inline base64 JPEG (1774x887) was extracted to
  `web/assets/login-bg.jpg` and rendered as `.lp-bg` (fixed, slow drift
  animation, disabled under `prefers-reduced-motion`) under the reference's
  left-to-right dark scrim (`.lp-overlay`).
* Hero column: eyebrow, "Welcome back to **SiteWise.**" (`#1aa8ff` accent),
  description, three glassy feature rows (map / bookmark / monitoring
  Material Symbols on translucent circles).
* Card: heading + sub, Google/Apple buttons **disabled** with an explicit
  "not configured" note (no fake login), "or" divider, labelled email +
  password fields with inline `lp-err` validation messages, working
  password-visibility toggle (`aria-pressed`), right-aligned forgot link,
  remember-me checkbox, full-width submit, and the signup switch.
* CSS: new self-contained `.login-page` / `lp-` scoped section at the end of
  `web/styles.css` (Archivo stack reused via `--lnd-font`; the reference's
  DM Sans link intentionally not imported). The old `.auth-*` section remains
  untouched for `/forgot`. Typography keeps the project's Archivo stack.
* Responsive: two-column >= 981px; single-column with a rotated vertical
  scrim at <= 980px; compact paddings/44px icon circles at <= 520px.
* Fixes found during verification: Jaspr hydration syncs `input.checked`
  against an attribute value of exactly `'true'` (`dom_render_object.dart`),
  so the remember checkbox must use Jaspr's dedicated `checked:` parameter —
  a raw `checked="checked"` attribute is read as false and silently cleared
  on hydration.
* Tests: new `test/login_page_test.dart` (jaspr_test) covers structure +
  empty-submit validation; `tool/probe_login.js` covers the built page in
  headless Chromium (bg image load, label association, eye toggle +
  `aria-pressed`, bad-email vs valid email, disabled socials, both routes,
  checkbox default-on, 0px overflow at 1440/390, zero console errors).
  `tool/verify_pages.js` `/login` contract updated to the `lp-` vocabulary.

## 9. Sign-up navbar swap (2026-10-28)

The bespoke `.su-topbar` ("Already have an account? — Sign in") was removed and
replaced with the site's real navigation bar.

* The landing page's top bar was extracted verbatim into a shared
  `lib/components/site_topbar.dart` (`SiteTopbar`): brand mark + wordmark +
  tagline, the four section links, Sign in / Sign up actions, and the small-
  screen menu. The landing page now renders `const SiteTopbar()` instead of its
  inline `_topbar()`, so both pages share one implementation.
* `SiteTopbar` takes a `linkPrefix`: landing keeps `''` so links scroll in
  place (`#problem`); sign-up passes `'/'` so they navigate back to the landing
  sections (`/#problem`) instead of dead-ending.
* The nav's CSS lives in the landing page's global `.topbar` / `.nav` block and
  depends on the `--lnd-*` tokens, so the sign-up page wraps the bar in
  `div.lnd` to supply them.
* Dead `.su-topbar*` / `.su-signin` / `.su-brand__name` rules (including two in
  media queries and one focus-visible selector group) were deleted; `.su-body`
  height changed from `calc(100vh - 73px)` to `calc(100vh - 75px)` for the
  74px nav + 1px border.
* The sign-up background is intentionally unchanged (its own
  `assets/signup-city.jpg` hero).
* Verified: `dart analyze lib` clean; build 32/32 routes;
  `probe_signup.js` — Sign in → /login, brand present, old `.su-topbar` count 0,
  form behaviour unchanged; nav height 74px, body 905px at 980px viewport,
  0 horizontal overflow at 1440 and 390; landing page nav still uses in-page
  anchors and `verify_pages.js` reports 0 problems across 62 routes.
