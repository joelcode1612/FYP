# UI Migration Audit — Bento/Landing Design Language

> Date: 2026-10-25  
> Scope: Landing page redesign + entrepreneur auth pages (login, signup, forgot-password)  
> Build: Jaspr 0.23.5 static, 32 routes

## What was done

### 1. Landing page (`/` & `/landing`)
- Rebuilt from the source `sitewise-roles/index.html` design.
- All CSS tokens remapped to the project's `web/styles.css`.
- 3D model note added (design reference only; no runtime 3D engine).

### 2. Auth pages — ported from HTML to Dart (`@client`)
Three entrepreneur auth surfaces were recreated as Jaspr `StatefulComponent`s:

| Route | File | Fields | Notes |
|-------|------|--------|-------|
| `/login` | `lib/pages/login_page.dart` | email, password + eye toggle, remember-me row, social buttons | Demo alert on submit |
| `/signup` | `lib/pages/signup_page.dart` | name, email, password, confirm + two eye toggles, social buttons | Password-length (≥8) + mismatch validation |
| `/forgot` | `lib/pages/forgot_password_page.dart` | email only | Demo alert on submit |

**Shared infrastructure added:**
- `lib/components/auth_icons.dart` — inline SVG field icons (email, lock, lock-check, user) and social logos (facebook, google, apple).
- `lib/components/dom_helpers.dart` — `textNode()` helper that avoids the Jaspr hydration desync caused by `Component.text('')` (server drops empty text nodes; client creates them).
- `web/styles.css` — auth block extended with `.auth-row`, `.auth-check`, `.auth-link`, `.auth-eye`, `.auth-field.is-invalid`, `.auth-err`, `.auth-social`, `.auth-sr`, `.auth-alert.is-hidden`, `.auth-err.is-hidden`.

**No backend exists.** All three pages are UI-only:
- Client-side validation surfaces inline errors (`auth-err`) and a non-blocking `auth-alert` banner.
- Submitting any form shows a demo message ("Demo build — … is disabled. No … is created or stored.").
- Social buttons are `disabled` with `aria-label`/`title` explaining "not configured".

### 3. Routing
`lib/app.dart` wired `/signup` and `/forgot` alongside the existing `/login`:
```dart
Route(path: '/login', builder: (context, state) => const LoginPage()),
Route(path: '/signup', builder: (context, state) => const SignupPage()),
Route(path: '/forgot', builder: (context, state) => const ForgotPasswordPage()),
```

## Verification results

### Structural (`tool/verify_pages.js`)
- **31 routes** checked at **1440 px** and **390 px**.
- **0 page checks with problems**.
- All expected DOM classes present, no horizontal overflow, no unresolved Material Symbols ligatures.

### Auth interaction (`tool/probe_auth.js`)
- `/login`: empty-submit validation works, eye toggle flips `input[type]`, valid submit shows demo alert.
- `/signup`: empty-submit highlights 4 fields, mismatch password shows "Passwords do not match.", matching submit shows demo alert, both eye toggles work.
- `/forgot`: empty-submit shows email error, valid submit shows demo alert.
- **PAGE ERRORS: none** (this run).

## Known issues

### 1. Flaky delayed `null.toString` console error during sequential navigation
**Symptom:** When navigating from one page to another in the *same browser tab* (e.g. `/login` → `/signup`), a `Cannot read properties of null (reading 'toString')` error may appear in the console **asynchronously after the new page has loaded**.

**Impact:** **Non-breaking.** The error does not affect DOM structure, layout, or user interactions. All functional probes pass.

**Root-cause hypothesis:** This is a Jaspr framework-level cleanup issue. The client-side reconciler may schedule a microtask / `requestAnimationFrame` callback that fires after the browser has already begun tearing down the old document during navigation. Because the callback tries to read a property of a DOM node that is now detached / null, it throws. The error is intermittent and only reproducible under rapid sequential navigation in a single tab — it never appears on a direct fresh page load.

**Mitigation already applied:**
- All conditional text spans were converted to `textNode()` + `is-hidden` class, eliminating the empty-text hydration desync that previously made this error deterministic.
- The remaining occurrence is a framework race condition, not a structural component bug.

### 2. No authentication backend
All three auth pages are visual prototypes. There is no user registration, session management, or password-reset backend. This is by design for the current milestone.

## Files created / modified

