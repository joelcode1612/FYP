# SiteWise ARCore Capture — Handover Checklist & Bug Register

**Date:** 2026-11-12
**Last refreshed:** 2026-11-12
**Repository:** `C:\Users\Lenovo\AndroidStudioProjects\FYP`
**Branch:** `joel` — baseline `0bbbbaf`; the AR work described here is still
uncommitted, alongside unrelated concurrent worktree changes.
**Scope:** `fyp_mobile_app` AR 360° capture, `shared_logic` tour repository, Add Property Step 3
**Purpose:** record the completed AR work and the one remaining external validation step. Everything below is verified against the working tree, not inferred.

---

## 0. Start here: runtime prerequisites and safe recovery

### Runtime prerequisites

- The native capture host is **Android-only**. The manifest declares `CAMERA`
  and `com.google.ar.core` as `optional`, so the app may install on an
  unsupported device, but guided capture cannot run there.
- The operator needs a camera grant, an ARCore-capable Android device and an
  installed/current **Google Play services for AR**. `ArSessionService.probe()`
  distinguishes a missing Kotlin host, unsupported hardware and an absent or
  outdated AR service; do not collapse these into “unsupported device.”
- Enter the flow from Owner Add Property → Step 3 → **Start AR Capture**. The
  draft is saved first; the route is `/owner/capture` with that real property
  id.

### Resume semantics — important

ARCore world coordinates are valid only for the AR session that recorded them.
There are two deliberately different recovery paths:

| Situation | UI/action | What remains valid |
|---|---|---|
| Same live AR session, with the original world frame intact | **Resume last capture** | Saved station coordinates, anchors and records can be reused. |
| New AR session, app resume after a session restart, or invalidated world frame | **Recalibrate & continue** | Existing JPEGs and their target ids are retained; the user records a **new** station and fresh anchors. Old world coordinates are never reused. |
| App process restarted | Open the same property’s capture flow | The account-scoped `PersistentTourRepository` recovers the draft/tour id and confirmed frame count. Because this is a new AR session, continue through **Recalibrate & continue**. |

Do not implement cold-start resume by merely loading `station.json`: its
ARCore position and orientation belong to the old world frame. A durable flow
must recover the same tour and then use **Recalibrate & continue**, or add a
real persistent-world mechanism (for example Cloud Anchors/Geospatial) with a
separate design and validation plan.

---

## 1. Current implementation state

| Area | State |
|---|---|
| Native ARCore host | Ported and compiling: `fyp_mobile_app/android/app/src/main/kotlin/com/example/fyp/ar/` (`ArCoreCapturePlugin.kt`, `ArCoreSessionController.kt`, `ArGlRenderer.kt`, `YuvJpegEncoder.kt`), registered in `MainActivity.kt`, `com.google.ar:core:1.57.0` in `build.gradle.kts`, `com.google.ar.core` meta-data in `AndroidManifest.xml`. |
| Dart capture subsystem | 40-file transitive closure ported from `adaptive_360_capture_app_ar_alignment` / `feature/arcore-capture-alignment`, imports rewritten to `package:fyp/`. |
| Active screen | `lib/presentation/shared/tour/ar_capture_mobile_page.dart` is a thin host; it renders `lib/features/capture/presentation/screens/ar_capture_screen.dart` driven by `ArCoreHost` → `ArSessionService` → `CaptureController`. `CameraPoseSource` / sensor pose is no longer used by this screen. |
| Persistence | `lib/features/capture/data/repositories/sitewise_capture_repository.dart` writes station/targets/records/JPEGs under `<tourRoot>/ar_capture/<tourId>/` and mirrors them into the existing `frames.json`; stitching stays on `ServiceLocator.panoramas.generate` → `/tour-preview`. The persisted station pose is session-scoped AR metadata, not a durable world location. |
| Tour lifecycle | `PersistentTourRepository` now persists `VirtualTour` metadata in the account-scoped local `virtual_tours_v1` draft record. `ServiceLocator.tourRepo`, `TourService`, `PanoramaGenerationService` and `ArCaptureMobilePage._syncFrameCount` share that one repository, so an app restart retains the draft id and confirmed frame count. |
| Step 3 | `sitewise_add_property_mobile_page.dart` shows **AR 360° Capture**, three guidance rows, Start (save draft → `/owner/capture` with real id), conditional Resume, info line, Back/Continue. No View Tour/Retake card. |
| Recovery inside capture | `CaptureController.continueSavedStation()` uses same-frame `resumeStation()` only when ARCore reused the session; otherwise it calls `recalibrateAndContinue()` and preserves saved image records while recreating the station/anchors. |
| Plane detection | Enabled at session start (`planes: true` → `HORIZONTAL_AND_VERTICAL`); per-pose `planeCount` / `planesTracked` / `walls` / `floors` / `ceilings` reach `CaptureState.planeSummary` and the status bar. |
| 26 targets | World-anchored to a station anchor at frozen geometry via `PlaneAnchorService.placeAll`; NOT gated on detected planes. |
| Drift safety | The temporary station-drift bypass was removed. The engine always resets and blocks outside the drift limit; rotation-in-place only supplies its verified drift reference. |
| Panorama viewer | `panorama_viewer ^2.0.7` replaces the unmaintained `panorama ^0.4.1` / `motion_sensors 0.1.0` stack; both existing viewer screens use `PanoramaViewer` in its default touch mode. Its unused `dchs_motion_sensors` bridge is a local no-native-plugin override at `fyp_mobile_app/third_party/dchs_motion_sensors/`. |
| Backend tour authorization | All existing virtual-tour CRUD routes require property-owner access. The server resolves the legacy numeric id against `fyp.rental_properties`, denies another owner, lets an AAL2 admin act, and rejects unlinked rows. PATCH only accepts `url` and `status`. |

