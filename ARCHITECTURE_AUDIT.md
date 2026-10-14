# Sitewise FYP — Architecture Audit

Date: 2026-10-11
Auditor: architecture review pass (Phases A–B)
Scope: `FYP` (Flutter), `fyp_workspace/shared_logic`, `fyp_workspace/fyp_jaspr_web`

---

## 1. Correction to the brief's premise

The brief asks me to refactor **BLoCs** and migrate them into `shared_logic`.

**There are no BLoCs in this project.** Verified:

```
grep -rl "package:bloc|package:flutter_bloc|package:riverpod|package:provider|package:get_it" lib/
→ (no matches)
```

`pubspec.yaml` declares no state-management or DI package at all. The actual
state layer is:

| Mechanism | Where | Count |
|---|---|---|
| `ChangeNotifier` | `lib/application/state/`, `lib/application/onboarding/`, `lib/presentation/shared/viewmodels/` | 7 classes |
| Static-field service locator | `lib/application/services/service_locator.dart` | 1 |

So the migration is **`ChangeNotifier` → `Cubit`**, not "move the existing BLoCs".
This matters because it changes the work from *relocation* to *rewriting*, and it
means the state layer must be rewritten before any of it can be shared — every
`ChangeNotifier` imports `package:flutter/foundation.dart` and therefore cannot
live in a framework-free package.

---

## 2. Current architecture

```
C:\Users\Lenovo\AndroidStudioProjects\
├── FYP\                          Flutter app, package name `fyp`, branch main @ 59e19a0
│   └── lib\
│       ├── domain\        22 files   ← 0 import Flutter
│       ├── data\          17 files   ← 0 import Flutter
│       ├── core\          11 files   ← 3 import Flutter
│       ├── application\   13 files   ← 3 import Flutter
│       └── presentation\ 131 files   ← 131 import Flutter
├── fyp_workspace\                Dart pub workspace (new)
│   ├── pubspec.yaml              workspace root, shared lockfile
│   ├── shared_logic\             42 files (domain+data+core, copied from FYP)
│   └── fyp_jaspr_web\            Jaspr app (landing page + shell ported)
└── Sitewise_Jaspr_Web\           STALE DUPLICATE — delete once unlocked
```

### Layer classification

| Layer | Belongs to | Actual state |
|---|---|---|
| `lib/domain/entities`, `repositories`, `services`, `usecases` | **Shared domain** | Already pure Dart. Copied to `shared_logic`. |
| `lib/data/datasources`, `dtos`, `mappers`, `models`, `repositories` | **Data** | Already pure Dart, **except 4 files using `dart:io`**. Copied. |
| `lib/core/config`, `constants`, `errors` | **Shared core** | Pure. Copied. |
| `lib/core/routing`, `theme`, `utils` | **Flutter infrastructure** | Flutter-coupled. Must stay. |
| `lib/application/services/*` | **Application** | 11 services; mostly orchestration over repositories. |
| `lib/application/state/app_state.dart` | **Shared application** | Global UI state (role, saved, compared). Flutter-coupled only by `ChangeNotifier`. |
| `lib/presentation/shared/viewmodels/*` | **Shared application** | 5 viewmodels, 824 lines. Genuinely shared by both trees, but trapped in presentation because of `ChangeNotifier`. |
| `lib/presentation/**` (rest) | **Flutter presentation** | 131 files, all Flutter. Stays. |

---

## 3. Main architectural violations

**V1 — Shared application logic is trapped in the presentation layer.**
`lib/presentation/shared/viewmodels/` holds 5 viewmodels used by *both* the web
and mobile trees. They are shared application logic living in a presentation
folder, and they cannot be shared with Jaspr because each imports
`package:flutter/foundation.dart` for `ChangeNotifier`. This is the single
biggest violation and the highest-value fix.

**V2 — Global mutable static state (`ServiceLocator`).**
`ServiceLocator` exposes `static final` fields and *mutable* statics
(`auth`, `preferences`, `onboardingRepo`). Viewmodels reach into it directly
(`ServiceLocator.properties.listings()`), so they cannot be constructed with
substitutes and cannot be tested in isolation. §8 of the brief explicitly warns
against this pattern.

