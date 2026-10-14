---
# Extracted from: fyp_jaspr_web/web/styles.css (:root), fyp_mobile_app/lib/core/theme/sitewise_theme.dart
tokens:
  colors:
    # Core brand
    primary: "#2F6FED"        # --action / SitewiseColors.action
    primaryHover: "#1D4ED8"   # --accent / SitewiseColors.accent
    secondary: "#1D4ED8"      # --accent (gradient partner + small badge text)
    background: "#F6F7F9"     # --background / scaffoldBackgroundColor
    surface: "#FFFFFF"        # --surface
    surfaceAlt: "#FAFBFC"     # --alt-surface / .section--alt
    ink: "#10151F"            # --ink / headings + dark surfaces
    text: "#10151F"           # body text resolves to --ink
    textMuted: "#667085"      # --muted (secondary copy)
    textOverline: "#6B7280"   # --overline-text (a11y-safe small caps)
    overline: "#98A2B3"       # --overline (borders/icons only)
    border: "#E4E7EC"         # --border
    success: "#0E9F6E"
    successText: "#0B815A"    # --success-text (4.96:1 on light)
    warning: "#B54708"
    danger: "#D92D20"
    geoWash: "#EAF1FE"
    geoBorder: "#CFE0FD"
    successWash: "#D3F8DF"
    warningWash: "#FEF0C7"
    dangerWash: "#FEE4E2"
    neutralWash: "#F2F4F7"
    scrim: "rgba(15, 23, 42, 0.45)"
    onDarkPrimary: "#FFFFFF"
    onDarkSecondary: "rgba(255, 255, 255, 0.62)"
    onDarkTertiary: "rgba(255, 255, 255, 0.74)"
  typography:
    fontFamily: "IBM Plex Sans, system-ui, -apple-system, Segoe UI, sans-serif"
    fontFamilyDisplay: "Sora, system-ui, -apple-system, Segoe UI, sans-serif"
    fontFamilyIcon: "Material Symbols Outlined, sans-serif"
    baseSize: "15px"
    baseLineHeight: "1.55"
    weights:
      regular: 400
      medium: 500
      semibold: 600
      bold: 700
      extrabold: 800
    scale:
      heroTitle: "52px / 1.04 / 800 / -2px"
      display: "46px / 1.06 / 800 / -1.6px"
      titleXl: "34px / 1.12 / 700 / -1px"
      metric: "26px / 1 / 800"
      titleLg: "22px / 1.12 / 800"
      topbarTitle: "20px / 1.12 / 800"
      brandName: "18px / 1.12 / 800 / -0.5px"
      title: "16px / 1.12 / 700"
      lead: "16px / 1.65 / 400"
      body: "14px / 1.6 / 400"
      table: "13.5px / 1.5 / 400"
      small: "12.5px / 1.55 / 400"
      eyebrow: "11px / 1.2 / 800 / +1.1px"
      tiny: "11px / 1.5 / 400"
      overline: "10px / 1.2 / 700 / +0.9px"
  spacing:
    xs: "4px"
    sm: "8px"
    md: "16px"
    lg: "24px"
    xl: "32px"
    section: "84px"
    sectionCompact: "56px"
  shapes:
    borderRadius: "12px"
    radiusLg: "16px"
    radiusXl: "22px"
    radiusPill: "999px"
    borderWidth: "1px"
    focusRing: "2px"
  elevation:
    flat: "none"
    dialog: "0 24px 64px rgba(15, 23, 42, 0.25)"
    menu: "0 16px 48px rgba(15, 23, 42, 0.22)"
    cardMobile: "0 3px 10px rgba(15, 23, 42, 0.04)"
    banner: "0 8px 18px rgba(47, 111, 237, 0.15)"
    pinHalo: "0 0 0 5px rgba(47, 111, 237, 0.16)"
  layout:
    contentMax: "1180px"
    appContentMax: "1080px"
    sidebarWidth: "236px"
    topbarHeight: "72px"
    containerGutter: "20px"
    chromeGutter: "24px"
    buttonHeight: "44px"
    buttonHeightGhost: "38px"
    buttonHeightCta: "52px"
    touchTargetMin: "48px"
---

# DESIGN.md

> **Provenance.** Two artifacts share one design language: `fyp_jaspr_web/web/styles.css` (the web token sheet, self-described as "the design system") and `fyp_mobile_app/lib/core/theme/sitewise_theme.dart` (`SitewiseColors` / `SitewiseSpacing`, the Flutter source of truth). The hex values are byte-identical across both. Where they diverge, the divergence is noted inline. All values below are absolute — none are invented.

## 1. Overview

**Structural vibe — "civic-tech clarity on a light canvas."** This is an *editorial light-mode dashboard* aesthetic, not a dark mode. The interface reads as a calm, evidence-first analytical tool: a near-white page (`#F6F7F9`) carrying pure-white bordered surfaces, hairline `1px` separators, and a single saturated blue (`#2F6FED`) used as an accent rather than a flood. Depth is deliberately almost absent — cards, app bars, and buttons all sit at `elevation: 0`; separation is communicated by borders and background tint, not shadows. The one dark element is `--ink` (`#10151F`), used as an *inverted surface* for the final CTA block, dark info cards, and the legacy Flutter AppBar.