---

## 2. Bug register

### FIXED — BUG-01 `probeDirections` return-shape mismatch (silent failure)

- **Symptom:** "Scan all directions" always failed; target sheet reported `0 with a surface · 26 blocked`; status showed `Could not scan the directions: type 'Map<Object?, Object?>' is not a subtype of type 'List<dynamic>?'`.
- **Root cause:** Kotlin returns an outcome **map** `{ "results": [...] }` (`ArCoreSessionController.kt` ≈ line 630). Dart used `invokeListMethod`, which casts the Map to a List and throws every time. This defect exists in the upstream reference too.
- **Fix:** `ArCoreHost.probeDirections` (`lib/features/virtual_tour/platform/arcore_ar.dart`) now uses `invokeMethod<dynamic>`, accepts either `{results:[...]}` or a bare list, and returns an empty probe list for an empty map (never a fabricated hit).
- **Evidence:** 3 mocked-channel tests in `test/ar_capture_integration_test.dart`.

### FIXED — BUG-02 body-spin blocked by the 0.20 m station-drift gate (the amber "limited" ring)

- **Symptom:** turning the body in place while holding the phone leaves the reticle amber and capture never arms.
- **Root cause:** `VioSphereConstants.maxStationDriftM = 0.20`. `VioSphereEngine.evaluateFrame` measured `distance(camera, frozenOrigin)`; a body-spin translates the phone 0.3–0.6 m even though the station has not changed, so `isWithinStation = false`, the stability window resets, and `CaptureState.stationDriftWarningActive` paints the amber ring.
- **Fix — rotation-aware drift, not a bypass:**
  - New `lib/features/capture/domain/services/rotation_in_place.dart`. It only establishes an arc when a yaw sweep **and** a stable radius are observed in a 1.4 s window; freezes that radius once; measures the gate drift as the deviation from the arc; enforces a hard 0.75 m raw-distance cap; drops back to the raw gate on radial departure, on the cap, or after `invalidate()`.
  - `CaptureGeometryConfig` gained `rotationInPlaceRadiusM = 0.75`, `rotationRadialToleranceM = 0.10`, `minRotationYawSweepDeg = 30`.
  - `VioSphereEngine.evaluateFrame` gained `stationDriftReference`; `FrameGateEvaluation` gained `rawStationDriftM` / `rawDriftM` so the true physical distance is still reported and logged. **The frozen origin, orientation and all 26 world anchors are untouched.**
  - `CaptureController` creates the monitor at calibration, invalidates it on tracking break / clear station, and publishes `rawStationDriftM` + `rotatingInPlace` into `CaptureState`.
  - UI: status line shows `turning in place`; progress row shows both gate drift and raw drift; Step 3 guidance now says "turn your body slowly in a full circle … hold steady at each point".
  - The temporary `kStationDriftGateBypassed` switch was removed. The drift gate is now non-bypassable through the mobile capture implementation.
- **Evidence:** 7 pure-Dart tests (body-spin passes, phone-only rotation passes, walk-away blocks, hard cap blocks, radial departure blocks, tracking break invalidates, engine gates on arc but still reports raw distance).