**V3 — Relative imports block extraction.**
`package:fyp/domain|data|core` imports: **0**. Files instead use relative paths
(`../domain/`, `../data/`) — **86 files** do this. Relative imports cannot cross
a package boundary, so extracting `domain`/`data` into `shared_logic` **requires**
rewriting all 86 to package imports. This is the true cost of the extraction and
is not optional.

**V4 — `dart:io` in the data layer.**
Four files import `dart:io`, which cannot exist in a browser:
`capture_frame_store.dart`, `onboarding_local_data_source.dart`,
`opencv_panorama_stitcher.dart`, `auth_repository_impl.dart` (plus
`onboarding_repository_impl.dart`, which imports the second). Already handled in
`shared_logic` by excluding them from the public export, but it means the web app
needs its own implementations of those contracts.

**V5 — Duplication introduced by the migration itself (transient).**
`shared_logic` currently holds copies of `domain`/`data`/`core` while `FYP` still
holds the originals. Until FYP is switched over and its copies deleted, the two
can drift. This is a migration window, not a target state.

**V6 — No tests protect the refactor.**
`test/` contains only `widget_test.dart` and `panorama_capture_test.dart`. There
are no tests over the domain, use cases or viewmodels — the exact code being
moved. There is no safety net.

---

## 4. Verification capability (critical constraint)

This determines what can be done safely.

| Check | Flutter app | Jaspr app |
|---|---|---|
| `dart analyze` / `flutter analyze` | ❌ blocked — Windows pipe pool (`CreateFile failed 231`) | ❌ same |
| `flutter test` / `dart test` | ❌ blocked | ❌ blocked |
| `dart compile js` | ❌ **fails inside the Flutter SDK** (`text_painter.dart`, `invalid-type`) — cannot reach project files | ✅ **works** |
| `jaspr build` / `serve` | n/a | ✅ works (user-confirmed build succeeded) |
| IDE analyzer | ✅ works (caught a real bug earlier) | ✅ works |

**Consequence:** changes to the Jaspr app and to `shared_logic` can be verified by
me. **Changes to the Flutter app cannot.** For those, the only channel is the
user's IDE diagnostics. Any Flutter-side rewrite therefore carries real risk and
should be done in small, individually-checkable steps.

---

## 5. Functionality and configuration that must be preserved

- **Git state.** `FYP` is on `main @ 59e19a0` with **staged, uncommitted work**
  (`.idea/*`, `lib/assets/models/target_reticle.glb`). Nothing may be reset,
  stashed or discarded.
- **Native/plugin dependencies:** `ar_flutter_plugin`, `opencv_dart` (with the
  `hooks.user_defines.dartcv4` stitching config), `panorama`, `path_provider`,
  `vector_math`, plus `dependency_overrides` for `permission_handler`.
- **Flutter assets:** `models/target_reticle.glb` (declared in pubspec `flutter.assets`).
- **Conditional import** in `ServiceLocator`:
  `opencv_panorama_stitcher_stub.dart if (dart.library.io) opencv_panorama_stitcher.dart`
  — the existing web-safety mechanism. Must be preserved.
- **The 360° panorama pipeline** (26 capture targets, OpenCV stitching) and the
  AR capture flow — platform-specific, must stay in Flutter.
- **Jaspr build config:** `jaspr: mode: static`, `port: 8090`, and the
  `lib/main.server.dart` entry-point naming.

---

## 6. What can be shared vs what must stay

**Safely shareable (move to `shared_logic`):**
- All 22 domain files (already there).
- All 17 data files except the 4 `dart:io` ones (already there).
- `core/config`, `core/constants`, `core/errors` (already there).
- **`AppState`** → a shared `AppCubit`: role, saved set, compare set (capped at 3),
  preview mode. Pure logic, no platform dependency once `ChangeNotifier` is gone.