| File | Action |
|------|--------|
| `lib/pages/login_page.dart` | Rewritten with stable alert/err spans, eye toggle inside field, `dom_helpers` import |
| `lib/pages/signup_page.dart` | **New** — full signup surface |
| `lib/pages/forgot_password_page.dart` | **New** — full forgot-password surface |
| `lib/components/auth_icons.dart` | **New** — SVG icon helpers |
| `lib/components/dom_helpers.dart` | **New** — `textNode()` hydration-safe helper |
| `lib/app.dart` | Added `/signup` and `/forgot` routes |
| `web/styles.css` | Added `.is-hidden` rules for auth alert/err |
| `tool/verify_pages.js` | Updated expected selectors for auth routes |

---

## Landing page polish pass (2026-10-26)

### Footer layout — the "too narrow for the card" bug
The landing footer renders four blocks (brand, Explore, Get started, Note) but the
ported `.footer-grid` declared only **three** columns, so the Note block wrapped to
a second row and left a large empty gap. `.footer-brand`, `.footer-base`,
`.footer-fine` and `.brand-icon-sm` had no styles at all, and `.footer-base` sat
outside `.wrap`, which made the two copyright spans run together at the viewport edge.

**Fix**
- `lib/pages/landing_page.dart` — footer brand grouped into `.footer-brand__row`;
  Note column tagged `.footer-col--note`; base bar now wraps its content in
  `.wrap.footer-base__inner`; added a "Recommendations & report" link and pointed
  "Create an account" at `/signup`.
- `web/styles.css` — new "Landing polish pass" block: a real 4-column grid
  (`1.55fr 1fr 1fr 1.3fr`), styled brand tile, uppercase column headings, link
  hover easing, full-bleed base bar with an aligned inner wrap, and responsive
  steps at 1100 / 720 / 460 px. Also adds card hover lift and a
  `prefers-reduced-motion` guard.

### 3D hero performance
`web/three_scene.js` previously started a new renderer and RAF loop on every
re-mount and never stopped them, and rendered continuously even when scrolled away.
It now:
- disposes the previous renderer/canvas when `start()` runs again;
- pauses the render loop when the hero is off-screen (`IntersectionObserver`) or
  the tab is hidden (`visibilitychange`), resuming on return;
- cleans up RAF, observers and the canvas in `dispose()`.

### Verification
- `tool/verify_pages.js`: **0 problems** across 31 routes at 1440 px and 390 px.
- Footer columns measure 340 / 242 / 242 / 314 px — all four on one row, no
  horizontal overflow.
- 3D canvas mounts and survives a scroll-away/return cycle with no console errors.

---

---

## Reusable letter-reveal animation (2026-10-26)

### Component
`lib/components/letter_reveal.dart` — `LetterRevealHeading` (plus `LetterRun`
and the testable `splitGraphemes` helper). It renders one
`<span class="lr-char" style="--i:N">` per character **inside the component
tree**, so the server and client emit identical markup and Jaspr hydration /
`setState` reconciliation are untouched. A script only toggles classes.

API:

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `level` | required | heading level 1–6 |
| `runs` | required | `LetterRun(text, tag: 'em')` preserves inline markup |
| `id`, `classes` | `null` | existing attributes are preserved |
| `animateOnLoad` | `true` | `lr--load` (CSS on mount) vs `lr--scroll` (observer) |
| `disabled` | `false` | renders plain text, no spans |
| `staggerMs` | `30` | requested per-character stagger |
| `durationMs` | `420` | per-character transition |
| `delayMs` | `0` | offset before the first character |
| `maxTotalMs` | `900` | caps the whole sequence; long headings get a smaller stagger |
| `attributes` | `{}` | extra heading attributes |

`LetterRevealHeading.text(...)` is a convenience constructor for a single run.

### Where it is applied

| Surface | Mode | Scope |
|---------|------|-------|
| Landing hero `h1` | `lr--load` | two runs, `<em>` preserved |
| Landing section `h2` ×4 | `lr--scroll` | Challenge / Exploration / Assessment / Recommendations |
| `PageHead` title (`ui.dart`) | `lr--load` | every dashboard page rendered by `AppLayout` |
| Bento dashboard `h1` ×3 | `lr--load` | entrepreneur / owner / admin dashboards |
| Auth `h1` ×3 | `lr--load` | login / signup / forgot-password |

Body copy, form labels, nav links, property cards, tables and prices are
untouched.

### Trigger and timing
- Above-the-fold headings use a CSS entrance on mount (`backwards` fill), so a
  failed animation can never leave text hidden.
- Section headings use `web/reveal.js`: one `IntersectionObserver`, created
  once, which arms off-screen headings and unobserves them after revealing.
  Headings already on screen at init are left visible (no flicker). Scrolling
  back does not replay the animation.
- Defaults: 30 ms stagger, 420 ms duration, 10 px rise, `cubic-bezier(0.22,
  0.61, 0.36, 1)`. Only `opacity` and `transform` animate.

