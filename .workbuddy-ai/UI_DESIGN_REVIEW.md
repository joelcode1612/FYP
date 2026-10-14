# Sitewise UI Design Review & Optimisation Proposals

Date: 2026-10-09
Reviewed: `Sitewise_UI_Experiment` (baseline identical to `FYP` for all pre-existing UI)
Scope: design-system consistency, accessibility, responsive behaviour, component reuse

---

## 1. What is already strong

Worth stating, because the proposals below are refinements of a good system, not a rescue.

- **Real design tokens.** `SitewiseColors` / `SitewiseSpacing` are a genuine single source
  of truth, and `sitewiseTheme()` centralises Material theming rather than styling ad hoc.
- **A real component library.** 21 shared widgets, plus separate mobile (17) and web (2)
  sets. `SitewiseEmptyState` alone is used 18 times, `SitewiseLoadingState` 35 times.
- **Correct role/environment separation.** Web and mobile are distinct widget trees
  (`presentation/web` vs `presentation/mobile`) resolved by width — no `if (isWeb)` branches
  inside pages. This is the right architecture and it is actually followed.
- **Consistent visual language.** Border radii, spacing rhythm, border colours and the
  ink/action/muted hierarchy are applied consistently across screens.
- **Colour semantics are disciplined** — the same status never renders two different colours
  in two places, because status→colour mapping is centralised in `AiDssStatusStyle`.

---

## 2. Findings

### P0 — Crashes (FIXED in this session)

`SitewiseCtaButton` is `SizedBox(width: double.infinity)`. A `Row` gives its non-flexible
children **unbounded width**, so an infinite width trips a hard assertion
(`rendering/box.dart:611`, `BoxConstraints forces an infinite width.`) and renders the red
error screen. Six sites placed it in a `Row`, so the AI-DSS flow could not render:

| File | Line | Context |
|---|---|---|
| `create_assessment_web_page.dart` | 149 | create form row |
| `assessment_overview_web_page.dart` | 395 | `_QuestionPanel` submit row |
| `assessment_overview_web_page.dart` | 566 | `_AnalysisPrompt` row |
| `assessment_findings_web_page.dart` | 66 | passed to `actions:` → `WebTopBar` row |
| `assessment_findings_web_page.dart` | 681 | `_NoFindings` row |
| `assessment_recommendations_web_page.dart` | 493 | `_NoAnalysis` row |

**Fixed** by adding an explicit `width` to `SitewiseCtaButton` (defaults to
`double.infinity`, so all Column usages are unchanged) and passing finite widths in Rows.

Also fixed: the mobile assessment flow was a **dead end**. `startAssessment()` was only
ever called by the *web* create page, so on the mobile tree the questionnaire opened with a
null session and showed "No question is available." Added `CreateAssessmentMobilePage` and
made the empty state offer "Start assessment" instead of a dead-end "View progress".

### P1 — Accessibility: text contrast fails WCAG AA

Computed against the white surface (`#FFFFFF`), WCAG AA needs 4.5:1 for normal text.

| Token | Hex | Contrast | Verdict |
|---|---|---|---|
| `overline` | `#98A2B3` | **2.60:1** | fails (used as text **53 times**) |
| `success` | `#0E9F6E` | **3.41:1** | fails as text |
| `action` | `#2F6FED` | 4.50:1 | borderline pass |
| `danger` | `#D92D20` | 4.67:1 | pass |
| `muted` | `#667085` | 4.98:1 | pass |
| `warning` | `#B54708` | 5.13:1 | pass |

The two failures matter because both are used for **small** text: `overline` is the 10–11px
eyebrow label, and `success` renders 12px status text inside pills.

Status pills compound it — `success` on `successWash` is **2.98:1**:

| Pill | Foreground on its wash | Contrast |
|---|---|---|
| Above threshold | `success` on `successWash` | 2.98:1 |
| Below threshold | `danger` on `dangerWash` | 4.36:1 |
| Insufficient data | `warning` on `warningWash` | 4.42:1 |
| On track | `action` on `geoWash` | 4.02:1 |

Also: only **2** `Semantics(...)` widgets and **0** `semanticLabel`s in the whole codebase,
so screen-reader coverage is largely whatever Flutter infers from `Text`.

### P1 — Token discipline is stated but not enforced

`sitewise_theme.dart` says plainly: *"Pages must consume [SitewiseColors]/[Theme.of] —
never hardcode hexes."* There are **99 hardcoded `Color(0x...)` literals** in
`lib/presentation`. 14 of them were mine, including four wash colours that
`sitewise_status_badge.dart` had already declared — the same four hexes were duplicated
across **seven files**.

The remaining ~85 sit mostly in illustration code (`intro_hero_visual.dart` 15,
`landing_web_sections.dart` 14, `onboarding_painters.dart` 9) where literal colour is more
defensible, but the rule as written is being violated throughout.

### P2 — Parallel implementations of existing components

My AI-DSS screens hand-rolled components that already exist:

- **4 bespoke empty states** (`_NoSession` ×2, `_NoFindings`, `_NoAnalysis`, `_NotAnalysed`)
  while `SitewiseEmptyState` is the established pattern with 18 usages.
- **3 bespoke stat cards** (`_Stat`, `_KpiCard`, `_DarkStat`) while `SitewiseStatCard` has 9.

Each is a slightly different interpretation of the same idea, which is how a design system
drifts.

### P2 — No dark mode