### FIXED — BUG-03 GLB assets existed on disk but were not bundled

- `assets/models/ar_capture_target.glb` and `white_frame_bezel.glb` were present but absent from `pubspec.yaml`, so `GlbMeshSource.load()` would fail at runtime. Declared explicitly; both confirmed inside the built APK under `assets/flutter_assets/assets/models/`.

### FIXED — BUG-04 duplicate transport

- `lib/data/datasources/remote/ar_core_channel.dart` was a second wrapper over the same channels (`adaptive360/arcore`, `adaptive360/arcore/events`). Removed; `ArCoreHost` is the single typed gateway.

### FIXED — BUG-05 unused AR channel and controller code

- `setPlaneDetection`, `_anchorReplacements`, `_recoverTarget`, and related replacement-limit code were unreachable. The redundant channel/service/controller path was removed; plane detection remains enabled solely by `planes: true` at session start.
- The native stale “30 targets” comment was corrected to **26**. It was documentation-only; runtime geometry already used 26 targets.

---

## 3. Completion status and remaining external validation

| Status | Item | Completed outcome / next action |
|---|---|---|
| Complete | Device-local cold-start recovery | `PersistentTourRepository` survives a process restart and is account-scoped. It restores the same unfinished tour so saved frames remain reachable; the new AR session deliberately uses **Recalibrate & continue**. |
| Complete | Step 3 photo dead code | Removed the unreachable `_buildPhotos` flow, its image-picker dependency and its orphaned state/handlers. Backend photo APIs and shared photo models remain intact. |
| Complete | AR host cleanup | Removed the unused `setPlaneDetection` channel path and unreachable anchor-replacement/recovery code. Corrected the native 30-target comment to 26. |
| Complete | Drift-gate safety | Removed the diagnostic bypass rather than relying on a production convention. All capture paths enforce the station-drift gate. |
| Complete | Panorama viewer Gradle-plugin warning | Retained `panorama_viewer ^2.0.7` for touch drag and pinch-to-zoom. Its unused `dchs_motion_sensors` bridge is overridden by `fyp_mobile_app/third_party/dchs_motion_sensors`, which declares no native plugin. Device-motion panorama navigation is deliberately unsupported until a maintained sensor implementation is selected and device-tested. |
| Complete | Backend virtual-tour authorization | GET, POST, PATCH and DELETE now verify the canonical listing owner; test coverage includes 401, owner access, cross-owner 403, AAL2-admin access, unlinked rows, writes and prohibited reassignment. |
| External validation required | Physical-device ARCore | `adb devices` returned no attached device in this workspace. Run the checklist in §5 before calling tracking, plane detection, body-spin capture or image/stitch quality production-verified. |
| Deferred product work | Cross-device/server tour sync | The existing server `virtual_tour` schema remains intentionally narrow and does not model the mobile `VirtualTour` record or image upload. Local restart recovery is solved. Do not add a partial `HttpTourRepository`: a future cross-device design needs one owner-scoped schema/API plus media upload, status mapping and a migration plan. |

---

## 4. Verified contract map (do not re-audit from scratch)

| Call | Direction | Shape |
|---|---|---|
| `start` | Dart → Kotlin | `{width, height, planes: true}` → `{textureId, planes, anchors, cameraImage, depth, reused}` |
| pose event | Kotlin → Dart | `type: "pose"` + `planeCount`, `planesTracked`, `walls`, `floors`, `ceilings`, `activeAnchorId`, intrinsics, `trackingContinuityBroken` |
| `imageOrientation` | Kotlin → Dart | `{type, axisX, axisY}` |
| `error` | Kotlin → Dart | `{type, message}` |
| `setMesh` | Dart → Kotlin | `{id, positions, colors}` |
| `setScene` | Dart → Kotlin | `{draws: [{meshId, anchorId, localRotation, modelMatrix, scale, offsetX/Y/Z, tintRGBA, useTint, opacity, requireTracking, useModelTranslation}]}` |
| `probeDirections` | Dart → Kotlin → Dart | args `{origin, directions, maxDistanceM}` → `{results: [{hit, distanceM, planeType}]}` |
| `raycast` / `createAnchor` / `refreshAnchor` | map → map | parsed with `invokeMapMethod` |
| `takeStill` | map | `{jpeg, imageWidth, imageHeight, sourceImageWidth, sourceImageHeight, rotationAppliedDeg, ...}` |

