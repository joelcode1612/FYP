# Sitewise — Frontend UI/UX Audit

**Scope:** `fyp_mobile_app` (Flutter, Material 3) + `fyp_jaspr_web` (Jaspr, SSR web) + `shared_logic`  
**Design authority:** [`DESIGN.md`](DESIGN.md) (token contract)  
**Audit type:** Source-derived static review. **No application was run, built, or served; no screenshots were captured; no automated tests were executed.**

---

## 0. Limitations and Evidence Basis

Read this before acting on any finding.

| Claim type                                                   | How it was established                                                                                                                                                                       |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Code structure, line references, token usage                 | Direct file reads and `grep` over the working tree — **verified**                                                                                                                            |
| Counts (hardcoded colours, magic spacing, `Semantics` usage) | `grep` result counts — **verified at time of scan**                                                                                                                                          |
| Rendered layout, overflow, overlap, tap behaviour            | **Not observed.** No emulator, simulator, or browser session was run. Findings of this class are inferred from CSS/Widget code and are labelled **Unverified — needs runtime confirmation**. |
| Contrast ratios                                              | Taken from the explanatory comment in `styles.css`. Not independently measured.                                                                                                              |
| Test results                                                 | **None executed.** No claim of passing tests is made anywhere in this document.                                                                                                              |

**Important timing caveat:** `fyp_jaspr_web/web/styles.css` was **1358 lines** when the design-system extraction was performed earlier in this project; it is now **1876 lines** (`Get-Content | Measure-Object`), having gained the `explore__*` panel/map/zoom rules (lines ~1519–1690). All web line numbers below refer to the **current 1876-line file**. The `DESIGN.md` §4/§7 sections describing `styles.css` therefore predate those additions and should be re-synced.

**Finding inventory:** 61 total — 18 Web (`W-*`), 25 Mobile (`M-*`), 8 Shared design system (`S-*`), 10 Code quality (`C-*`).

---

## 1. Executive Summary

The frontend is **architecturally disciplined but not accessibility-complete**.

What is genuinely good, and should be protected:

- A real, documented token contract (`DESIGN.md`) with a two-family type system (Sora/IBM Plex Sans) and a deliberate **flat, border-and-tint** visual language at `elevation: 0`.
- The Jaspr web tree contains **zero hardcoded hex values in Dart** — every colour goes through `styles.css`. Its own comments state the rule and the code honours it.
- Web navigation is `<a href>`-based with `?id=` query params, so it is crawlable, middle-clickable, and functional without JavaScript.
- **Zero `TODO`/`FIXME`/`HACK` comments** across both trees.
- The four-state verification mapping (draft/pending/verified/rejected → neutral/warning/success/danger) is consistent across both platforms.

Where it breaks down, in order of consequence:

1. **Web is unusable for authenticated users below 900px.** `.sidebar { display: none }` at `styles.css:1852–1854` with **no drawer, sheet, or tab-bar substitute** — a complete loss of primary navigation. This is the single most severe defect found.
2. **Dialogs and menus are not keyboard-operable.** `grep` for `aria-modal`, `role': 'dialog'`, `Escape`, and `onKeyDown` across `fyp_jaspr_web/lib` returns **zero matches**. Overlays open with no focus movement, no focus trap, and no Escape handler.
3. **Mobile touch targets fall below the 48px floor in the app's own contract** — the featured-card save button is `38×38`, the card `_IconAction` hit area is `30×30` (`20px` icon + `5px` padding), and landing role links are bare `InkWell`-wrapped text.
4. **Mobile has effectively no screen-reader support** — only **2** `Semantics(...)` widgets exist in the entire presentation tree.
5. **Token drift in the Flutter tree undermines the single-source-of-truth claim** — ~70 `Color(0x...)` literals and 88 `Colors.*` usages sit outside `sitewise_theme.dart`, including the wash colours that *do* exist as tokens on the web side.
6. **Forms lack associated labels, error states, and progress validation** on both platforms.

The remediation is mostly **targeted and additive** — ARIA attributes, a focus/Escape handler, a mobile nav pattern, token extraction, and touch-target resizing. No rewrite is warranted, and nothing here requires changing business logic, routing, or data models.

---

## 2. Existing Project Overview

**Repository shape.** Three packages:

| Path              | Role                                                                                                                                                                                   |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fyp_mobile_app/` | Flutter client (mobile tree only). Entry: `lib/main.dart`. Routes: `lib/core/routing/app_routes.dart` (35 routes, one `onGenerateRoute`). Theme: `lib/core/theme/sitewise_theme.dart`. |
| `fyp_jaspr_web/`  | Jaspr SSR web client. Entry: `lib/main.server.dart` (`Document` + font `<link>`s). Routes: `lib/app.dart` (27 `Route` entries). Design system: `web/styles.css`.                       |
| `shared_logic/`   | Domain + data + application layer shared by both (entities, repositories, use cases, Cubits).                                                                                          |

**How mobile and web relate.** This is **not a responsive-layout project and not a component-sharing project**. It is *two hand-maintained presentation trees over one shared domain layer*:

- **Separate layouts, separate navigation chrome, separate widgets.** Flutter uses `BottomNavigationBar` + a compact `AppBar`; Jaspr uses a `236px` sidebar + `72px` topbar (`AppLayout`) or a sticky masthead + footer (`MarketingLayout`).
- **Shared visual language only** — the same hex values and the same `4/8/16/24/32` spacing scale, expressed twice: once as `SitewiseColors`/`SitewiseSpacing` in Dart, once as CSS custom properties in `:root`.
- **Consistent routing shape.** Both expose the same paths (`/admin/users`, `/owner/tours`, `/entrepreneur/explore`, …). Detail identifiers travel as `settings.arguments` on mobile and as `?id=` query params on web.
- **`parentShellRoute` is duplicated verbatim** in `app_routes.dart:48–61` and `navigation.dart:98–112` — the same route-to-parent map maintained twice, with the web copy already drifting (the web map carries `/owner/tour-preview` while the mobile map does not, so a detail route highlights differently on each platform).

**Roles and workflows.**

- **F\&B Entrepreneur** — dashboard, preferences, explore (list + map), property detail, 360° tour, recommendations, compare (max 3), saved, suitability report, profile.
- **Property Owner** — dashboard, properties list, add/edit property (validated form, stepper on mobile), tours, tour preview, 360° capture (mobile-only, `PanoramaCapturePage`), profile.
- **Administrator** — dashboard, users, user detail, verification queue, verification detail, listings, listing detail, profile.
- **Public** — landing (marketing), login/role picker. Mobile additionally has an onboarding flow and an `AppStartGate` splash that branches onboarding → auth → role home.

**State management.** Cubits (`AppCubit`, `EntrepreneurCubit`, `OwnerCubit`, `AdminCubit`) consumed via `CubitBuilder` on web and `BlocBuilder` on mobile. Two `ChangeNotifier` ViewModels also exist (`PanoramaCaptureViewModel`, `TourPreviewViewModel`), and auth/filter state uses raw `setState`. See `C-09`.

---

## 3. Mobile UI Audit

**Summary.** The mobile tree has a coherent visual identity and good structural instincts (property-card variants are genuinely different layouts rather than boolean flags, states are extracted into named widgets, forms are stepper-organised). Its weaknesses are **accessibility and token discipline**, not layout architecture.

**Confirmed findings:**

- Touch targets below the 48px contract in five distinct places (`M-01`, `M-02`, `M-03`, `M-19`, `M-20`).
- Only **2** `Semantics(...)` widgets in the whole presentation tree (`M-09`).
- A single `RichText` at `landing_mobile_sections.dart:103` that bypasses text scaling (`M-15`) — verified as the only `RichText(` in the tree, which makes it a one-line fix with outsized impact.
- ~70 hardcoded `Color(0x...)` literals and 88 `Colors.*` usages outside the theme (`M-07`, `C-01`).
- ~250 `SizedBox`/`EdgeInsets` values that do not map to the `4/8/16/24/32` scale (`M-06`, `C-02`).
- Auth validation is SnackBar-only, and "Forgot password?" is a stub that shows `'Connect this to your password reset flow.'` (`C-06`).
- `AppBarTheme` (`ink`/dark) is contradicted by `MobileTopBar` (`surface`/light) — two competing chrome styles (`M-12`).

**Unverified (needs a device/emulator):** whether the 46px CTA actually clips or merely under-shoots the target; whether `11sp` bottom-nav labels overflow on the longest role label; whether the stepper's deferred validation produces a confusing jump-scroll on a real keyboard-visible viewport.

---

## 4. Web UI Audit

**Summary.** The web tree is the **cleaner of the two** in code discipline and the **more broken** in accessibility and responsive completeness. Its Dart contains no hex literals, it uses semantic `<a>`/`<button>` correctly, and its comments document design intent with unusual rigour. It also has the only truly blocking defect in the project.

**Confirmed findings:**

- **`W-05`: total navigation loss below 900px.** Verified by reading `styles.css:1845–1855` — `.masthead__nav` is disabled, `.footer-grid` collapses to one column, and `.sidebar` is set to `display: none`, with no replacement pattern defined anywhere in the stylesheet.
- **`W-01`: no keyboard operability for overlays.** Verified by grep — zero occurrences of `Escape`, `onKeyDown`, `aria-modal`, or `role': 'dialog'` in `fyp_jaspr_web/lib`.
- **`W-10`: form labels are `<span>`s.** Verified in `add_property_page.dart:311` — `span(classes: 'overline', ...)` with no `for`/`id` association, despite the inputs carrying `id` attributes.
- ~15 duplicated `_Loading` classes, one per page.
- 18 inline `style` attributes in Dart, several of them static `gap` values that belong in CSS.
- Tables lack `<caption>` and `scope`.

**Unverified (needs a browser):** the claimed overlap between `.explore__detail` and `.explore__zoom` at ≤1100px (`W-13`) — both are positioned `bottom: 16px` per the CSS, which makes the risk real, but whether they visually collide depends on the stacking and the `right`/`left` insets actually applied; I did not open the page.

---

## 5. Shared Design System Audit

**The two token sources agree on all hex values** and on the five-step spacing scale. That is the good news, and it is the reason this project reads as one product.

**Where they diverge** (each is a real, visible inconsistency between platforms for the *same* logical component):


| # | Divergence | Mobile | Web |
|---|---|---|---|
| `S-01` | Default control radius | `10px` | `16px` |
| `S-03` | Card radius | `12px` | `16px` |
| `S-07` | Primary CTA fill | `accent` `#1D4ED8` | `action` `#2F6FED` |
| `S-02` | Semantic wash tokens | **hardcoded in 6+ files** | present as `--success-wash` etc. |
| `S-06` | Overline text colour | still `#98A2B3` (2.60:1, fails AA) | fixed to `#6B7280` (4.82:1) |

`S-06` is the most consequential: the web tree explicitly documents *why* `--overline` was split and how many times the Flutter tree misuses it as a text colour. The Flutter `bodySmall` still resolves to `#98A2B3`. **The web team fixed an AA failure that mobile still ships.**

`S-04` and `S-05` are API-shape problems rather than pixel problems: Flutter's `SitewiseStatCard` has a delta slot and an icon tile that the web `StatCard` lacks, and Flutter's `SitewiseStatusBadge` takes raw `Color` parameters at call sites while the web `Pill` takes a semantic `tone` string. The web API is the better one — it makes the wrong thing harder to write.

`S-08`/`C-02`: `12px` appears 80+ times in the mobile tree with no token name, which is the mechanical cause of the magic-number sprawl.

---

## 6. Frontend Code Quality Audit

**Maintainability.**
- **13 mobile and 6 web files exceed 300 lines**, several mixing theming, layout, data formatting, and multiple widget definitions. `panorama_capture_page.dart` and `explore_page.dart` (484 lines) are the worst.
- `C-04` — the verification-status → colour mapping is **copy-pasted in at least four files** (`sitewise_status_badge.dart`, `mobile_owner_property_card.dart`, `mobile_review_row.dart`, and mirrored on web). Drift has already occurred.
- `C-09` — three state-management patterns coexist (Cubit, `ChangeNotifier`, raw `setState`) with no documented boundary.
- `C-08` — the web is clean in Dart but ~15 non-token hex/rgba values remain inside `styles.css` component rules.

**Accessibility.**
- Web: no focus trap, no Escape, no `aria-modal`, no `aria-current`, no table `scope`, no form labels (`W-01`, `W-02`, `W-04`, `W-08`, `W-10`).
- Mobile: 2 `Semantics` widgets total; one `RichText` bypassing text scaling (`M-09`, `M-15`).
- `DESIGN.md` §8 is explicit that mobile labels must never drop below 48px — the code violates its own documented contract in five places.

**Performance.**
- No evidence of oversized assets or unnecessary rebuilds was found. The web loads three Google Fonts stylesheets with `display=swap`/`display=block` and preconnects, which is appropriate.
- `AppLocator` holds a client-side singleton for session state, which is intentional and documented.
- **Not measured:** no bundle analysis, no Lighthouse run, no profile trace. Performance findings are therefore limited to the structural observations above.

**Security.** No client-side secret handling, no `dangerouslySetInnerHTML`-equivalent, no user-controlled HTML injection found. `styles.css` does receive a computed `color:` from `_scoreColor()` on web, but the value is derived from a numeric score, not user input. **No security issue identified.**

---

## 7. Detailed Review Comments

Full structured format for **Critical** and **High**. Medium/Low are consolidated into tables in §7.3 to keep this section navigable.

### 7.1 Critical

---

### Issue W-05: Authenticated web navigation disappears below 900px with no replacement

**Platform:** Web
**Location:** `fyp_jaspr_web/web/styles.css:1845–1855` (`.sidebar { display: none }`, `.masthead__nav { display: none }`); consumer `fyp_jaspr_web/lib/layouts/app_layout.dart:79–96`

**Current implementation:** A single media query hides both the masthead nav and the app sidebar at ≤900px. The stylesheet defines no drawer, sheet, tab bar, or toggle for those widths, and `AppLayout` renders no alternative navigation affordance.

**Problem:** Every authenticated route loses its entire primary navigation. A user on a tablet, a small laptop, or a split-screen window can reach pages only by editing the URL.

**Why it matters:** This is a functional dead end, not a cosmetic gap. It blocks the core workflow for all three roles and is the one finding that makes the product unusable rather than merely difficult.

**Recommended change:** Add a mobile navigation pattern at ≤900px. Preferred: a toggle button in `.topbar` that opens the existing `.sidebar` as a fixed off-canvas drawer over a scrim, reusing the current `nav-item` markup so no destination list is duplicated. Acceptable alternative: a bottom tab bar of the role's 4–5 primary destinations.

**Implementation guidance:** Add a `.sidebar--open` modifier (`position: fixed; inset: 0 auto 0 0; z-index: 70; transform: translateX(0)`) plus a backdrop element, and a `.topbar__burger` button hidden above 900px. Toggle it with the same `setState` pattern already used by `TopbarControls`. Do not introduce a new state library for this.

**Priority:** Critical
**Effort:** Large
**Verification:** At 899px, 768px, and 480px while authenticated as each of the three roles, confirm a visible control exists and reaches every sidebar destination.

---

### Issue W-01: Dialogs and menus are not keyboard-operable

**Platform:** Web
**Location:** `fyp_jaspr_web/lib/components/topbar_controls.dart:78–112` (search), `248–258` (notifications), `343–373` (avatar menu)

**Current implementation:** Overlays are plain `<div class="overlay">` with `events(onClick: ...)` to close. The inner panel stops propagation with an empty `onClick`. Verified by grep: **no** `Escape` handler, `onKeyDown`, focus trap, or initial-focus movement exists anywhere in `fyp_jaspr_web/lib`.

**Problem:** Opening a dialog leaves focus on the trigger; Tab walks into the page behind the overlay; Escape does nothing; focus can leave the dialog and never return predictably.

**Why it matters:** WCAG 2.2 SC 2.1.2 (No Keyboard Trap) and SC 2.4.3 (Focus Order). The search dialog is the primary way to reach a listing by name — keyboard and screen-reader users cannot use it at all.

**Recommended change:** On open, move focus into the panel (the search `<input>` for search, the first item for the menu); trap Tab/Shift+Tab within it; close on Escape and return focus to the trigger. Add `role="dialog"`, `aria-modal="true"`, and an accessible name.

**Implementation guidance:** Attach a document-level `keydown` listener while `_open` is true. Prefer the native `<dialog>` element with `showModal()` if Jaspr's DOM builder supports it — it provides focus containment and Escape for free — otherwise implement a minimal trap. Add `aria-expanded` to each trigger.

**Priority:** Critical
**Effort:** Medium
**Verification:** With keyboard only: Tab to the search trigger, Enter, confirm focus lands in the input, Tab cycles only inside the panel, Escape closes and restores focus to the trigger.

---

### Issue M-09: Mobile accessibility tree is effectively unlabelled

**Platform:** Mobile
**Location:** Entire `fyp_mobile_app/lib/presentation/` tree. Only `mobile_quick_actions.dart:56` and `mobile_home_header.dart:51` contain `Semantics(...)`.

**Current implementation:** 35 routes' worth of UI is built from `Text`, `Row`, `Column`, and `InkWell` without semantic grouping. `MobilePropertyCard` in particular presents a title, location, price, size, type, score, and two icon actions as unrelated fragments.

**Problem:** TalkBack/VoiceOver announce a stream of disconnected strings with no indication that a card is one actionable item or that an icon is a button.

**Why it matters:** WCAG 2.2 SC 1.3.1 and 4.1.2; also a practical prerequisite for any app-store accessibility review. This is the highest-leverage mobile fix because it is additive — it changes no layout.

**Recommended change:** Wrap each `MobilePropertyCard` in `Semantics(button: true, label: '<title>, <price> per month, <city>, suitability <score>')` with `MergeSemantics` for the inner text. Add `Semantics(button: true, label: tooltip)` to `_IconAction`. Wrap decorative painters (`_BannerArcPainter`, `_GroundBars`, map grid) in `ExcludeSemantics`.

**Implementation guidance:** Start with `MobilePropertyCard`, `MobileCompactPropertyCard`, `MobileFeaturedPropertyCard`, `MobileFeaturedBanner`, `_IconAction`, and `SitewiseSearchBar`. These seven cover the majority of real screen-reader exposure. No visual change should result — verify with the semantics debugger.

**Priority:** Critical
**Effort:** Large
**Verification:** Enable TalkBack/VoiceOver; traverse Home → Explore → Property Detail → Saved. Each card should announce as a single coherent item with a price and a state.

---

### Issue M-03: Card save/compare icon actions have a 30×30px hit area

**Platform:** Mobile
**Location:** `fyp_mobile_app/lib/presentation/mobile/widgets/mobile_property_card.dart:526–540` (`_IconAction`)

**Current implementation:** `Padding(padding: EdgeInsets.all(5), child: Icon(icon, size: 20))` inside an `InkWell` — a 30×30 logical-pixel target.

**Problem:** 18px below the 48px minimum in both WCAG 2.5.5 and the project's own `DESIGN.md` §8.

**Why it matters:** Saving and comparing are the two highest-frequency card interactions; mis-taps here directly damage the shortlist workflow. `_IconAction` is used by both the standard and featured cards, so one fix covers every occurrence.

**Recommended change:** Expand the `InkWell` to ≥48×48 while keeping the 20px glyph and the current visual rhythm.

**Implementation guidance:** Wrap the `InkWell` in `ConstrainedBox(constraints: BoxConstraints(minWidth: 48, minHeight: 48))` with the icon centred, rather than increasing `EdgeInsets.all()` blindly — that would push the card's internal layout apart. In the featured card the `Positioned(top: 12, right: 12)` inset gives room for 48px without moving the glyph if the padding is rebalanced.

**Priority:** Critical
**Effort:** Small
**Verification:** Flutter Inspector hit-test bounds ≥48×48; tap reliably near the icon's edge on a physical device.

---

### Issue M-15: Landing hero uses `RichText`, so it ignores system text scaling

**Platform:** Mobile
**Location:** `fyp_mobile_app/lib/presentation/mobile/landing/widgets/landing_mobile_sections.dart:103`

**Current implementation:** `RichText(text: const TextSpan(style: TextStyle(fontSize: 34, ...)))`. Verified as the **only** `RichText(` in the presentation tree.


**Problem:** `RichText` does not apply `MediaQuery.textScaler`. A user who raises their system font size sees this text stay at 34px while everything around it grows.

**Why it matters:** WCAG 2.2 SC 1.4.4 (Resize Text). The hero headline is the most prominent text on the public landing page — the first thing a low-vision user reads, and the one element that will not respond.

**Recommended change:** Replace with `Text.rich(TextSpan(...))`, which inherits scaling, or pass `textScaler: MediaQuery.textScalerOf(context)` explicitly.

**Implementation guidance:** One-line change. Keep the existing `TextSpan` tree; only the constructor changes. Because it is the sole `RichText` in the tree, this fix is complete and cannot have siblings.

**Priority:** Critical
**Effort:** Small
**Verification:** Raise the device font scale to 200%; the hero headline should scale with the surrounding copy and wrap rather than clip.

---

### Issue M-19: Landing role links are bare text with no target area and no link semantics

**Platform:** Mobile
**Location:** `fyp_mobile_app/lib/presentation/mobile/landing/widgets/landing_mobile_sections.dart:357–367`

**Current implementation:** `InkWell(onTap: ..., child: Text('${r.linkLabel} →', style: TextStyle(fontSize: 12.5, ...)))` — no padding, no minimum size, no `Semantics`.

**Problem:** The tap target is the rendered text box (~12.5px tall). There is no `link`/`button` role, so assistive tech does not announce it as actionable.

**Why it matters:** This is the primary entry point into each role's app from the landing page. It is simultaneously the smallest target and the most important one on the screen.

**Recommended change:** Replace with `TextButton(onPressed: ..., child: Text(...))`, which supplies Material's 48px minimum target and the correct button semantics, then restyle to match the existing 12.5px action-blue treatment.

**Implementation guidance:** If the intended visual is a text-link rather than a filled/outlined button, use `TextButton` with `style: TextButton.styleFrom(minimumSize: Size(48,48), padding: EdgeInsets.symmetric(horizontal: 8), foregroundColor: SitewiseColors.action)`.

**Priority:** Critical
**Effort:** Small
**Verification:** Accessibility scanner reports the element as an actionable control with a ≥48px height; tap test succeeds near the text edge.

---

### 7.2 High

---

### Issue C-04: Verification status → colour mapping is duplicated in four or more files

**Platform:** Shared
**Location:** `fyp_mobile_app/lib/presentation/shared/widgets/sitewise_status_badge.dart:20–46`; `mobile_owner_property_card.dart:121–136`; `mobile_review_row.dart:139–154`; web mirror `fyp_jaspr_web/lib/components/property_card.dart:9–14`

**Current implementation:** Each file independently maps `VerificationStatus` to a colour pair, hardcoding `0xFFD3F8DF`, `0xFFFEF0C7`, `0xFFFEE4E2`, `0xFFF2F4F7`.

**Problem:** Four copies of one canonical mapping. `SitewiseStatusBadge.forVerification()` already exists and is the intended single source — the other three files bypass it.

**Why it matters:** A single status-colour change requires four edits, and missing one produces a screen that contradicts the others. This is exactly the drift `DESIGN.md` §8.16 warns about.

**Recommended change:** Make `SitewiseStatusBadge.forVerification()` (or a `resolveVerificationStyle()` helper) the only mapping. Have the card and row widgets consume it, or read from new `SitewiseColors` wash tokens.

**Implementation guidance:** Add the four wash colours to `SitewiseColors` (see `S-02`), then delete the local switches. On web, `toneForVerification()` already does the right thing — leave it and note the parallel.

**Priority:** High
**Effort:** Small
**Verification:** `grep -r "0xFFD3F8DF\|0xFFFEF0C7\|0xFFFEE4E2\|0xFFF2F4F7" fyp_mobile_app/lib` returns matches only inside `sitewise_theme.dart`.

---

### Issue S-02 / C-01: ~70 hardcoded colour literals outside the theme contract

**Platform:** Mobile
**Location:** Across `fyp_mobile_app/lib/presentation/` — concentrated in `landing_mobile_sections.dart` (8), `intro_hero_visual.dart` (16), `onboarding_painters.dart` (10), `mobile_property_card.dart` (6), `sitewise_status_badge.dart` (4). Plus 88 `Colors.*` usages.

**Current implementation:** Direct `Color(0xFF…)` construction in widgets and painters, in direct contradiction of `sitewise_theme.dart:5` ("Pages must consume `SitewiseColors`/`Theme.of` — never hardcode hexes").

**Problem:** The theme is not authoritative. Six of these are duplicates of wash colours that **already exist as named tokens on the web side**.

**Why it matters:** Blocks dark mode, makes global colour changes unreliable, and makes the two platforms drift by construction. The web tree proves the discipline is achievable — it has zero hex literals in Dart.

**Recommended change:** Triage into three buckets: **(a)** semantic duplicates → add `successWash`/`warningWash`/`dangerWash`/`neutralWash` to `SitewiseColors` and replace; **(b)** UI chrome (`Colors.grey.shade300` grabber, `Colors.white` in `auth_field.dart:60`, `Colors.grey` in `admin_user_detail_mobile_page.dart:89`) → map to `border`/`surface`/`muted`; **(c)** painter-internal tints → leave, but add a one-line comment stating why they are exempt.

**Implementation guidance:** Do bucket (a) and (b) mechanically; they are the majority and are low-risk. Explicitly document bucket (c) as an accepted exception rather than silently leaving it, so the rule stays trustworthy.

**Priority:** High
**Effort:** Large
**Verification:** `grep "Color(0x" fyp_mobile_app/lib/presentation` drops to painter files only, and `grep "Colors\.\(grey\|white\)\b"` returns no UI-chrome hits.

---

### Issue S-06: Mobile still uses the AA-failing overline colour as text

**Platform:** Shared (regression on Mobile)
**Location:** `fyp_mobile_app/lib/core/theme/sitewise_theme.dart:15` (`overline = #98A2B3`), consumed at `:179` for `bodySmall`; contrast rationale documented at `fyp_jaspr_web/web/styles.css:30–36`

**Current implementation:** Web split the token into `--overline` (`#98A2B3`, borders/icons only, 3:1 bar) and `--overline-text` (`#6B7280`, 4.82:1, for text). Flutter has only the first and uses it for `bodySmall`.

**Problem:** `#98A2B3` measures **2.60:1** on white — below the 4.5:1 AA threshold for small text. The web comment states the Flutter tree used it as a text colour 53 times.

**Why it matters:** This is a known, documented, already-solved-elsewhere accessibility defect. Users with low vision cannot read the secondary copy it colours.

**Recommended change:** Add `overlineText = Color(0xFF6B7280)` to `SitewiseColors`; point `bodySmall` and every text use at it; keep `overline` for borders and icons.

**Implementation guidance:** Mechanical substitution, but audit each call site — some uses (icon tints, dividers) legitimately keep `overline`. The `DESIGN.md` §2.4 table already defines the intended split.

**Priority:** High
**Effort:** Medium
**Verification:** Contrast-check `bodySmall` text ≥4.5:1; `grep "SitewiseColors.overline"` returns only border/icon contexts.

---

### Issue W-10: Web form labels are `<span>`s, not `<label>`s

**Platform:** Web
**Location:** `fyp_jaspr_web/lib/pages/owner/add_property_page.dart:305–315` (the `_field` helper); inputs carry `id` at lines 229, 240, 251, 267, 278

**Current implementation:** `span(classes: 'overline', [Component.text(labelText)])` above each input. The inputs have `id` attributes; nothing references them.

**Problem:** Labels are not programmatically associated with their controls. Clicking the label text does not focus the input, and the accessible name is not reliably derived.

**Why it matters:** WCAG 2.2 SC 1.3.1 and 3.3.2. This is the primary data-entry form for the owner role.

**Recommended change:** Render `<label for="field-title">` and pass the same id used on the input.

**Implementation guidance:** Change the helper to take an `id` parameter, emit `label(attributes: {'for': id}, classes: 'overline', ...)`, and add `label.overline` to the existing `.overline` selector in `styles.css` so styling is unchanged. The same helper is the right place to add `aria-describedby` for the existing inline `'Required'` error text.

**Priority:** High
**Effort:** Small
**Verification:** Click each label — focus moves to its input. Accessibility tree shows each input's name matching its visible label.

---

### Issue W-02 / W-14: Overlays lack ARIA roles; triggers lack expanded state

**Platform:** Web
**Location:** `fyp_jaspr_web/lib/components/topbar_controls.dart:79, 85, 249, 253, 344, 348` (panels); `326–342` (avatar trigger)

**Current implementation:** Panels are bare `<div>`s. The avatar trigger sets `aria-haspopup` but never updates `aria-expanded`. Verified: no `role': 'dialog'` or `aria-modal` anywhere in the web tree.

**Problem:** Screen readers are not told a modal/menu opened, nor whether a trigger is expanded.

**Why it matters:** WCAG 2.2 SC 4.1.2 (Name, Role, Value). Pairs naturally with `W-01` — fix them together.

**Recommended change:** Add `role="dialog"` + `aria-modal="true"` + `aria-label` to dialog panels; `role="menu"` + `role="menuitem"` to the avatar menu; bind `aria-expanded` to `_open` on all three triggers.

**Implementation guidance:** Fold into the `W-01` work — same files, same edit pass.

**Priority:** High
**Effort:** Small
**Verification:** Screen reader announces "dialog" on open and "expanded/collapsed" on the trigger.

---

### Issue W-04: Tables lack `<caption>` and `scope`

**Platform:** Web
**Location:** `compare_page.dart:89–97`, `admin/users_page.dart:80–89`, `admin/verification_page.dart:87–97`

**Current implementation:** `table(classes: 'table', [thead([tr([th(...)])]), tbody([...])])` with no `<caption>` and no `scope` on header cells.

**Problem:** Header-to-cell association is not programmatic; tables have no accessible name.

**Why it matters:** WCAG 2.2 SC 1.3.1. Compare and user/admin tables are dense and are precisely where association matters most.

**Recommended change:** Add `caption(classes: 'sr-only', [...])` as the table's first child and `attributes: {'scope': 'col'}` on every `th`.

**Implementation guidance:** The `.sr-only` utility already exists in `styles.css:405–415` — no new CSS needed.


**Priority:** High
**Effort:** Small
**Verification:** axe-core / Lighthouse table rules pass.

---

### Issue M-10: Mobile forms lack validators, formatters, and keyboard chaining

**Platform:** Mobile
**Location:** `fyp_mobile_app/lib/presentation/mobile/property_owner/pages/owner_add_property_mobile_page.dart:108–137`

**Current implementation:** City has no validator; rental and size use `TextInputType.number` with no `inputFormatters`; no `textInputAction` or `autofillHints` on any field. Established via the subagent's file read; this file was **not** re-read line-by-line in the final verification pass — treat the exact line numbers as **Unverified**, the pattern as confirmed.

**Problem:** Empty city, negative rent, and non-numeric input are all submittable. The keyboard offers no Next/Done progression.

**Why it matters:** Data integrity plus form completion speed. This is the owner's core create-listing flow.

**Recommended change:** Add validators to all fields, `FilteringTextInputFormatter` appropriate to each, `textInputAction: next`/`done`, and `autofillHints` where applicable.

**Priority:** High
**Effort:** Small
**Verification:** Attempt to submit with empty city and negative rent — both must be rejected with a visible inline message.

---

### Issue M-14 / C-07: Missing/unhandled loading, empty, and error states

**Platform:** Mobile + Web
**Location:** Mobile pages not importing the shared state widgets — including `entrepreneur_saved_mobile_page.dart`, `entrepreneur_recommendations_mobile_page.dart`, `admin_profile_mobile_page.dart`, `owner_profile_mobile_page.dart`. Web equivalent: `entrepreneur/dashboard_page.dart` branches on `vm.loading` but has **no `vm.error` branch** (lines 133–150).

**Current implementation:** State handling is inconsistent. Some pages use `SitewiseLoadingState`/`ErrorState`/`EmptyState`; others render directly. On web, the dashboard renders a loading card or the data, with no error path at all.

**Problem:** A cubit error on these pages produces a blank or stale view with no explanation and no retry.

**Why it matters:** Reliability perception. The shared widgets already exist, so the cost of consistency is low.

**Recommended change:** Audit every data-consuming page and branch explicitly on loading → error → empty → populated. On web, add an `vm.error != null` branch rendering the existing `.text-danger` treatment plus a retry link.

**Implementation guidance:** Reuse `SitewiseErrorState`/`SitewiseEmptyState` on mobile; reuse the web dashboard's existing `_error(String)` helper pattern already present in `admin/dashboard_page.dart:69`.

**Priority:** High
**Effort:** Medium
**Verification:** Force a repository failure per page; confirm a message and a retry affordance render.

---

### Issue M-01 / M-02 / M-20: Additional sub-48px targets

**Platform:** Mobile
**Location:** `mobile_property_card.dart:283–286` (save button `38×38`), `:403–406` (CTA `height: 46`), `landing_mobile_sections.dart:935–948` (footer links, ~11.5px tall + 9px padding)

**Current implementation:** Three further instances below the 48px floor the theme itself declares at `sitewise_theme.dart:128` (`minimumSize: Size(48, 48)`).

**Problem / why it matters:** Same class of defect as `M-03`, and `M-02` is a 2px violation of the app's own theme token — trivially fixed but symptomatic.

**Recommended change:** Save button → 48×48 (keep the 19px glyph); CTA → `height: 48`; footer links → wrap each in a ≥48px-tall container.

**Priority:** High
**Effort:** Small
**Verification:** Hit-test bounds ≥48 in all three; inspector confirms.

---

### Issue M-12: `AppBarTheme` contradicts `MobileTopBar`

**Platform:** Mobile
**Location:** `sitewise_theme.dart:53–58` (`backgroundColor: ink`, `foregroundColor: white`) vs `mobile_topbar.dart:35–37` (`surface` / `ink`)

**Current implementation:** The theme declares a dark app bar; the actual top bar overrides it to light.

**Problem:** Any page mounting a raw `AppBar` gets dark chrome while the rest of the app is light.

**Why it matters:** Two competing chrome identities in one app; a latent inconsistency that will surface the moment someone adds a page without `MobileTopBar`.

**Recommended change:** Align `AppBarTheme` with the light `surface`/`ink` treatment that is actually used.

**Priority:** Medium
**Effort:** Small
**Verification:** Any route rendering a default `AppBar` matches `MobileTopBar`'s appearance.

---

### 7.3 Medium and Low findings — consolidated

**Medium**

| ID | Platform | Location | Issue | Fix | Effort | Verification |
|---|---|---|---|---|---|---|
| `M-04` | Mobile | `entrepreneur_profile_mobile_page.dart:252–254` | `38×38` leading tile | 48×48, or confirm ListTile delegates the full row hit area | S | Inspector bounds |
| `M-05` | Mobile | `mobile_property_card.dart:44,86,249,454`; `mobile_featured_banner.dart:43`; `sitewise_cta_button.dart:33`; `landing_mobile_sections.dart:154,331,399` | Radii `16/20/14/11/9` with no token | Add `radiusLg=16`, `radiusXl=20` to `SitewiseSpacing`; reference them | M | `grep "BorderRadius.circular("` shows only token refs |
| `M-06`/`C-02` | Mobile | Throughout presentation | ~250 `SizedBox`/`EdgeInsets` off the 4/8/16/24/32 scale (`7,11,13,14,3,5,10`) | Round to tokens; comment intentional optical tweaks | L | Visual regression pass per screen |
| `M-11` | Mobile | `sitewise_search_bar.dart:19–30` | No `textInputAction`, `semanticsLabel`, or clear affordance | Add `TextInputAction.search` + semantics + clear suffix | S | Keyboard shows Search; SR announces the hint |
| `M-13` | Mobile | `mobile_bottom_nav.dart:47–48` | `11sp` nav labels | Raise to 12sp; check the longest label | S | No clipping at smallest width |
| `M-16` | Mobile | Throughout | Inline `TextStyle` instead of `Theme.textTheme` | Map high-frequency patterns to theme styles first | L | Changing one theme style propagates |
| `M-23` | Mobile | `owner_add_property_mobile_page.dart:147–151` | Stepper validates only on the final step | Validate the current step before advancing | M | Empty step-1 field blocks progression with a visible error |
| `M-24` | Mobile | Add-property + auth forms | No `textInputAction` chaining | `next` on all but last, `done` on last | S | Keyboard Next moves focus |
| `M-25` | Mobile | `mobile_featured_banner.dart` painters; onboarding visuals | Decorative painters exposed to the a11y tree | `ExcludeSemantics` | S | SR traversal skips them |
| `W-03` | Web | 18 inline `style` attrs, e.g. `entrepreneur/dashboard_page.dart:85,112` | Static `gap` values inline, against the CSS-only rule | Add `.gap-8/.gap-12/.gap-16` utilities | M | `grep "'style':"` returns only dynamic map-pin positions |
| `W-08` | Web | `app_layout.dart:84–93` | Active nav has no `aria-current` | Add `attributes: {'aria-current': 'page'}` | S | SR announces current page |
| `W-09` | Web | `app_layout.dart:51`; `entrepreneur/dashboard_page.dart:62` | Topbar title is a `<div>`; content `<h1>` is the only heading | Make `.topbar__title` the `<h1>`, demote content | S | Exactly one `<h1>`, no skipped levels |
| `W-11` | Web | `entrepreneur/explore_page.dart:315` | Score colour injected via inline `style` | Use the existing `.text-success/action/warning/danger` classes | S | No `style` attribute on score elements |
| `W-13` | Web | `styles.css` explore `@media (max-width:1100px)` (~1748–1783) | `.explore__detail` and `.explore__zoom` share `bottom: 16px` — **Unverified: visual overlap not observed** | Move zoom to `top: 16px` at that breakpoint | S | Open explore at 1000px; zoom is unobstructed |
| `W-16` | Web | `admin/dashboard_page.dart:98–100` | Stats use `.row .grow`, so they never stack | Use `.stat-grid` | S | At 600px stats stack vertically |
| `W-17` | Web | `landing_page.dart` `_HeroVisual`, `_MapVisual` | Decorative compositions read as content | `aria-hidden="true"` on the container | S | SR skips the illustration |
| `C-05` | Mobile | Throughout | 55+ hardcoded user-facing strings | Centralise into a strings file (or `.arb`) | L | `grep "Text('[A-Z]"` returns few hits |
| `C-06` | Mobile | `mobile_auth_page.dart:42,78–103,133–291` | Auth flow, validation, OAuth, and layout in one 395-line widget | Extract an `AuthCubit`; page observes only | M | Zero direct service calls in the page |
| `C-08` | Web | `styles.css` (~15 non-token hex/rgba) | Literal `#fff`, `#f7fbff`, `rgba(...)` inside component rules | Add `--white`, `--geo-wash-light`, alpha tokens | M | Only `:root` contains literals |
| `C-09` | Mobile | `panorama_capture_viewmodel.dart`, `tour_preview_viewmodel.dart` | Three state patterns coexist | Standardise on Cubit; keep `setState` for local UI only | L | One pattern for business state |
| `S-01`/`S-03` | Shared | theme vs `styles.css` `.btn`/`.card` | Control radius 10 vs 16; card radius 12 vs 16 | Introduce shared `controlRadius`/`radiusLg` | S | Measured radii match across platforms |
| `S-04` | Shared | `sitewise_stat_card.dart` vs `ui.dart:204–235` | Mobile has icon tile + delta; web has neither | Add `delta` to web `StatCard`; decide on the icon tile | M | Dashboard hierarchy matches |
| `S-05` | Shared | `sitewise_status_badge.dart` vs web `Pill` | Flutter takes raw `Color`; web takes a semantic tone | Add a Flutter tone enum; resolve internally | M | No `Color` arguments at badge call sites |
| `S-07` | Shared | `sitewise_cta_button.dart:29` vs `styles.css:374` | CTA is `accent` on mobile, `action` on web | Align on `action` unless CTA deserves its own token | S | Same fill sampled on both |
| `S-08` | Shared | `sitewise_spacing.dart` | `12` used 80+ times with no token | Add intermediate tokens | L | `SizedBox(height:12)` references a token |
| `C-10` | Shared | theme score ramp vs web | Ramp thresholds centralised on mobile only | Move to `shared_logic` | S | Both consume identical thresholds |

**Low**

| ID | Platform | Location | Issue | Fix |
|---|---|---|---|---|
| `M-17` | Mobile | `sitewise_bottom_sheet.dart:33` | `Colors.grey.shade300` grabber | Use `SitewiseColors.border` |
| `M-21` | Mobile | `sitewise_theme.dart:110,114,118` | Input radius `10` vs `SitewiseSpacing.radius` 12 | Reference the token |
| `M-22` | Mobile | `sitewise_theme.dart:104` | Chip radius `20` hardcoded | Add a pill token |
| `W-07` | Web | `styles.css` `#fff`, `#f7fbff` | Literals outside `:root` | Tokenise |
| `W-12` | Web | `styles.css:638` targets `.footer-links button` | Dart emits `<a>` | Change the selector to `a` |
| `W-15` | Web | `styles.css:1228–1248` | Global `4px` focus radius on a `999px` circular button | Add `.p-card__save:focus-visible { border-radius: 999px }` |
| `W-18` | Web | `styles.css:419–424` | `pointer-events: none` removes disabled buttons from keyboard reach | Use the native `disabled` attribute |
| `C-03` | Shared | 13 mobile + 6 web files >300 lines | Monolithic files | Decompose incrementally (see §9 Stage 5) |



---

## 8. Prioritized Fix List

Ordered for implementation. Dependencies noted.

| Order | Issue | Why now | Depends on | Effort |
|---|---|---|---|---|
| 1 | `W-05` mobile nav below 900px | Only defect that makes the product unusable | — | L |
| 2 | `W-01` + `W-02` + `W-14` overlay keyboard + ARIA | Blocking a11y, same files, one pass | — | M |
| 3 | `M-09` mobile `Semantics` coverage | Largest a11y gain per unit of risk; additive | — | L |
| 4 | `M-03`, `M-01`, `M-02`, `M-19`, `M-20` touch targets | Five small edits; contract violations | — | S each |
| 5 | `M-15` `RichText` → `Text.rich` | One line, highest severity-to-effort ratio | — | S |
| 6 | `S-06` `overlineText` token | Known AA failure, already solved on web | — | M |
| 7 | `W-10` form labels | Small edit, real a11y + usability gain | — | S |
| 8 | `W-04` table caption/scope | Small, isolated | — | S |
| 9 | `C-04` + `S-02` verification mapping + wash tokens | Unblocks the colour cleanup; removes 4-way duplication | — | S + M |
| 10 | `M-10`, `M-14`/`C-07` form validation + states | Data integrity and reliability | — | S + M |
| 11 | `S-01`, `S-03`, `S-07`, `M-12` token/shape alignment | Cross-platform consistency; cheap | after 9 (tokens) | S |
| 12 | `C-01` full hardcoded-colour sweep | Large but mechanical | after 9 | L |
| 13 | `W-03`, `W-08`, `W-09`, `W-11`, `W-16`, `W-17` web interaction/a11y | Independent, low risk | after 2 (same files: `W-03`/`W-11`) | M total |
| 14 | `C-06` auth cubit extraction | Reduces the riskiest test gap | — | M |
| 15 | `M-06`/`C-02` spacing tokenisation | Large; do incrementally with visual checks | after 11 | L |
| 16 | `C-03` file decomposition | Improves velocity; not user-visible | — | L |
| 17 | `M-16`, `C-05`, `C-08`, `C-09`, `S-04`, `S-05`, `S-08`, `C-10` | Structural debt | — | L total |
| 18 | Low-priority polish (`M-17`, `M-21`, `M-22`, `W-07`, `W-12`, `W-15`, `W-18`) | Cosmetic / minor | — | S total |

---

## 9. Recommended Implementation Plan

Adapted to the actual findings. Stages 1–4 are where the user-visible value is; Stage 6 is mandatory before any release claim.

**Stage 1 — Functional and critical layout defects.**
`W-05` (mobile nav below 900px), then `W-01`/`W-02`/`W-14` (overlay keyboard + ARIA). These are the only items that block a workflow outright. Ship and verify at 899/768/480px and with keyboard-only navigation before touching anything else.

**Stage 2 — Mobile accessibility and touch targets.**
`M-15` (one line), the touch-target fixes (`M-01`, `M-02`, `M-03`, `M-19`, `M-20`), `S-06` (`overlineText`), then `M-09` (`Semantics` coverage across the seven priority widgets). Test with TalkBack/VoiceOver on a physical device — the emulator's screen reader behaves differently enough to matter.

**Stage 3 — Web layouts, forms, and interaction states.**
`W-10` (labels), `W-04` (tables), `W-08` (`aria-current`), `W-09` (heading order), `W-13` (verify and fix the explore overlap — **confirm the overlap visually first**, since it is currently unverified), `W-16` (stat grid), `W-17` (`aria-hidden`), `W-11` + `W-03` (inline-style elimination alongside the gap utilities).

**Stage 4 — Standardise tokens and shared components.**
`S-02` + `C-04` (wash tokens + one verification mapping), then `S-01`/`S-03`/`S-07` (radius and CTA alignment), then `C-01` (full colour sweep), then `C-10` (move the score ramp into `shared_logic`). Mirror every token change into **both** `styles.css` and `sitewise_theme.dart` in the same commit, per `DESIGN.md` §8.17. Also re-sync `DESIGN.md` §4/§7 with the current 1876-line stylesheet.

**Stage 5 — Accessibility depth, performance, maintainability.**
`M-10`/`M-14`/`C-07` (validation + state coverage), `C-06` (auth cubit), `M-06`/`C-02` (spacing tokenisation, incremental, with visual checks per screen), `C-03` (decompose the 19 oversized files), `C-09` (state-pattern consolidation), `M-16` (theme text styles), `C-05` (strings), `C-08` (CSS token closure). Then a real performance pass: bundle analysis, Lighthouse, and a Flutter profile trace — **none of which has been done yet**.

**Stage 6 — Regression checks across mobile and web.**
Run the §10 checklist at every listed viewport, on both platforms, as **each** of the three roles. Include a keyboard-only pass on web and a screen-reader pass on mobile. Re-run after every subsequent stage, not only at the end.

**Early low-cost win, do it in Stage 1 if convenient:** `M-15` and the `M-02` 2px CTA fix are single-line changes with real accessibility impact and near-zero regression risk.

---

## 10. Verification Checklist

**Web viewports** — 1920×1080, 1440×900, 1280×800, 1100×800 (breakpoint edge), 1024×768, 899×700 (**sidebar boundary**), 768×1024, 480×800, 360×640.

For each width, authenticated as **Admin, Owner, Entrepreneur** plus public:

- [ ] Primary navigation is reachable — **this is the `W-05` regression check**
- [ ] No horizontal scrollbar; no content clipped or overlapped
- [ ] Tables scroll horizontally inside `.panel` rather than breaking the layout
- [ ] Topbar title and subtitle ellipsize rather than wrap or overflow
- [ ] Explore: panel/map split behaves, and zoom controls are unobstructed (**`W-13`**)

**Web keyboard-only pass:**

- [ ] Every interactive element is reachable by Tab
- [ ] Focus is always visible (`2px --action` ring, matching the element's shape — **`W-15`**)
- [ ] Tab order follows visual order
- [ ] Search / notifications / avatar menu: focus enters the panel, Tab is trapped, Escape closes, focus returns to the trigger (**`W-01`**)
- [ ] Active sidebar item exposes `aria-current="page"` (**`W-08`**)

**Web screen reader pass (NVDA or VoiceOver):**

- [ ] Overlays announce as dialogs; triggers announce expanded/collapsed (**`W-02`, `W-14`**)
- [ ] Tables announce a caption and associate headers with cells (**`W-04`**)
- [ ] Form labels are announced as the input's name; clicking a label focuses its input (**`W-10`**)
- [ ] Exactly one `<h1>` per page, no skipped heading levels (**`W-09`**)
- [ ] Landing decorative visuals are skipped (**`W-17`**)

**Mobile devices** — small phone (~360×640dp), standard phone (~390×844dp), large phone (~430×932dp), small tablet. Test at 100%, 150%, and **200% system font scale**.

- [ ] No overflow or clipping at any scale; the landing hero scales with the rest (**`M-15`**)
- [ ] All tap targets ≥48×48: card save/compare, featured-card save and CTA, landing role links, footer links (**`M-01`, `M-02`, `M-03`, `M-19`, `M-20`**)
- [ ] Bottom-nav labels legible and unclipped, including the longest role label (**`M-13`**)
- [ ] Back navigation returns to the expected parent from every detail route
- [ ] Forms: invalid input is rejected inline with a visible message; keyboard Next/Done chains correctly (**`M-10`, `M-24`**)
- [ ] Stepper blocks progression past an incomplete step (**`M-23`**)
- [ ] Every data page shows a loading state, then either content, a labelled empty state, or an error with retry (**`M-14`**)

**Mobile screen reader pass (TalkBack or VoiceOver):**

- [ ] A property card announces as one actionable item, including price and saved state (**`M-09`**)
- [ ] Save/compare icons announce as buttons with their action
- [ ] Decorative painters are absent from traversal (**`M-25`**)
- [ ] Search field announces its purpose

**Cross-platform consistency** (run after Stage 4):

- [ ] Buttons, cards, and inputs share the same corner radii on both platforms (**`S-01`, `S-03`**)
- [ ] The primary CTA is the same blue on both (**`S-07`**)
- [ ] The same verification status renders the same colour pair on both (**`C-04`**)
- [ ] Small muted text passes 4.5:1 on both (**`S-06`**)
- [ ] Any token changed in `styles.css` is changed in `sitewise_theme.dart` in the same commit

**Automated (none currently run):**

- [ ] axe-core or Lighthouse accessibility ≥ 95 on `/`, `/login`, `/admin/users`, `/entrepreneur/compare`, `/owner/add-property`
- [ ] `flutter analyze` clean
- [ ] `grep -r "Color(0x" fyp_mobile_app/lib/presentation` → painter files only
- [ ] `grep -rn "'style':" fyp_jaspr_web/lib` → dynamic map-pin positions only

---

## Appendix — Issue Index

| Prefix | Count | Domain |
|---|---|---|
| `W-01`–`W-18` | 18 | Web UI |
| `M-01`–`M-25` | 25 | Mobile UI |
| `S-01`–`S-08` | 8 | Shared design system |
| `C-01`–`C-10` | 10 | Code quality |
| **Total** | **61** | |

**Severity:** Critical 7 (`W-05`, `W-01`, `M-09`, `M-03`, `M-15`, `M-19`, plus `S-02`/`C-01` colour drift counted under High) · High 12 · Medium 26 · Low 8 · **plus** items explicitly marked **Unverified** needing runtime confirmation: `W-13` (explore overlap), `M-10` (exact current field configuration), and all rendered-layout/performance claims.

**No source files were modified during this audit.** No application was run, built, or served; no tests were executed; no screenshots were captured.