**Typographic mood.** A two-family pairing does the tonal work: **Sora** (geometric, tight, weight 800) for every heading, numeral, and metric; **IBM Plex Sans** for all prose. Headings are aggressively negative-tracked (`-2px` at 52px, `-1.6px` at 46px, `-1px` at 34px), which gives the display layer a compressed, confident, almost poster-like density. Body copy is soft-edged and muted (`#667085`) with generous line-height (`1.55`–`1.68`) — the contrast between the two is the signature.

**Atmosphere.** Light, cool, and institutional-but-modern. A faint geospatial motif is load-bearing, not decorative: `--geo-wash` / `--geo-border` blues, a `23px` grid overlay, map pins with a soft halo, stylised roads, and concentric location arcs all reinforce the "location intelligence" subject. Imagery is conspicuously *absent* — visuals are CSS/canvas geometry, gradients, and Material Symbols icons, so nothing implies content the data layer cannot back.

**Target platform orientation — dual, from one token base.**
- **Web / desktop (Jaspr, SSR):** full app shell with a fixed `236px` sidebar + `72px` sticky topbar; marketing pages with a sticky `72px` masthead and a 3-column footer grid; `1180px` marketing container and `1080px` app content column. Breakpoints at **1100px**, **900px**, and **640px**.
- **Mobile (Flutter, Material 3):** bottom navigation bar + compact top app bar, `48px` minimum touch targets, modal bottom sheets with a `40×4px` grabber and `20px` top radius, horizontally scrolling discovery rails.

**Consistency doctrine found in the code.** The CSS file states that tokens are "the single source of truth," and the Dart theme states "Pages must consume `SitewiseColors`/`Theme.of` — never hardcode hexes." Visual rules live in the token layer, not in component code — Jaspr components carry *only* class names, and even data-driven bar widths are snapped to a `.w-5…w-100` utility rather than an inline style.

## 2. Colors

### 2.1 Brand / Primary accents
| Token | Value | Role |
|---|---|---|
| `--action` | `#2F6FED` | The single interactive accent. Primary buttons, links, active nav, focus rings, progress fills, price text, map pins, selection washes' foreground. |
| `--accent` | `#1D4ED8` | Darker partner. Primary button **hover**, brand-mark gradient end, tiny badge label text, gradient terminus. |
| `--geo-wash` | `#EAF1FE` | The brand tint at surface strength: icon tiles, active nav background, avatars, badges, chips, card media/banner, result-item hover, highlighted table rows. |
| `--geo-border` | `#CFE0FD` | Border for geospatial/blue-tinted containers (score ring track, Flutter chip side). |

Contrast rule recorded in code: the `--action` → `--accent` step is the *only* sanctioned hover shift for a solid primary control.

### 2.2 Secondary / Semantic
| Token | Value | Wash partner | Meaning |
|---|---|---|---|
| `--success` | `#0E9F6E` | `--success-wash` `#D3F8DF` | Verified, positive delta, high scores |
| `--success-text` | `#0B815A` | — | Success *text* (4.96:1 on light) |
| `--warning` | `#B54708` | `--warning-wash` `#FEF0C7` | Pending review, mid scores |
| `--danger` | `#D92D20` | `--danger-wash` `#FEE4E2` | Rejected, destructive actions, low scores, error icon |
| `--muted` (neutral) | `#667085` | `--neutral-wash` `#F2F4F7` | Draft, inactive, neutral pills |

Rule from code: semantic colors appear almost exclusively as **wash background + matching dark foreground**. A semantic hue is never a large flat fill except for the destructive confirm button (`backgroundColor: danger`).

### 2.3 Background / Surface layers (back to front)
1. `--background` `#F6F7F9` — page canvas (also the desktop sidebar-nav hover and `.menu__item` hover).
2. `--alt-surface` `#FAFBFC` — alternating marketing band (`.section--alt`).
3. `--surface` `#FFFFFF` — cards, panels, sidebar, topbar, masthead, footer, dialogs, menus, mobile nav.
4. `--ink` `#10151F` — inverted surface: `.cta-box`, `.card--dark`, snackbars, and the Flutter `AppBarTheme`.
5. `rgba(15, 23, 42, 0.45)` — modal scrim (`.overlay`).

### 2.4 Text contrast layers
| Layer | Token | Use |
|---|---|---|
| Headings / primary | `--ink` `#10151F` | All `h1–h4`, `.title`, nav labels, body in Flutter |
| Secondary | `--muted` `#667085` | `.lead`, `.body`, `.small`, `.tiny`, subtitles, meta, icons at rest |
| Small-caps labels | `--overline-text` `#6B7280` | `.overline`, `.sidebar__role`, `table th` — **not** `--overline` |
| Faint | `--overline` `#98A2B3` | Non-text only: borders, icons |
| On dark (primary) | `#FFFFFF` | Text on `--ink` and on `--action` |
| On dark (secondary) | `rgba(255,255,255,0.62)` | `.muted-on-dark` |
| On dark (tertiary) | `rgba(255,255,255,0.74)` | `.cta-box .lead` |

Accessibility note recorded verbatim in the CSS: `--overline` (`#98A2B3`) is only **2.60:1** on white and fails WCAG AA; it passes the **3:1** bar for borders and icons, so it is restricted to those, while text uses `#6B7280` (**4.82:1**). Any port that reintroduces `#98A2B3` as a text color is a regression.