- **`EntrepreneurViewModel`**, **`OwnerViewModel`**, **`AdminViewModel`** →
  shared Cubits. They contain real business logic (listing filter by query +
  property-type/city, recommendation ranking) that must not be duplicated.
- The **11 `application/services/*`** orchestration classes — these are
  application-layer, though several depend on platform services and need the
  dependency split described in §7.

**Must stay app-specific:**
- All of `lib/presentation/**` (131 Flutter files).
- `core/routing` (`app_routes.dart`), `core/theme` (`sitewise_theme.dart`),
  `core/utils/capture_log.dart` — Flutter-coupled.
- AR capture, OpenCV stitching, file-based frame storage, onboarding file
  persistence — platform-specific by nature.
- `PanoramaCaptureViewModel` (406 lines) and `TourPreviewViewModel` — these drive
  AR/capture UI and are Flutter/platform-bound; they should **not** be forced into
  the shared package.

---

## 7. Compatibility risks and unresolved decisions

**R1 — Moving `FYP` into the workspace is currently blocked.**
`mv FYP fyp_workspace/fyp_mobile_app` fails with `Device or resource busy`; 8
lingering Dart processes hold the folder. A rename probe confirms the lock. Until
the IDE and stale daemons are closed, Phase C cannot complete. FYP is intact.

**R2 — Renaming the package `fyp` → `fyp_mobile_app`.**
Not required for the workspace to function (folder name ≠ package name), and
renaming forces an import rewrite on top of the V3 rewrite. **Recommendation:
keep the package name `fyp`** and let the folder be `fyp_mobile_app`. The brief's
tree shows the folder, not the package name.

**R3 — No BLoC → Cubit rewrite is verifiable by me.**
The `ChangeNotifier` → `Cubit` migration touches 5 viewmodels and **32 consumer
files**. I cannot run `flutter analyze` or `flutter test`, and `dart compile js`
does not reach project files. This must either (a) be done in small steps with the
user pasting IDE diagnostics, or (b) be done on the shared/Jaspr side first where
it *is* verifiable.

**R4 — `flutter_bloc` becomes a new Flutter dependency.**
Required by §5 of the brief. It is a real dependency addition to a working app.
`bloc` (pure Dart) goes into `shared_logic`; `flutter_bloc` goes into `fyp_mobile_app`.

**R5 — The 86 relative imports.**
Rewriting them is mechanical but large, and unverifiable by me. It should be done
in one pass per layer with IDE verification between passes.

**R6 — `Sitewise_UI_Experiment`** exists from earlier work and is not part of the
target architecture. Out of scope unless the user says otherwise.

---

## 8. Recommended execution order

Chosen to maximise verifiable progress and avoid breaking a working app:

1. **`shared_logic` application layer** (verifiable) — add `bloc`; create
   `AppCubit`, `EntrepreneurCubit`, `OwnerCubit`, `AdminCubit` with **constructor-injected**
   repositories (not `ServiceLocator`); export them.
2. **Wire the Jaspr app** (verifiable) — consume the shared Cubits, proving the
   architecture end-to-end in a package I can compile and build.
3. **Unblock FYP** — user closes the IDE/daemons; move the folder into the workspace.
4. **Rewrite FYP's state layer** — `ChangeNotifier` → `flutter_bloc`, in small
   steps, verified through the IDE.
5. **Rewrite the 86 relative imports** to `package:shared_logic/...`.
6. **Delete FYP's duplicate `domain`/`data`/`core`** once all references are gone.
7. **Port the remaining ~25 web pages** to Jaspr.

Steps 1–2 are unblocked and verifiable today. Steps 3–5 need the user.

---

## 9. Execution results (refactor completed)

Date: 2026-10-11. All eight steps of §8 were executed; final state below.

### Structure

- **FYP itself became the workspace root** (`pubspec.yaml` with
  `workspace: [fyp_mobile_app, fyp_jaspr_web, shared_logic]`). The folder could
  not be renamed/moved (VS Code holds it open), so the target tree was reached
  by moving the Flutter package *into* `fyp_mobile_app/` instead of moving FYP
  under a new parent. Folder rename remains a trivial, optional follow-up.