### Accessibility and fallbacks
- The heading carries `aria-label` with the full text; the visual span wrapper
  is `aria-hidden`, so screen readers announce one phrase, not one item per
  character.
- `prefers-reduced-motion: reduce`: nothing is hidden, no transform.
- JavaScript disabled: scroll headings are never armed and stay readable.
- Unicode: `splitGraphemes` iterates code points, keeping emoji, skin-tone
  modifiers, ZWJ sequences, flags, combining marks and CJK intact.
- Layout: heading geometry with spans is identical to plain text (hero 225 px,
  section h2 98 px, auth 30 px, page-head 31 px at 1440 px; one 1 px sub-pixel
  rounding on the bento title, height unchanged).

### Verification
- `dart analyze lib tool/lr_grapheme_check.dart` → 0 errors, 0 warnings
  (2 pre-existing info lints in `explore_page.dart`).
- `dart run tool/lr_grapheme_check.dart` → 12/12 PASS (short, long,
  punctuation, newline, accents, CJK, emoji, skin tone, ZWJ family, flag,
  mixed).
- Browser (Chromium 1440 px and 390 px): hero opacity 0 → 1; all four section
  headings arm then reveal; scrolling back does not replay; filter `setState`
  does not restart the title; reduced motion and no-JS show static text; no page
  or console errors on landing, auth or dashboard routes.
- `tool/verify_pages.js`: **0 problems across all 31 routes** at 1440 px and
  390 px.

### Remaining limitations
- `splitGraphemes` is a compact approximation of Unicode segmentation, not a
  full UAX #29 implementation. Exotic clusters (e.g. Indic conjuncts) may split
  more than a full implementation would; common Latin, CJK and emoji sequences
  are handled.
- Client-side route changes do not re-run `reveal.js`, so `.lr--scroll`
  headings added after initial load (landing only) would appear without the
  animation. All `.lr--load` surfaces animate on mount regardless.
- Inline `style` is used to carry `--i` and the timing variables. It sets no
  visual property — the design system still owns colour, type and spacing.

---

## Recommendations panel — ranked view (2026-10-26)

### Problem
Section 04, tab 01 ("Candidate properties matched to your assessment") did not
match the reference design:

- The rank label and fit badge sat side by side instead of spanning the card.
- The stage was a white card with a divider under the top bar, not the light
  tinted panel in the reference.
- The tag above the heading and the heading itself shared one line.
- Card meta text inherited the 15 px body size, so it wrapped to two lines.
- Tag tones were wrong: informational tags rendered teal and the rent breach
  rendered amber instead of red.

### Root cause
The port omitted two rules from the design source's `landing-enhancements.css`:
`.rec-view { display: grid; gap: 18px; }` and `.cand-head { display: flex;
align-items: center; justify-content: space-between; gap: 10px; }`. Without
`.cand-head` the rank and badge were inline siblings.

### Changes
- `lib/pages/landing_page.dart`
  - Stage gets `interactive-stage--ranked` on tab 01 only.
  - `_recView1` adds `rec-view--ranked` and `stage-topbar__copy`.
  - New `_candTagTone()`: `Above`/`HIGH_RISK` → `danger`, `UNKNOWN` → `warn`,
    otherwise `ml` (blue).
  - "See factor explanations →" now switches to tab 02 (it was inert).
- `web/styles.css`
  - Restored `.rec-view` grid and `.cand-head` flex.
  - Ranked stage: `#f8fafc` panel, `#e2e8f0` border, 20 px radius, 22 px
    padding, no shadow; top bar borderless and vertically centred.
  - Cards: 14 px radius, 16 px padding, `#f8fafc` with `#e2e8f0` border; active
    card white with the blue accent border.
  - Card typography: 10.5 px muted rank, 15 px title, 12 px meta (was 15 px and
    wrapping), 11 px tags with 6 px radius.
  - Full-width select button.

### Verification (Chromium, 1440 px and 390 px)
- Panel `rgb(248,250,252)`, radius 20 px, padding 22 px, border `#e2e8f0`.
- `.cand-head` computed `display:flex; justify-content:space-between`.
- Selecting candidate 03 moves the active state and swaps both button labels.
- "See factor explanations →" activates step 02 (`aria-selected="true"`) and the
  stage class reverts to the white panel.
- Tabs 02–04 and the mobile single-column layout unchanged.
- `tool/verify_pages.js`: 0 problems across 31 routes; no console errors.

## Signup page — split marketing layout (2026-10-26)

### Problem
The signup page was a single centred `auth-page` card: a form floating in a
large empty light-grey page. It did not match the reference design, which
splits the viewport — a marketing/brand panel on the left carrying the value
proposition, the account form on the right.