**Calibration does not require a plane.** Only tracking, a fresh pose and a usable forward direction. A missed wall or ceiling cannot block a target.

---

## 5. Verification commands (Windows PowerShell)

Run these **serially**. Do not run a Flutter test while Gradle is building an
APK, and do not run two Flutter test/analyze commands concurrently: the native
asset/Gradle build directories are shared.

```powershell
Set-Location 'C:\Users\Lenovo\AndroidStudioProjects\FYP'

# Dependency resolution belongs to the workspace root.
flutter pub get

# Proxy variables break Flutter tooling on this machine. Remove them only from
# this PowerShell process; machine-wide settings are unchanged.
$proxyVars = 'HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy','ALL_PROXY','all_proxy'
foreach ($name in $proxyVars) {
  Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}

Set-Location '.\fyp_mobile_app'
flutter analyze
flutter test test\ar_capture_integration_test.dart
flutter test
flutter build apk --debug
```

### Historical completed verification

These are the completed results recorded when the AR implementation was
produced. They are useful evidence, but are not a substitute for a serial
rerun before handoff.

- `flutter analyze` — **0 errors**; 4 warnings + 2 infos were recorded in the original AR handoff snapshot.
- `flutter test test/ar_capture_integration_test.dart` — **22 passed**.
- Full suite `flutter test` (re-run after Gradle finished) — **95 passed / 2 skipped**.
- `flutter build apk --debug` — **succeeded** (381 s Gradle task), `build/app/outputs/flutter-apk/app-debug.apk`, 227,014,202 bytes. Both GLB models confirmed present inside the APK.
- A full-suite run attempted *concurrently* with Gradle failed on a transient transform-directory race (`build/flutter_plugin_android_lifecycle/.transforms/...`), not a code defect. Do not run tests and `flutter build apk` at the same time.

### Verification update on 2026-11-12

The focused checks were rerun serially after dependencies were resolved:

- `flutter test --no-pub test\ar_capture_integration_test.dart` — **22 passed**.
- `flutter test --no-pub test\persistent_tour_repository_test.dart` — **3 passed**.
- `flutter test --no-pub test\touch_only_panorama_sensors_test.dart` — **1 passed**; it verifies that the compatibility bridge exposes no motion data.
- Targeted `flutter analyze --no-pub` on the changed capture, persistence, Step 3, viewer and touch-only bridge files — **No issues found**.
- `backend/.venv/Scripts/python.exe -m ruff check …` — **passed**; focused virtual-tour API suite — **7 passed**. The test runner reports one upstream `starlette.testclient` deprecation warning.
- `flutter pub get` resolves `dchs_motion_sensors 2.0.2` from the local path override (`direct overridden`); the obsolete `motion_sensors 0.1.0` is absent from the lockfile. The local package contains no Flutter `plugin` declaration, so it is not registered as a native Android Gradle plugin.
- `flutter build apk --debug --no-pub` — **succeeded**. Fresh `build/app/outputs/flutter-apk/app-debug.apk`: 275,739,583 bytes (written 2026-11-12 14:43:18 MYT).

Do not infer a physical-device pass from a successful APK build.

### Device test checklist (OPEN-02 — must be done on an ARCore-capable phone)

- [ ] ARCore probe succeeds; session starts and the `Texture` shows the live camera + GLB marker.
- [ ] Status bar reports real `N planes · W walls · F floors · C ceilings` as the user looks around.
- [ ] "Scan all directions" returns `N of 26 directions have a surface` (not the old cast error).
- [ ] **Stand still and rotate the phone in the hands** → all 26 directions reachable, no amber ring.
- [ ] **Turn the whole body slowly in a full circle, holding steady at each target** → status shows `turning in place`, gate drift stays under 0.20 m, raw drift is displayed, all 26 frames capture. This is the acceptance test for BUG-02.
- [ ] Walk 1–2 m away → amber ring returns and capture is refused (safety gate intact).
- [ ] Walk back → gate recovers after the 500 ms hysteresis.
- [ ] Cover the camera / move too fast → tracking break invalidates the arc; recalibration is required.
- [ ] Complete 26 frames → `frames.json` has 26 entries with real JPEGs, OpenCV stitching succeeds, `/tour-preview` opens.
- [ ] Leave mid-capture and return → Resume button appears only when the draft holds frames; saved frames are not lost.
- [ ] Confirm parallax/stitch quality for the body-spin technique; if unacceptable, reduce `rotationInPlaceRadiusM` (currently 0.75 m) rather than disabling the gate.