## 3. Typography

**Families (loaded via Google Fonts with `display=swap`):**
- Display — `Sora`, weights **600 / 700 / 800**, fallback `system-ui, -apple-system, "Segoe UI", sans-serif`.
- Body — `IBM Plex Sans`, weights **400 / 500 / 600 / 700**, same fallback chain.
- Icons — `Material Symbols Outlined`, variable axes `opsz 24, wght 400, FILL 0, GRAD 0`, `display=block`.

**Global rules.** Body `15px / 1.55`, `-webkit-font-smoothing: antialiased`. All headings: display family, `margin: 0`, `letter-spacing: -0.02em`, `line-height: 1.12`. Paragraphs and `hr` are marginless — spacing is owned by layout utilities (`gap`), never by margins.

### 3.1 Type scale
| Role | Class | Size | Weight | Line-height | Tracking | Color |
|---|---|---|---|---|---|---|
| Hero title | `.hero__title` | 52px → 42px → 34px | 800 | 1.04 | −2px (−1.4px/−1px) | ink |
| Display | `.display` | 46px → 32px | 800 | 1.06 | −1.6px (−1px) | ink |
| Section title | `.title-xl` | 34px | 700 | 1.12 | −1px | ink |
| Metric / KPI | `.metric` | 26px | 800 | 1 | — | ink / `.text-success` / `.text-action` |
| Card title | `.title-lg` | 22px | 800 | 1.12 | −0.02em | ink |
| Topbar title | `.topbar__title` | 20px | 800 | 1.12 | −0.02em | ink |
| Brand name | `.brand__name` | 18px | 800 | 1.12 | −0.5px | ink |
| Sub-title | `.title` | 16px | 700 | 1.12 | −0.02em | ink |
| Lead | `.lead` | 16px | 400 | 1.65 | — | muted |
| Body | `.body` | 14px | 400 | 1.6 | — | muted |
| Table | `.table` | 13.5px | 400 | 1.5 | — | ink |
| Small / caption | `.small` | 12.5px | 400 | 1.55 | — | muted |
| Eyebrow | `.eyebrow` | 11px | 800 | 1.2 | +1.1px, uppercase | action |
| Tiny | `.tiny` | 11px | 400 | 1.5 | — | muted |
| Overline | `.overline` | 10px | 700 | 1.2 | +0.9px, uppercase | overline-text |

Mobile mirror: the Flutter landing tree reproduces the same ramp in raw `TextStyle`s — `34/1.1/−1` headline, `17` and `16` card titles at `w700`, `14/1.65–1.7` leads, `12.5` captions, `11.5` meta, and `10.5` overlines at `SitewiseColors.overline`. **`10.5px` is the mobile equivalent of the web `.overline`** and carries the same legibility caveat.

### 3.2 Weights as semantic signals
- `w800` — display headings, metrics, brand, active CTA label, avatar initial.
- `w700` — section titles, active nav item, success deltas, active bottom-nav label, table headers.
- `w600` — buttons, pills, badges, secondary emphasis.
- `w500` — inactive nav items, unselected bottom-nav labels.
- `w400` — body prose.

Uppercase + positive tracking is reserved exclusively for **eyebrow / overline / table-header / sidebar-role** micro-labels. Regular prose is never letter-spaced up.

## 4. Layout & Spacing

### 4.1 Spacing scale (the only five steps)
`SitewiseSpacing` and `:root` agree exactly: **`xs 4` · `sm 8` · `md 16` · `lg 24` · `xl 32`**.

Observed compositions, all built from those five steps (plus `2px` hairlines):
- Control internals: `gap: 8`, `gap: 6`, `gap: 4`; button padding `0 20px`; ghost `0 10px`.
- Grid gutters: `16px` (`.grid-2`, `.grid-4`, `.card-grid`), `14px` (`.stat-grid`), `32px` (`.footer-grid`).
- Vertical rhythm: `.stack` uses the step scale; cards `padding: 16–24px`; `.stat` `18px`; `.card--dark` `24px`; `.cta-box` `52px 48px` (`36px 24px` on mobile).
- Section bands: `padding: 84px 0` → `56px 0` below 640px.
- Hero column gap: `58px` → `36px` at ≤1100px.

### 4.2 Layout systems
**Flexbox** drives the structural chrome: `.app-shell` (sidebar + main), `.sidebar` (vertical: head / role / nav / foot), `.topbar` (title block + `margin-left: auto` actions), `.masthead__inner`, `.stack` (column), `.row` (centered row, `.row--top` for `align-items: flex-start`), `.grow` (`flex: 1 1 0; min-width: 0`), `.feature`, `.btn-row` (`gap: 12px; flex-wrap: wrap`), `.footer-links`.

**CSS Grid** drives the content matrices: `.grid-2` and `.grid-4` (`repeat(n, 1fr)`, `gap: 16px`), `.stat-grid` (`repeat(4, 1fr)`, `gap: 14px`), `.footer-grid` (`1.4fr 1fr 1fr`, `gap: 32px`), `.hero` (`1fr 1fr`, `gap: 58px`), and the responsive card matrix `.card-grid` (`repeat(auto-fill, minmax(240px, 1fr))`, `gap: 16px`). Small grid utilities also use `display: grid; place-items: center` as a one-line centering idiom (`.brand__mark`, `.icon-tile`, `.score-card__ring`).