- One lockfile at the root; members declare `resolution: workspace` and depend
  on `shared_logic: any` (no path dependencies).
- Node test-map server files (`test/server.js`, `test/package.json`,
  `test/public/`, `test/data/`) were accidentally swept into
  `fyp_mobile_app/test/` during the move and were restored to root `test/`.

### State layer (deviations from §6/§8)

| Original | Final home | Kind |
|---|---|---|
| `AppState` | `shared_logic` `AppCubit` | ChangeNotifier → Cubit |
| `EntrepreneurViewModel` | `shared_logic` `EntrepreneurCubit` | ChangeNotifier → Cubit |
| `OwnerViewModel` | `fyp_mobile_app/application/viewmodels/` | stays ChangeNotifier, constructor DI |
| `AdminViewModel` | `fyp_mobile_app/application/viewmodels/` | stays ChangeNotifier, constructor DI |
| `OnboardingController`, `PanoramaCaptureViewModel`, `TourPreviewViewModel` | unchanged (app) | stays ChangeNotifier (platform-bound) |

`OwnerViewModel`/`AdminViewModel` were **not** cubit-ised: they are app-only
today (Jaspr has not ported those flows), so §6's shareable list was honoured
in spirit by moving them to the application layer with constructor injection.
Read-only convenience getters on both cubits keep consumer code
(`appState.x`, `vm.y`) unchanged; the relative `Listenable.merge`/`AnimatedBuilder`
listen sites were converted to `BlocBuilder`.

### Migration scale

- 79 files: relative imports → `package:shared_logic/shared_logic.dart`.
- 22 files: `AnimatedBuilder`/`Listenable.merge` state listening → `BlocBuilder`.
- 10 + 10 entrepreneur pages: `EntrepreneurViewModel()` → `ServiceLocator.newEntrepreneurCubit()`.
- 14 owner/admin pages: constructor-DI via `ServiceLocator.newOwnerViewModel()` / `newAdminViewModel()`.
- Domain/data/core moved out of the app: 6 `dart:io` files stayed; everything
  else relocated to `shared_logic` (byte-verified before deletion).
- Jaspr: 66 deprecated top-level `text(` → `Component.text(`, unused import
  removed, `prefer_is_empty` fix → `dart analyze` clean.

### Verification (final)

| Package | Command | Result |
|---|---|---|
| `fyp_mobile_app` | `flutter analyze` | No issues found |
| `fyp_mobile_app` | `flutter test` | 27/27 passed |
| `shared_logic` | `dart analyze` | No issues found |
| `shared_logic` | `dart test` | 18/18 passed |
| `fyp_jaspr_web` | `dart analyze` | No issues found |
| `fyp_jaspr_web` | `dart run jaspr_cli:jaspr build` | OK — 18 static routes |
| `fyp_jaspr_web` | `dart run tool/typecheck.dart` | exit 0 |

Test fix note: 3 pre-existing `widget_test.dart` failures (`find.text('Skip')`)
predate the refactor — the intro page has no header "Skip" in any lineage of
this code (verified against `Sitewise_UI_Experiment`); expectations were
aligned to the actual "Skip for now" bottom-panel button.

### Risks carried forward

- **R1 resolved by structure, not rename** — FYP root rename still blocked by
  the open IDE; optional.
- **R6** — `../Sitewise_UI_Experiment` and `../Sitewise_Jaspr_Web` remain
  outside the workspace (the latter's two stale `jaspr serve` processes, which
  blocked port 8090, were stopped). Candidates for user deletion.
- `flutter_bloc`/`bloc` added as planned (R4) — versions: bloc 9.2.1,
  flutter_bloc 9.1.1.
- The 86-import rewrite (R5) completed mechanically and is covered by the
  analyzer + tests above.
- ~~Not yet done from §8: step 7 — porting remaining web pages to Jaspr~~ —
  completed in §10 below.

---

## 10. Web-tree migration to Jaspr (completed)