---

## 6. Constraints / non-negotiables for the next agent

1. Do **not** replace the original production `PU_model.joblib`, the recommender, or any ML scoring.
2. Do **not** reintroduce `CameraPoseSource` or a second Flutter `camera` session — ARCore owns the camera device.
3. Do **not** fabricate poses, frames, plane counts or SHAP values; `0` means measured zero, `null` means not recorded.
4. Do **not** insert experimental/unversioned scores into legacy columns.
5. Do **not** commit or push; do not reset branches or overwrite concurrent edits. Check `git status --short` before every edit — other sessions are active in this repo.
6. Do not reintroduce a station-drift bypass. The raw gate and verified rotation reference are part of the capture safety contract.
7. No destructive DB operations, migrations or `create_all` without explicit approval.
8. Report physical-device behaviour as **unverified** until tested on real hardware.

---

## 7. Key file index

| Path | Role |
|---|---|
| `fyp_mobile_app/lib/features/capture/domain/services/rotation_in_place.dart` | NEW — body-spin detector |
| `fyp_mobile_app/lib/core/math/vio_sphere_math.dart` | `stationDriftReference`, `rawStationDriftM`, non-bypassable station gate |
| `fyp_mobile_app/lib/features/capture/domain/services/target_sphere.dart` | `CaptureGeometryConfig` rotation fields |
| `fyp_mobile_app/lib/features/capture/application/capture_controller.dart` | monitor wiring, gate call |
| `fyp_mobile_app/lib/features/capture/application/capture_state.dart` | `rawStationDriftM`, `rotatingInPlace` |
| `fyp_mobile_app/lib/features/virtual_tour/platform/arcore_ar.dart` | FIXED `probeDirections` |
| `fyp_mobile_app/lib/features/capture/data/repositories/sitewise_capture_repository.dart` | tour-scoped frame store |
| `fyp_mobile_app/lib/features/capture/data/services/ar_session_service.dart` | Android/ARCore capability, install and session boundary |
| `fyp_mobile_app/lib/features/capture/domain/models/capture_station.dart` | explicit AR-world/session validity contract |
| `fyp_mobile_app/lib/presentation/shared/tour/ar_capture_mobile_page.dart` | AR capture host + stitcher hand-off |
| `fyp_mobile_app/lib/presentation/mobile/entrepreneur/pages/sitewise_add_property_mobile_page.dart` | Step 3 UI, Start/Resume |
| `fyp_mobile_app/test/ar_capture_integration_test.dart` | 22 automated tests |
| `shared_logic/lib/src/domain/repositories/admin_repositories.dart` + impl + `tour_service.dart` | `tourForPropertyDraft` |
| `fyp_mobile_app/lib/data/repositories/persistent_tour_repository.dart` | account-scoped device persistence for tour metadata |
| `fyp_mobile_app/lib/application/services/service_locator.dart` | single shared persistent tour repository wiring |
| `fyp_mobile_app/third_party/dchs_motion_sensors/` | local touch-only compatibility layer; no native plugin |
| `fyp_mobile_app/test/touch_only_panorama_sensors_test.dart` | regression test for the inactive sensor bridge |
| `backend/src/sitewise/db/models/virtual_tour.py` | existing narrow backend schema; timezone-aware defaults |
| `backend/src/sitewise/api/v1/virtual_tours.py` | owner-scoped CRUD and PATCH allow-list |
| `backend/tests/api/test_virtual_tours_authorization.py` | virtual-tour owner isolation API coverage |
| `fyp_mobile_app/pubspec.yaml` | `permission_handler`, GLB assets, `panorama_viewer` |
| `fyp_mobile_app/android/app/src/main/AndroidManifest.xml` | camera permission and optional ARCore declaration |
| `.workbuddy-ai/memory/2026-11-12.md` | chronological work log |

---

## 8. Update log

- **2026-11-12 — completion pass:** added account-scoped local tour persistence
  for process-restart recovery; protected all existing virtual-tour CRUD routes
  with owner checks; removed the unused photo/anchor/plane-detection paths and
  the station-drift bypass; migrated the panorama viewer dependency; corrected
  the 26-target documentation; and reran the focused automated checks.
- **2026-11-12 — Android compatibility pass:** replaced the panorama viewer's
  unused transitive native sensor bridge with a local touch-only compatibility
  layer, added a regression test, and rebuilt the debug APK. Touch drag and
  pinch-to-zoom remain supported; device-motion panorama navigation is not.