**Responsive collapse contract.**
| Breakpoint | Change |
|---|---|
| ≤1100px | `.hero` → 1 column, gap 36px; `.hero__title` → 42px/−1.4px; `.grid-4`, `.stat-grid` → 2 columns |
| ≤900px | `.masthead__nav` hidden; `.footer-grid` → 1 column; **`.sidebar` hidden** |
| ≤640px | `.section` → 56px; `.grid-2`, `.grid-4`, `.stat-grid` → 1 column; `.display` → 32px/−1px; `.hero__title` → 34px; `.cta-box` → 36px 24px |

### 4.3 Containers, gutters, and fixed dimensions
- Marketing container: `max-width: 1180px`, `margin: 0 auto`, `padding: 0 20px`.
- App content: `.app-content__inner` `max-width: 1080px`, `padding: 24px`, inside a scrolling `flex: 1` region.
- Chrome gutters: masthead inner and topbar both `padding: 0 24px`.
- Fixed rails: `--sidebar-w: 236px` (`flex: none`), `--topbar-h: 72px` on both masthead and app topbar.
- Anchor offset: `scroll-padding-top: 88px` (`72px` header + breathing room); `scroll-behavior: smooth`.
- Mobile: bottom nav is inset-aware by Material; bottom sheets reserve `MediaQuery.viewInsets.bottom + 20`.

## 5. Elevation and Depth

**The governing principle is flatness.** `cardTheme.elevation: 0`, `AppBarTheme.elevation: 0`, `ElevatedButton.styleFrom(elevation: 0)`, `BottomNavigationBar.elevation: 0`, `scrolledUnderElevation: 0`. Depth is *not* the primary hierarchy device — `1px` borders and background tint are. Shadows exist only in a small, enumerated set:

| Element | Shadow | Note |
|---|---|---|
| `.dialog` | `0 24px 64px rgba(15,23,42,0.25)` | Heaviest elevation in the system |
| `.menu` | `0 16px 48px rgba(15,23,42,0.22)` | Second-level overlay |
| Mobile property card | `0 3px 10px rgba(15,23,42,0.04)` (≈`0x0A0F172A`) | Near-imperceptible lift |
| Featured banner | `0 8px 18px rgba(47,111,237,0.15)` (`0x262F6FED`) | **Tinted** shadow — brand-colored, not black |
| White circular chip | `0 4px 10px rgba(0,0,0,0.20)` (`0x33000000`) | Only true black shadow; sits on gradient |
| Map pin | `box-shadow: 0 0 0 5px rgba(47,111,237,0.16)` | Zero-blur halo ring |

**Gradients (all subtle, all brand-derived):**
- Brand mark: `linear-gradient(135deg, #2F6FED, #1D4ED8)` — identical in `styles.css` and `sitewise_brand.dart`.
- Featured banner: `topLeft → bottomRight, #2F6FED → #1D4ED8`.
- Map/visual panel: `linear-gradient(160deg, #F7FBFF, #EAF1FE)`.
- Grid overlay: two-axis `linear-gradient(rgba(75,120,184,0.13) 1px, transparent 1px)` at `23px × 23px` (Flutter painter equivalent: `28px` grid at `geoBorder` α0.6, plus white `6px` "roads").
- Onboarding visuals: painter-side gradients off `action`/`accent`.

**Transparency layers:** white-on-gradient overlays at `α 0.10 / 0.13 / 0.22 / 0.30`, `rgba(255,255,255,0.93)` for `.visual__chip`, `rgba(15,23,42,0.06)` for the property-card save hover, `rgba(15,23,42,0.45)` scrim.

**Backdrop blur / frosted glass: not used.** No `backdrop-filter`, no `BackdropFilter`, no blur radii anywhere in either tree. Overlays are opaque surfaces + scrim.

**Z-index ladder (web):** `50` sticky masthead → `60` overlay/dialog.

## 6. Shapes & Borders

### 6.1 Radius rules
| Token / value | Applied to |
|---|---|
| `999px` (`--radius-pill`, `99`, `1000`) | Pills, badges, avatars, dots-as-circles, banner CTA, role-menu trigger |
| `22px` (`--radius-xl`) | `.cta-box`, `.visual` — the "hero panel" radius |
| `20px` | Status badges, filter chips, mobile sheet top corners |
| `16px` (`--radius-lg`) | `.card`, `.panel`, `.step`, `.score-card`, `.dialog`, **`.btn`**, `.btn--primary/secondary/cta`, mobile property card, mobile banner |
| `14px` | `.menu` |
| `12px` (`--radius`, `SitewiseSpacing.radius`) | `.card--flat`, `.card--dark`, `.stat`, `.p-card`, `.icon-tile`, `.visual__chip`, map panel, `p-card__score`, Flutter `CardTheme` |
| `10px` | `.nav-item`, `.icon-btn`, `.input`, `.p-card__compare`, Flutter input/button/outlined-button |
| `9px` | `.brand__mark` (30×30) |
| `8px` | `.masthead__link`, `.menu__item`, map-panel chip, mobile stat icon tile |
| `6px` / `4px` | Progress-bar track+fill (`.weights__track/fill` 4px, `ClipRRect(6)`) |
| `2px` | Mobile skyline bars top corners |