Date: 2026-10-11. The Flutter web tree was ported to Jaspr and removed from
the mobile app. This supersedes the §9 state-layer note: `OwnerViewModel` /
`AdminViewModel` were subsequently cubit-ised into `shared_logic`
(`OwnerCubit`, `AdminCubit`) and shared by both apps.

### What was built (fyp_jaspr_web)

- **Composition root** `lib/data/app_locator.dart` — the Jaspr counterpart of
  the mobile `ServiceLocator`: the same shared repos/services
  (demo-data mode), a client-side `AppCubit` singleton, and per-page
  `newEntrepreneurCubit()` / `newOwnerCubit()` / `newAdminCubit()` factories.
- **`CubitBuilder`** (`lib/components/bloc.dart`) — `flutter_bloc`'s
  `BlocBuilder` for Jaspr: subscribes to `cubit.stream` on the client only
  (`kIsWeb` guard; jaspr forbids streams during SSR) with `cubit.state` as
  `initialData`, so static rendering shows real state.
- **Shell upgrades** — topbar controls ported from `web_topbar.dart`
  (listing search dialog, per-role notification panel, avatar menu with
  profile link + role switch), all working without JavaScript (plain
  `?id=` links); `/login` role-picker page (landing parity).
- **Route table** (`lib/app.dart`) — explicit 28-route table mirroring
  `app_routes.dart`; detail ids moved from `settings.arguments` to `?id=`
  query params; active role derived from the URL path (`roleForPath`).
  No `/*path` wildcard (invalid filename on Windows during static
  generation); unknown paths 404.
- **25 real pages** replacing the Flutter web tree's ~3,200 lines:
  9 entrepreneur (dashboard, explore, preferences, profile, property detail,
  recommendations, report, saved, tour), 8 admin (dashboard, users, user
  detail, verification, verification detail, listings, listing detail,
  profile), 7 owner (dashboard, properties, property detail, add property,
  tours, tour preview, profile), plus the compare page (exemplar) and shared
  `PropertyCard`. Flutter-only rendering (Panorama 360°, map tiles, AR
  capture) is rendered as labelled static placeholders; capture links are
  disabled with a "runs in the mobile app" hint.
- **SSR rules learned** (encoded in the porting guide): both `StreamBuilder`
  streams and `FutureBuilder` futures must be null on the server; detail
  pages guard with `id.isEmpty → not-found` (static generation renders
  routes without query params) or use `kIsWeb`-wrapped futures.

### What was removed (fyp_mobile_app)

- `web/` (Flutter Web bootstrap: index.html, manifest, icons).
- `lib/presentation/web/` — all 33 web-tree files (landing, shell, 25 pages,
  2 widgets).
- `lib/presentation/presentation_environment.dart` (width-based web/mobile
  resolver) and `sitewise_preview_switcher.dart` (PreviewMode UI).
- `app_routes.dart` rewritten mobile-only (web imports/ternaries gone);
  `AppStartGate` and `SitewiseRoleMenu` no longer branch on environment;
  `parentShellRoute` moved into `app_routes.dart` for the bottom nav.
- `PreviewMode` remains as an (unused) enum field in shared `AppState` —
  harmless, kept to avoid touching the shared state contract.

### Verification (final, post-migration)

| Package | Command | Result |
|---|---|---|
| workspace | `flutter analyze` | No issues found |
| `fyp_mobile_app` | `flutter test fyp_mobile_app` | 27/27 passed |
| `shared_logic` | `dart analyze` + `dart test` | clean, 18/18 passed |
| `fyp_jaspr_web` | `dart analyze` | No issues found |
| `fyp_jaspr_web` | `dart run tool/typecheck.dart` | exit 0 |
| `fyp_jaspr_web` | `dart run jaspr_cli:jaspr build` | OK — 28 static routes |
| `fyp_jaspr_web` | static output spot-checks | landing/login/all three role shells render real SSR content |

`widget_test.dart` TEST 13 was inverted: a 1400×900 viewport now boots the
**mobile** onboarding (the web tree it used to assert no longer exists in
Flutter).
