# Sitewise — Jaspr Web

The Sitewise web frontend, rebuilt with [Jaspr](https://jaspr.site) so it renders
**real HTML and CSS** instead of a Flutter canvas.

This is a **separate project** from the Flutter app. It does not replace or modify
`C:\Users\Lenovo\AndroidStudioProjects\FYP`; that project is untouched.

---

## Why Jaspr

Flutter Web paints widgets onto a `<canvas>`. Search engines, link previews and
screen readers see essentially an empty canvas element. The Flutter team's own
position is that *"Flutter Web is for building Web-Apps, not Web-Sites."*

Jaspr is a Dart web framework with the same component model you already know, but
it emits real DOM. That matters for exactly one part of Sitewise: the **public
landing page**, which is the only surface that is public, pre-auth, and therefore
the only one where being indexable is worth anything. Everything else sits behind
a login where SEO is irrelevant.

> **This is an architecture change, not a refactor.** The project report states
> ASR-1 as *"Flutter Mobile + Web, one codebase"*. Moving web to Jaspr makes it
> **two codebases** (Flutter for mobile + app, Jaspr for web). That is a claim in
> the report that this work invalidates, and it should be updated if this port
> continues.

---

## Status

| Area | Flutter source | Jaspr status |
|---|---|---|
| Landing page | `web/landing/` (1,705 lines) | **Ported** |
| Design system | `core/theme/sitewise_theme.dart` | **Ported** → `web/styles.css` |
| Shared components | `presentation/shared/widgets/` (20) | Partially ported → `lib/components/ui.dart` |
| App shell (sidebar/topbar) | `web/shell/` (866 lines) | Not yet |
| Entrepreneur (10 pages) | `web/entrepreneur/` | Not yet |
| Property owner (7 pages) | `web/property_owner/` | Not yet |
| Administrator (8 pages) | `web/admin/` | Not yet |

Routes that are not ported yet render an explicit `PendingPage` rather than
falling through to a blank screen, so no link on the landing page dead-ends.

---

## Running it

Requires a working Dart toolchain.

```shell
dart pub get
jaspr serve          # http://localhost:8080
jaspr build          # static output in build/jaspr
```

If `jaspr` is not installed:

```shell
dart pub global activate jaspr_cli
```

**Tooling status on the machine this was authored on.** `dart pub global
activate jaspr_cli` first failed at *"Building package executables"*, then
succeeded on retry — `jaspr.bat` is now installed at
`%LOCALAPPDATA%\Pub\Cache\bin\jaspr.bat`. That directory is usually not on PATH,
so call it by full path or add it.

`jaspr serve` now starts and reports:

```
Running jaspr in static rendering mode.
⠋ [CLI] Starting web compilers......
⠹ [BUILDER] Connecting to the build daemon......
CreateFile failed 231 (All pipe instances are busy.)
```

So the CLI and the project are correct; the **build daemon** is what fails,
because it spawns a subprocess and Windows named-pipe instances are exhausted
system-wide (`process_win.cc:742`). No workaround exists — `dart run
build_runner` and `dart compile kernel` fail identically. **A reboot is
required**, after which `jaspr serve` should reach `http://localhost:8080`.

**Do not use `webdev serve` as a substitute.** `webdev` is the tool for plain
Dart web apps built with `build_runner`; it is not a Jaspr runner. It looks for
a Dart entry under `web/` and shells out to `.\bin\dart pub deps`, which fails
with *"The system cannot find the file specified"* — and even if it started, it
would serve `web/index.html` as a Dart entry point rather than running Jaspr's
build pipeline.

What **was** verified here:

```
dart compile js lib/main.server.dart -o /tmp/main.js
→ Compiled 16,063,183 input bytes … to 1,405,691 characters JavaScript
```

Zero errors. This compiles the real entry point, so it type-checks the entry
*and* everything reachable from it — `app.dart`, every page, every component.
`dart compile js tool/typecheck.dart` additionally covers components the app does
not currently reach.

An earlier claim of "zero errors" was **wrong**: the harness did not import the
entry point, so it never checked it, and two real errors sat there undetected
(see the import gotcha below). Compiling the real entry point directly is the
check that matters.

Compiling proves the code is *valid*, not that the page *renders* — only
`jaspr serve` can show that.

---

## Gotcha: the entry point must be named `*.server.dart`

`jaspr serve` refuses to start without one:

```
[CRITICAL] No server entrypoint found in "bin/" or "lib/".
Make sure to have at least one "*.server.dart" file
(usually "lib/main.server.dart") in your project.
```

The entry is therefore **`lib/main.server.dart`**, not `lib/main.dart`. This
applies to `static` and `server` rendering modes.

## Gotcha: never import both `jaspr.dart` and `server.dart`

`package:jaspr/jaspr.dart` and `package:jaspr/server.dart` **each** export a
`runApp` and a `Document` — the client stub and the server implementation. A
file importing both gets:

```
error: The name 'runApp' is defined in the libraries
  'package:jaspr/src/server/run_app.dart (via package:jaspr/server.dart)' and
  'package:jaspr/src/stub/run_app_stub.dart (via package:jaspr/jaspr.dart)'.
  (ambiguous_import)
error: 'Document' isn't a function. (invocation_of_non_function)
```

The rule:

| File kind | Import |
|---|---|
| Entry point (`main.server.dart`) — uses `runApp`, `Document` | `jaspr/dom.dart` + **`jaspr/server.dart`** |
| Components/pages — use `div`, `text`, `StatelessComponent` | `jaspr/dom.dart` + **`jaspr/jaspr.dart`** |

`jaspr/dom.dart` is safe in both; it is only the `runApp`/`Document` pair that
collides.

---

## Layout

```
lib/
  main.server.dart             entry: Jaspr.initializeApp + runApp(Document(...))
  app.dart                     route table (Router/Route)
  components/ui.dart           Brand, Pill, Eyebrow, SectionHead,
                               ActionLink, ActionButton, StatCard,
                               StepCard, FeatureRow, WeightBar, Icon
  data/site_content.dart       copy + data ported from LandingContent
  layouts/marketing_layout.dart  masthead + footer
  pages/landing_page.dart      the landing page
tool/
  typecheck.dart               verification harness (not shipped)
web/
  index.html                   fonts + stylesheet
  styles.css                   THE design system
```

### The one thing to understand before editing

**All styling lives in `web/styles.css`.** Jaspr has no pre-styled component
library, and its `text()` takes only a `String` — there is no `TextStyle`. Every
colour, size and weight that lived in a Flutter `TextStyle` has to be a CSS rule.
So `styles.css` is the equivalent of `SitewiseColors`, and Dart files compose
class names.

That also means the port is not mechanical: `Text(..., style: TextStyle(fontSize:
13, fontWeight: FontWeight.w700))` becomes a CSS class, not a translated call.

---

## Differences from the Flutter version

Beyond syntax, three things are deliberately better rather than merely different:

1. **Anchors instead of imperative scrolling.** The Flutter page held a
   `GlobalKey` per section and called `Scrollable.ensureVisible`. Here the masthead
   links are `#how`, `#geo`, … and CSS `scroll-behavior` does the work — no
   JavaScript, and the links are crawlable.
2. **No `CustomPainter`.** The Flutter hero and map visuals were canvas painters.
   These are CSS gradients and positioned elements, so they scale, print, and
   respect the user's font-size settings.
3. **Accessible text contrast.** `SitewiseColors.overline` (`#98A2B3`) is only
   2.60:1 on white and fails WCAG AA for small text, yet the Flutter tree uses it
   as a text colour 53 times. This CSS keeps `--overline` for borders and icons
   (where 3:1 applies) and adds `--overline-text` (`#6B7280`, 4.82:1) plus
   `--success-text` (`#0B815A`, 4.96:1) for text.

---

## Icons

Flutter uses `Icons.storefront_outlined` (an `IconData`). Jaspr has no such type,
so `data/site_content.dart` stores the Material Symbols *name* (`'storefront'`)
and `Icon` renders `<span class="ms">storefront</span>`. Keeping the name rather
than a code point keeps the data readable and comparable with the Flutter source.