Stated rule: **controls and cards share the `16px` radius on the web**; small utility affordances step down to `8–10px`; anything status-like becomes a full pill. The Flutter tree's *default* for controls is a tighter `10px`, with `16px` reserved for the heavier pre-login CTA and property cards — worth noting when porting either direction.

### 6.2 Borders
- **`1px solid --border` is the universal separator** — cards, panels, tables, dividers, sidebar edge, topbar bottom, masthead bottom, footer top, input rest state, secondary button.
- `border: 1px solid transparent` on `.btn` so every variant keeps identical box metrics when a border is added by a modifier.
- Focus: **`2px solid --action`** with `outline-offset: 2px` on `:focus-visible`; inputs use `outline-offset: 0`; Flutter focused inputs use a `1.6px --action` side instead.
- Dividers are `1px` elements (`.divider`, `.menu__divider`), and `.table tr:last-child td` drops its bottom border so a table never double-borders against its panel.
- Semantic borders: `--geo-border` for geospatial tints, `--action` for selected chips/secondary-button hover/compare-on, `--danger` for danger-outline hover.
- Flutter `CardTheme` is border-led: `elevation: 0` + `BorderSide(color: border)`.

## 7. Component Specifications

### 7.1 Buttons (`.btn` + variants)
**Anatomy.** `inline-flex`, centered, `gap: 8px`, `height: 44px`, `padding: 0 20px`, `border: 1px solid transparent`, `border-radius: var(--radius-lg)` (16px), `font-weight: 700`, `font-size: 14px`. Transition: `background-color, border-color, opacity` at **`0.16s ease`**. Optional leading Material Symbol at `16px` (`size: 'sm'`).

| Variant | Rest | Hover | Notes |
|---|---|---|---|
| `--primary` | bg `--action`, text `#fff` | bg `--accent` | Only solid fill |
| `--secondary` | bg `--surface`, text `--ink`, border `--border` | border `--action`, text `--action` | Outline→accent shift, no fill |
| `--ghost` | transparent, text `--muted`, `height: 38px`, `padding: 0 10px`, `w600` | text `--action` | Header/nav affordance |
| `--danger-outline` | transparent, text `--danger`, border `--border` | border `--danger` | Destructive, low-emphasis |
| `--cta` | full-width, `height: 52px`, `radius 16`, `w800` | inherits variant | Mirrors Flutter `SitewiseCtaButton` |
| `[disabled]` / `.is-disabled` | `opacity: 0.5`, `cursor: not-allowed`, `pointer-events: none` | — | Flutter CTA uses `accent.withValues(alpha: .5)` |

**Composition rules.** `.btn-row` (`gap: 12px`, wrap) for button clusters. In Jaspr, navigation CTAs are `<a class="btn btn--…">` (crawlable, middle-clickable); state-changing CTAs are `<button>` with `.is-disabled` when the handler is `null`. Flutter `SitewiseButton` / `SitewiseSecondaryButton` are `ElevatedButton` / `OutlinedButton` with `minimumSize: Size(48, 48)`, `radius 10`, icon `18px` + `SizedBox(width: 8)`; `expanded: true` wraps in `SizedBox(width: double.infinity)`. **Touch targets never go below 48px on mobile** even where the web uses 44px.

### 7.2 Icon buttons, avatars, brand mark
- `.icon-btn` — `38×38`, radius `10px`, transparent, `--ink`, `font-size: 20px`; hover bg `--background`. Used for search, dialog-close, and topbar utilities.
- `.avatar` — `34×34` circle, bg `--geo-wash`, color `--action`, `w800`, `14px`. Trigger has `padding: 4px`, `border-radius: 999px`, hover bg `--background`. Flutter equivalent: `CircleAvatar(radius: 16)`.
- `.brand__mark` — `30×30`, radius `9px`, brand gradient, white glyph, `15px w800`; `gap: 9px` to the `18px w800 −0.5px` wordmark.
- `.icon-tile` — `40×40`, radius `12px`, bg `--geo-wash`, color `--action`, `16px` icon, `flex: none`; the standard leading tile for features and role cards. Flutter stat card uses a `20px` icon in an `8px`-padded, `8px`-radius tile.

### 7.3 Inputs
**Web (`.input`).** `flex: 1`, `1px solid --border`, radius `10px`, `padding: 10px 12px`, `font-size: 14px`, `font-family: inherit`, **bg `--background` (not white — inputs read as inset)**, color `--ink`. Focus: `outline: 2px solid --action`, `outline-offset: 0`.
**Flutter.** `filled: true`, `fillColor: --surface`, `OutlineInputBorder` radius `10`, enabled border `--border`, focused border `--action` `1.6px`, labels and hints `--muted`, content padding `16/14`.
Search (`SitewiseSearchBar`) = `TextField` with `prefixIcon: Icons.search` and the shared decoration — never a bespoke field.