`MaterialApp` sets `theme:` but no `darkTheme:` / `themeMode:` (0 occurrences). The app
ignores OS dark mode entirely. Every screen is built on light-surface assumptions, so this
is a feature gap rather than a bug.

### P2 — Responsive cliff at 1024px

`PresentationEnvironmentResolver.webBreakpoint = 1024`. At exactly 1024px the web tree
renders a fixed 236px sidebar, leaving ~788px for content whose `maxWidth` is 1080 — so the
web layout is at its most cramped precisely at the breakpoint, then jumps to the mobile tree
below it. Tablets in landscape and small laptop windows sit in the worst part of the range.

---

## 3. Proposals

Ordered by value-to-risk. Nothing here is implemented yet unless marked.

### A. Contrast: add contrast-safe text tokens (recommended)

Keep the vivid tokens for **fills and icons**; add `*Text` variants for **on-light text**.
This preserves the brand colours while fixing the failures.

```dart
static const Color overlineText = Color(0xFF6B7280); // 4.82:1 on white
static const Color successText  = Color(0xFF0B815A); // 4.96:1 on white
```

Then swap the 53 `color: SitewiseColors.overline` **text** usages to `overlineText`
(keeping `overline` for borders/icons, where 3:1 is the bar and it passes), and use
`successText` inside `AiDssStatusPill` / status badges.

Eyebrow labels stay visually distinct through size, weight and letter-spacing rather than
low contrast — which is the standard accessible pattern.

### B. Enforce the token rule

1. Add the wash tokens (done — `successWash`, `warningWash`, `dangerWash`, `neutralWash`).
2. Add an `analysis_options.yaml` lint or a small CI grep that fails on `Color(0x` outside
   `lib/core/theme/` and the illustration files, so the rule stops being aspirational.
3. Migrate the illustration hexes opportunistically, not in one sweep.

### C. Consolidate bespoke components

Replace my 4 empty states with `SitewiseEmptyState` and the 3 stat cards with
`SitewiseStatCard`. Note this **is** a visual change: `SitewiseEmptyState` centres a
circular `geoWash` icon badge, whereas my versions are left-aligned bordered cards inside a
scrolling column. Worth deciding which is correct before migrating.

### D. Screen-reader coverage

Add `Semantics`/`semanticLabel` to the composite widgets that lose meaning when flattened —
`AiDssBenchmarkBar` (currently a `Stack` of coloured boxes, meaningless to a screen reader),
`AiDssStatusPill`, the trace utility bars, and the property cards' image/price pairs.

### E. Responsive

Lower `webBreakpoint` to ~900 and/or make the sidebar collapsible below ~1200px, so the
1024–1280 range gets a usable web layout instead of the tightest one.

### F. Dark mode

Add `darkTheme:` + `themeMode: ThemeMode.system`. Requires a dark variant of the palette;
tokens make this tractable, but it is a real piece of work and should be scoped separately.

---

## 4. Verification status

**What was verified**

- `dart format` — clean (219 files, 0 changes).
- **Type/symbol check: 0 errors in project files.** `dart compile js lib/main.dart` compiles
  the whole app through the Dart front end, which performs full static type checking. Its
  output contains ~56,000 errors, but **every one is inside the Flutter SDK** (they carry the
  signature `invalid-type`, i.e. the compiler failing to resolve SDK types in this
  environment). Filtering to files under `Sitewise_UI_Experiment/` yields **0**. The untouched
  baseline produces ~55,900 of the same SDK-internal errors and likewise 0 in project files,
  which is what establishes the noise as environmental rather than ours.
  This proves the changed code has no syntax, type, or unresolved-symbol errors — including
  the new `create_assessment_mobile_page.dart` and the modified `app_routes.dart`.
- Hardcoded hexes in AI-DSS code — 0 remaining; 16 new token usages.

**What was NOT verified**

- `flutter analyze` / `flutter test` — **cannot run on this machine.** The Windows pipe pool
  is exhausted (`CreateFile failed 231`, `process_win.cc:742`), so `dart analyze` cannot spawn
  its analysis server.
- A Python LSP harness was written to work around that. It failed twice on this project:
  a full run over 221 files reported `0/221`, and a focused run over just the 8 changed files
  reported `0/8` after hitting a 25-minute ceiling. **A "0 errors" reading from that harness
  is meaningless**, because it published diagnostics for zero files. It is reported here only
  to record that the workaround is a dead end, not as evidence.
- **The crash fix itself is a runtime concern and remains unexecuted.** A layout assertion
  fires during `performLayout`, which no static analyser — and no amount of compilation —
  can detect. The reasoning is solid (the assertion is documented at `box.dart:611`, and the
  six call sites were each confirmed to sit in a `Row`), but it should be confirmed with
  `flutter run -d chrome` before being trusted.
- No test was added for this class of bug. A widget test that pumps each assessment screen
  would catch it, and is the right long-term guard — see proposal G.

## 5. Proposal G — regression guard for layout errors

The bug fixed in section 2 was invisible to every static tool available here. The durable
fix is a widget test that simply pumps each assessment screen at a desktop and a phone
surface size and asserts no exception is thrown:

```dart
testWidgets('assessment screens lay out without exception', (tester) async {
  tester.view.physicalSize = const Size(1440, 900);
  await tester.pumpWidget(/* app at /entrepreneur/assessment/create */);
  expect(tester.takeException(), isNull);
});
```

Cheap to write, and it would have caught this before it reached you.