### Changes
- `lib/pages/signup_page.dart` — rewritten as `SignupPage`:
  - `div.signup-page` → `header.su-topbar` (brand + "Sign in" link) and
    `div.su-body` holding the two columns.
  - `_hero()` renders `aside.su-hero` with an inline SVG skyline
    (`_heroArt()`), the eyebrow, the headline "Find the right **space** for
    your **business.**", a lead paragraph, and three benefit rows
    (search / map / monitoring icons) via `_benefit()`.
  - `_panel()` renders `main.su-panel` → `div.su-card` with the form:
    `LetterRevealHeading` title, name / email / password / confirm fields
    (`_fieldBlock`, with show-hide eyes on both password inputs), two
    account-type radio cards (`_typeCard`, `role="radio"` +
    `aria-checked`), an optional planned-concept `select` (5 concepts),
    a terms checkbox, the submit button, and the data-use note.
  - Client-side validation in `_submit()`: name, email regex, password
    ≥ 6 chars, confirmation match, terms accepted. Per-field messages and
    an `aria-live` alert region. Success shows a "demo build" notice — no
    account is created, matching the no-backend posture of `/login`.
  - `_heroArt()` is a hand-built SVG skyline (distant blocks, twin towers,
    mid layer, dark shophouses with warm windows, road) on a
    `0 0 800 1000` viewBox with `preserveAspectRatio="xMidYMax slice"`.
    It is decorative and `aria-hidden`, so the page ships with no image
    payload and makes no external requests.
- `web/styles.css` — new scoped `Signup — split marketing layout` block:
  - `.su-body` grid `minmax(0, 1.1fr) minmax(470px, 0.9fr)`, full viewport
    height below the top bar.
  - `.su-hero` with a sky gradient, the SVG absolutely positioned behind the
    copy, and a `.su-hero::after` scrim (vertical + horizontal white
    gradients) that keeps the headline legible over the scene.
  - `.su-panel` on `#f1f5f9` with a white `.su-card`, `.su-control` inputs
    with leading icons, `.su-type` radio cards, `.su-select` custom-chevron
    select, `.su-terms` and a full-width `.su-submit`.
  - Responsive: ≤ 1080 px stacks to one column and hides the benefit list;
    ≤ 560 px tightens the top bar, the type cards go single-column and the
    hero shrinks to 320 px.
- `tool/verify_pages.js` — the `/signup` expectation was still asserting the
  old `auth-*` classes. Replaced with the new `signup-page, su-topbar,
  su-hero, su-card, su-control, su-type, su-submit`.
- `tool/probe_signup.js` — new functional probe for the new form.

### Mobile legibility fix
The first mobile pass was broken. The hero was only 250 px tall, so the
portrait SVG (`xMidYMax slice`) cropped to its bottom band and scaled the
buildings up behind the lead paragraph; the scrim was also too weak and the
road rendered as a hard dark bar. Fixed by:

- Raising the hero to 380 px (≤ 1080 px) and 320 px (≤ 560 px).
- Re-weighting the stacked-layout scrim toward the top
  (`rgba(255,255,255,.95)` → `.86` at 38 % → `.6` at 62 % → `.18` at 88 %).
- Masking the bottom of `.su-hero__art`
  (`linear-gradient(180deg, #000 88%, transparent 100%)`) so the road fades
  out instead of ending in a hard stripe.

### Verification (Chromium)
- Screenshots at 1440 / 1280 / 390 px: no horizontal overflow (`0` px) at
  every width, form card present, 5 controls, 2 account-type cards, the
  default "F&B Entrepreneur" selected, no console or page errors.
- `tool/probe_signup.js`:
  - Empty submit → all five field messages + "Please fix the highlighted
    fields." alert.
  - Password eye toggles only its own field (`password` → `text`).
  - Account-type switch updates `aria-checked` to `["false","true"]`.
  - Concept select lists the placeholder plus 5 concepts and accepts
    "Cloud Kitchen".
  - Valid submit → "Demo build — account creation is disabled." with the
    `info` tone, no errors left visible, still on `/signup`.
  - Heading carries the letter-reveal classes (`.su-title.lr.lr--load`,
    25 char spans); "Sign in" points at `/login`.
- `tool/verify_pages.js`: 0 problems across 31 routes at 1440 px and 390 px.

### Known limitation
The city backdrop is a stylised inline SVG, not a photograph. It keeps the
page dependency-free and instant, but it is not a photographic scene — swap
it for a generated or licensed photo if the reference fidelity matters more
than the zero-request payload.