### 7.4 Cards, panels, and surfaces
| Component | Anatomy |
|---|---|
| `.card` | bg `--surface`, `1px --border`, radius **16**, padding `20px`. Often combined as `.card stack` for vertical content. |
| `.card--flat` | radius **12**, padding `16px` — denser variant |
| `.card--dark` | bg `--ink`, border `--ink`, text `#fff`, radius `12`, padding `24px`; secondary copy `rgba(255,255,255,0.62)` |
| `.panel` | bg `--surface`, `1px --border`, radius `16`, `overflow: hidden` — the table/wrapper shell |
| `.stat` | radius `12`, padding `18px`; inner order is icon row → `.overline` label → `.metric` value (`26px/800`), optional tone class |
| `.step` | radius `16`, padding `20px`; `.step__num` in Sora `13px/800/--action`, then `.title`, then `.body` |
| `.p-card` | radius `12`, `overflow: hidden`, `flex` column: optional `.p-card__banner` (`--geo-wash`, `12px`, padding `10px`) → `.p-card__media` (`120px` tall, `--geo-wash`, centered icon at `opacity: 0.5`, badge top-left 8px, save button top-right 4px) → `.p-card__body` (padding `12px`, `gap: 2px`) with title (ellipsis), meta `12px muted`, price row (`baseline`, price in `--action w700`), score chip, and a full-width `.p-card__compare` button |
| Flutter `Card` | From theme: `--surface`, `elevation: 0`, radius `12`, `BorderSide(--border)` |
| Empty-state / error-state | Centered column, padding `32px`; empty uses a `--geo-wash` circle with a `40px --action` icon; error uses a bare `48px --danger` icon; both followed by a `16px w700` title, `6px` gap, centered `bodySmall`, and an optional `ElevatedButton` after `16px`. |

### 7.5 Pills, badges, dots
`.pill` — `inline-flex`, `gap: 6px`, `padding: 4px 10px`, `border-radius: 999px`, `12px w600`, `white-space: nowrap`. Tones pair a wash with its dark foreground: `neutral` (`--neutral-wash`/`--muted`), `action` (`--geo-wash`/`--action`), `success` (`--success-wash`/`--success-text`), `warning` (`--warning-wash`/`--warning`), `danger` (`--danger-wash`/`--danger`).
`.dot` — `7×7`, `border-radius: 50%`, `flex: none`, with `--success`/`--warning`/`--danger` fills, used inline inside pills for status.
Flutter `SitewiseStatusBadge` — padding `10/4`, radius `20`, `12px w600`; `forVerification()` maps verified → `#0E9F6E` on `#D3F8DF`, pending → `#B54708` on `#FEF0C7`, rejected → `#D92D20` on `#FEE4E2`, draft → `#667085` on `#F2F4F7`. **This four-state mapping is the canonical status language** and the Jaspr `toneForVerification()` mirrors it 1:1.
`SitewiseFilterChip` / Flutter `ChipTheme` — radius `20`, unselected `--surface` + `--border` + `--ink`; selected `--action` fill + white `w500` label; theme chip default bg `--geo-wash`, side `--geo-border`, `12px` label.

### 7.6 App shell — sidebar, topbar, content
**`.sidebar`** — `236px` fixed, bg `--surface`, `border-right: 1px --border`, full-height flex column. `__head` padding `20px 20px 8px` (brand). `__role` padding `8px 20px`, `11px w700`, `+1.2px`, uppercase, `--overline-text`. `__nav` `flex: 1`, padding `0 12px`, `gap: 2px`. `__foot` `border-top 1px`, padding `16px`, `11px --muted`.
**`.nav-item`** — full width, `gap: 12px`, padding `11px 12px`, radius `10px`, transparent, `--ink`, `14px w500`, left-aligned. Hover: bg `--background`. Active (`.nav-item--active`): bg `--geo-wash`, color `--action`, `w700`. Detail routes highlight the **parent** shell route so the sidebar is never empty.
**`.topbar`** — `height: 72px`, `flex: none`, bg `--surface`, `border-bottom 1px`, `gap: 16px`, padding `0 24px`. Title `20px w800` ellipsized, subtitle `12px --muted` ellipsized, then optional `.topbar__actions` (`margin-left: auto`, `gap: 8px`) and `.topbar__controls` (`.icon-btn`s + avatar menu, `gap: 4px`).
**`.app-content`** — `flex: 1; overflow-y: auto`; `__inner` max-width `1080px`, margin auto, padding `24px`.
**Mobile shell** — top bar: `--surface` bg, `--ink` fg, `elevation: 0`, `scrolledUnderElevation: 0`, `Border(bottom: --border)`, title `17px w700` (or the wordmark at `17`), `leadingWidth: 48` with a brand pin when the route cannot pop. Bottom nav: `--surface` with a top hairline, `elevation: 0`, selected `--action`, unselected `--muted`, fixed type, labels `11px` (`w700` selected / `w500` unselected), icons `23px`.

### 7.7 Masthead and footer
**`.masthead`** — `position: sticky; top: 0; z-index: 50`, bg `--surface`, `border-bottom 1px`. Inner: `72px` tall, max-width `1180px`, `gap: 10px`, padding `0 24px`, brand → nav (`margin-left: auto`, `gap: 4px`) → actions (`gap: 8px`, `margin-left: 8px`). `.masthead__link`: transparent, `--muted`, `13px w600`, padding `8px 10px`, radius `8px`; hover → `--ink` on `--background`.
**`.site-footer`** — bg `--surface`, `border-top 1px`, padding `48px 0 32px`. `.footer-grid` = `1.4fr 1fr 1fr`, `gap: 32px` → 1 column ≤900px. `.footer-links` = column, `gap: 10px`; links `13px --muted`, hover `--action`. Closes with `hr.divider` + `.tiny` copyright.

### 7.8 Data table
`.table` — `width: 100%`, `border-collapse: collapse`, `13.5px`. `th` = `10px w700`, `+0.8px`, uppercase, `--overline-text`, padding `12px 14px`, `border-bottom 1px`. `td` = padding `14px`, `border-bottom 1px`, `vertical-align: middle`; last row's cells drop the border. `.table-scroll` wraps wide tables in `overflow-x: auto`; `.table__metric` is `w600`; `.table__row--highlight td` gets `--geo-wash`.

### 7.9 Overlays — dialog, menu, scrim
**`.overlay`** — fixed inset 0, `z-index: 60`, `rgba(15,23,42,0.45)`, flex, `align-items: flex-start`, `justify-content: center`, `padding: 10vh 24px 24px`. Only the backdrop dismisses; panels stop propagation. `.overlay--menu` right-aligns in a transparent layer at `calc(72px + 8px)` top offset.
**`.dialog`** — `--surface`, `1px --border`, radius `16`, `box-shadow: 0 24px 64px rgba(15,23,42,0.25)`, max-width `420px` (`--wide` `560px`), max-height `60vh`, flex column, hidden overflow. Internals: `__head` (`gap: 8px`, padding `14px 16px`, bottom border), `__title` (Sora `16px w800`, padding `14px 16px 10px`), `__loading`/`__empty` (padding `24px 16px`, `--muted`, `13.5px`, centered), `.result-list` (padding `8px`, scroll) with `.result-list__item` (`gap: 12px`, padding `10px 12px`, radius `10`) whose hover is `--geo-wash`.
**`.menu`** — `--surface`, `1px --border`, radius `14`, `box-shadow: 0 16px 48px rgba(15,23,42,0.22)`, min-width `240px`, padding `8px`. `__head` padding `10px 12px 8px`; `__name` `14px w800`; `__divider` `1px`, margin `6px 4px`; `__item` block, padding `9px 12px`, radius `8px`, `13.5px`, hover `--background`; `__item--current` = `--action w700`.

### 7.10 Progress, gauges, and scores
- `.weights__track` — height `8px`, radius `4px`, bg `--neutral-wash`, `overflow: hidden`; `.weights__fill` — full-height, radius `4px`, bg `--action`, width from a `.w-5…w-100` utility (bucket snapped to 5% in `WeightBar`).
- `SitewiseProgressIndicator` — `LinearProgressIndicator` inside `ClipRRect(6)`, `minHeight 8` (`6` compact), track `--border`, value `8px` from the trailing figure (`12px` compact, `w700`, same color).
- **Score → color ramp (shared by the bar and the ring):** `≥75 → --success`, `≥55 → --action`, `≥40 → --warning`, else `--danger`.
- `SitewiseEvidenceScore` — `72×72` ring, `strokeWidth: 8`, track `--border`, centered score `18px w800` in the ramp color, followed by a `w700` label and a `bodySmall` explainer.
- `.score-card__ring` (web) — `46×46`, `border: 5px solid --geo-border`, `border-top-color: --action` (a CSS-only partial ring), `11px w800` centered.

### 7.11 Icon system
`.ms` — `Material Symbols Outlined`, `font-size: 20px`, `line-height: 1`, `flex: none`, `font-variation-settings: "FILL" 0, "wght" 400, "GRAD" 0, "opsz" 24`. Sizes: `--sm` `16px`, default `20px`, `--lg` `24px`. The **icon name (not a code point) is stored in content data**, keeping the web and Flutter trees comparable. Icons are decorative by default; a meaningful icon passes a `label`, rendered as `.sr-only` text rather than an ARIA attribute.

### 7.12 States inventory
| State | Treatment in code |
|---|---|
| Hover | bg `--background` (nav/icon-btn/menu-item/compare), bg `--accent` (primary), border+text `--action` (secondary), text `--action` (ghost), border `--danger` (danger-outline), bg `--geo-wash` (result item) |
| Active/selected | `--geo-wash` + `--action` + `w700` (nav), `--action` border/text (compare, chip), `--action` icon+label (bottom nav) |
| Focus | `:focus-visible` → `2px --action` outline, offset `2px`, radius `4px`; inputs offset `0` |
| Disabled | `opacity: 0.5` + `pointer-events: none`; Flutter CTA → `accent @ 50%` |
| Loading | `.dialog__loading` / `body muted` "Loading…" strings inside a `.card`; Flutter `SitewiseLoadingState` |
| Empty | `.dialog__empty`, `SitewiseEmptyState` (geo-wash circle + icon) |
| Error | `.text-danger` inline message, `SitewiseErrorState` (danger icon + retry `ElevatedButton`) |
| Success | `.text-success` / `.pill--success` / `--success-text` |

## 8. Design Implementation Do's & Don'ts

### Do
1. **Do consume the tokens.** Web: `var(--action)`, `var(--radius-lg)`, `var(--md)`. Flutter: `SitewiseColors.*`, `SitewiseSpacing.*`, or `Theme.of(context)`. Both files state this as a hard rule — the CSS calls itself "the only place a hex may appear."
2. **Do keep every visual rule in `styles.css`.** Jaspr components carry class names only; even data-driven widths use the `.w-5…w-100` bucket utilities instead of inline styles. If you need a new width, add a class.
3. **Do build spacing from `4 / 8 / 16 / 24 / 32`.** Those five values are the whole scale in both trees. Denser compositions are legitimate only inside those steps (e.g. `gap: 2px` in a card body, `gap: 6px` inside a pill).
4. **Do default to flat + bordered.** New surfaces get `--surface` + `1px --border` + a radius from the scale, at `elevation: 0`. Reach for a shadow only for genuine overlays (dialog, menu) and use the two documented recipes.
5. **Do separate by border and tint, not by shadow.** The `--geo-wash` / `--background` / `--surface` / `--ink` ladder is the hierarchy device.
6. **Do use `--action` for interaction and `--accent` only as its press/hover step** or as a gradient terminus. One accent, one hover.
7. **Do pair a semantic wash with its matching dark foreground** (`--success-wash` + `--success-text`, etc.). Never place a semantic hue on an unrelated background.
8. **Do route small text through `--overline-text` (`#6B7280`), never `--overline` (`#98A2B3`).** Reserve `--overline` for borders and icons where the 3:1 bar applies.
9. **Do use Sora + `w700/w800` for headings, metrics, and every number**; IBM Plex Sans + `w400/w500` for prose. Apply negative tracking by size (`−2px` @52, `−1.6px` @46, `−1px` @34, `−0.5px` @18).
10. **Do reserve uppercase + positive tracking for micro-labels only** (eyebrow, overline, table header, sidebar role).
11. **Do keep radii within the ladder:** `999` pills · `22` hero panels · `16` cards/buttons · `12` default · `10` controls · `8` small links. Status implies a pill.
12. **Do honour `1px solid --border` for every separator**, and drop the last table row's bottom border so tables never double-border inside a `.panel`.
13. **Do keep chrome dimensions fixed** — `236px` sidebar, `72px` topbar/masthead, `1180px` marketing max, `1080px` app max, `20/24px` gutters, `88px` anchor offset.
14. **Do keep interactive elements at least `44px` tall on web and `48px` on mobile** (`52px` for the primary CTA), and give every state-changing control a visible `2px --action` focus ring.
15. **Do pick anchors for navigation and buttons for state changes** — anchors stay crawlable, middle-clickable, and work without JavaScript; the property card's bookmark/compare controls are siblings of the link, never nested inside it.
16. **Do preserve the four-state verification mapping** (draft/pending/verified/rejected → neutral/warning/success/danger) across both trees.
17. **Do mirror every change in both token sources.** `styles.css` and `sitewise_theme.dart` currently agree on all hexes and on `xs/sm/md/lg/xl`; a one-sided edit forks the language.
18. **Do label meaningful icons** and keep decorative ones in the accessibility tree only when needed; the pattern is a visually hidden `.sr-only` span, not an ARIA attribute.
19. **Do respect the documented breakpoints** (1100 / 900 / 640) rather than inventing new ones; below 900px the sidebar and masthead nav are expected to be gone.

### Don't
1. **Don't hardcode hexes** in pages or widgets. No `Color(0xFF…)` outside `sitewise_theme.dart`; no literal colors outside `:root` in CSS.
2. **Don't reintroduce `#98A2B3` as a text color** — it is 2.60:1 on white and fails AA. It is a border/icon token only.
3. **Don't add shadows to cards, buttons, app bars, or nav.** Every one of those is explicitly `elevation: 0`; gratuitous depth is the fastest way to fracture this look.
4. **Don't introduce a second accent hue.** There is exactly one blue family plus four semantic states.
5. **Don't use `backdrop-filter` or frosted glass.** It appears nowhere; overlays are opaque surfaces over a `rgba(15,23,42,0.45)` scrim.
6. **Don't flood large areas with `--action` or a semantic hue.** The only sanctioned solid fills are the primary button, the 30px brand mark, the gradient banner, and the destructive confirm button.
7. **Don't invent spacing values** (no `13px`, `18px`, `30px` rhythm) or new radius values. Snap to the scale, and snap percentage widths to the nearest `5%` bucket.
8. **Don't letter-space body copy upward or use uppercase for prose** — that register belongs to micro-labels only.
9. **Don't set font sizes off the ramp.** If a new role is needed, add it to the scale table rather than inventing an inline size.
10. **Don't use borders thicker than `1px`** except the documented `2px` focus ring and `1.6px` Flutter focused input; don't use colored borders decoratively.
11. **Don't overload the link color** — `--action` means "interactive"; using it for decoration makes affordances ambiguous.
12. **Don't nest interactive controls inside anchors**, and don't wire state-changing actions to `<a>`.
13. **Don't assume imagery.** Visuals are gradients, grids, arcs, pins, skyline bars, and icons — no photographic placeholders that imply data the layer cannot support.
14. **Don't lift the mobile touch target below `48px`** to match a `44px` web control, and don't drop the safe-area/viewInsets padding on bottom sheets and nav.
15. **Don't fork the two themes.** A color or spacing change lands in `sitewise_theme.dart` **and** `styles.css` in the same change; the CSS is a deliberate port of the Dart tokens, not an independent design.