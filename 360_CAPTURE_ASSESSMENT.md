# 360° Capture Module — Requirements Assessment

Date: 2026-10-11
Scope: `fyp_mobile_app` 360° panorama capture module vs the 7-subsystem brief
Method: read every capture file, checked the actual dependency graph, ran greps
for each required capability. Nothing below is inferred from file names.

---

## Headline

| Measure | Score |
|---|---|
| **Overall compliance with the brief** | **≈ 65 %** |
| Core capture workflow (the hard part) | **≈ 85 %** |
| Cloud/production requirements (Supabase + Render + QA) | **≈ 25 %** |

The module is **much further along than the HTML prototype it came from**, and the
hardest parts — the 26-point rig, the session state machine, and the quaternion
alignment maths — are genuinely done and unit-tested. What is missing is mostly
the *production* half: exposure locking, blur QA, and the backend stitching
service.

---

## What is actually implemented

### ✅ The 26-point capture rig — complete
`shared_logic/lib/src/data/datasources/local/capture_target_data_source.dart`

The exact matrix the brief calls industry-standard, with **8 upper + 8 middle +
8 lower + 1 zenith + 1 nadir = 26**:

| Band | Pitch | Yaw values | Frames |
|---|---|---|---|
| Zenith | +90° | — | 1 |
| Upper | +45° | 0, 45, 90, 135, 180, 225, 270, 315 | 2–9 |
| Middle | 0° | 0, 45, 90, 135, 180, 225, 270, 315 | 10–17 |
| Lower | −45° | 0, 45, 90, 135, 180, 225, 270, 315 | 18–25 |
| Nadir | −90° | — | 26 |

Each point carries more than the prototype did: per-axis tolerances
(`pitchTolerance` 12–15°, `yawTolerance` 15°, poles 360°), `previousFrame` /
`nextFrame` links, `expectedYawDelta` / `expectedPitchDelta`, and
**`overlapNeighbors`** — stitching metadata the prototype did not have.

### ✅ Capture session state machine — complete, and better than the prototype
`fyp_mobile_app/lib/application/services/panorama_capture_service.dart` (306 lines)

A 10-state machine: `initializing → trackingReady → settingOrigin → guiding →
stabilizing → capturing → processing → preview → completed | error`.

Real invariants enforced in code, not just UI:
- tracking warm-up (5 consecutive pose polls before origin is taken)
- origin drift monitoring — >0.5 m from origin blocks alignment
- stability gate — alignment must hold continuously for 800 ms
- **never advances without a confirmed image**; duplicate frames rejected
- failed capture stays on the same target for retry
- `reopenFrame()` for retakes; later frames kept (same origin, still valid)
- `restoreFrames()` / `prepareResume()` for resuming an interrupted session
- `stabilityFraction()` drives the UI progress bar

### ✅ Quaternion alignment maths — complete, gimbal-lock aware
`fyp_mobile_app/lib/core/utils/ar_math.dart`

This directly answers the brief's §C concern:

```dart
final localDir = cameraRotation.conjugated().rotated(toTarget);
```

Uses the **quaternion conjugate** rather than Euler angles, so it does not suffer
gimbal lock at the zenith/nadir — the exact failure mode the brief warns about.
`wrapAngleDeg` and `angleDifferenceDeg` handle the 355°→0° case correctly (a
target at 0° seen from 355° reports +5°, not −355°). There is even a guard for a
zero-length direction so it returns `(0, 0, not aligned)` instead of NaN.

### ✅ Real image capture, not a simulation
`fyp_mobile_app/lib/application/services/ar_capture_service.dart`

The prototype's `onpointermove` drag simulation has been replaced with **real
ARCore** via `ar_flutter_plugin`:
- `getCameraPose()` — real device pose from the AR session
- `snapshot()` — real camera frame, decoded to PNG bytes
- 26 reticle nodes placed in AR space via `sphericalToVector()`

### ✅ Real frame persistence
`fyp_mobile_app/lib/data/datasources/local/capture_frame_store.dart`

`<appDocs>/sitewise/tours/<tourId>/frames/frame_<NN>.png` via `path_provider`.

### ✅ Real stitching (but on-device)
`fyp_mobile_app/lib/data/datasources/local/opencv_panorama_stitcher.dart`

`cv.Stitcher.create(mode: PANORAMA)` → `stitchAsync()` → writes `panorama.jpg`.
Honest failure reporting — every failure names the failing stage and preserves
the source frames. `panorama_generation_service.dart` validates the 26-frame
sequence (rejects <26, rejects duplicate indices) before delegating.

### ✅ Tests — 17 tests over the pure logic
`fyp_mobile_app/test/panorama_capture_test.dart` (360 lines)

Covers the rig (unique indexes 1..26, zenith above / nadir below, pole yaw
tolerance), angle wrapping, alignment, the full 26-frame sequence, stability,
duplicate rejection, retake, origin drift, resume, and generation validation.
The test names even reference `(bug #1)` / `(bug #2)` — previously-found bugs now
locked down.

---

## Subsystem scorecard

| # | Subsystem (brief) | Required | Actual | Score |
|---|---|---|---|---|
| A | Camera + **AE/AWB lock** | `camerawesome`, exposure locked across all 26 | ARCore snapshot works, but **zero exposure/WB control** | **60 %** |
| B | Orientation / tracking | `motion_sensors` Rotation Vector | ARCore world tracking (the brief's own §C alternative) | **90 %** |
| C | Alignment & target guidance | Quaternion maths, gimbal-lock safe | Fully implemented | **100 %** |
| D | Motion stability | Gyro angular-velocity delta, 1.3 s | Time-based alignment hold, 800 ms — no raw gyro | **60 %** |
| E | Image quality validation | OpenCV Laplacian variance blur check | **Absent** | **0 %** |
| F | Coverage / adaptive guidance | Room-size-driven multi-station | **Absent** | **0 %** |
| G | Panorama stitching | Python FastAPI + Supabase backend | Real OpenCV Stitcher, but **on-device** | **55 %** |
| H | Tour rendering | `panorama_viewer` + hotspots | `package:panorama` viewer works; **no hotspots** | **50 %** |
| — | 26-point rig definition | 8+8+8+1+1 matrix | Complete, with extra stitching metadata | **100 %** |
| — | Session state machine | init/align/cap/done/fail | 10-state, well-tested | **100 %** |

### Weighted total

| Item | Weight | Score | Contribution |
|---|---|---|---|
| 26-point rig | 5 % | 100 % | 5.0 |
| Session FSM + sequence integrity | 15 % | 100 % | 15.0 |
| Alignment / guidance maths | 15 % | 100 % | 15.0 |
| Camera capture | 10 % | 60 % | 6.0 |
| Motion stability | 10 % | 60 % | 6.0 |
| Frame persistence | 5 % | 100 % | 5.0 |
| Image quality QA | 10 % | 0 % | 0.0 |
| Panorama stitching | 15 % | 55 % | 8.25 |
| Tour rendering | 10 % | 50 % | 5.0 |
| Multi-station coverage | 5 % | 0 % | 0.0 |
| **Total** | **100 %** | | **≈ 65 %** |

---

## Critical gaps, in priority order

### 1. No AE/AWB lock — this will break stitching in practice (highest risk)
The brief is explicit: *"If image 1 is pointing at a dark corner and image 2 at a
bright window, the exposure difference will make stitching impossible."*

`grep -rniE "exposure|whitebalance|awb|focuslock" lib/` → **no matches**. ARCore
(`ar_flutter_plugin`) exposes no exposure or white-balance API, so this cannot be
fixed inside the current camera stack. It needs `camerawesome`, which binds to
the Android Camera2 `CONTROL_AE_LOCK` / `CONTROL_AWB_LOCK` controls.

**This is the single highest-value change available**, because without it the
stitcher will fail on real rooms even though all the surrounding logic is correct.

### 2. On-device stitching will likely OOM
The brief warns mobile processors lack RAM for 26 high-resolution images. The
current implementation stitches **on-device** with `opencv_dart`. The pipeline
may work on a handful of frames but is expected to fail on a real 26-frame set at
camera resolution. Needs the backend service (or aggressive downscaling, which
trades away output quality).

### 3. No blur detection
Subsystem E is entirely absent. A blurry frame poisons the whole panorama because
SIFT/ORB cannot find keypoints in it — and the user only finds out at the end,
after 26 captures. The Laplacian-variance check (`opencv_dart` is already a
dependency) would catch it at capture time. **Cheap to add, high value.**

### 4. No multi-station support
The brief's §F and the prototype's "Small/Medium/Large" station planning did not
survive the port. Large or L-shaped rooms currently produce one panorama that
cannot cover them.

### 5. No hotspots
`grep -rni "hotspot"` → no matches. Multi-station tours cannot be navigated
between, so even with stations added there is no way to link them.

### 6. Stability is time-based, not motion-based
The brief specifies a gyro angular-velocity delta with a 1.3 s threshold; the
implementation uses an 800 ms alignment-hold timer. It works and is arguably
simpler, but it cannot distinguish "holding still" from "moving slowly while
staying on target" — which is exactly what causes motion blur.

---

## Dependency reality check

| Package | Brief | In pubspec | Imported |
|---|---|---|---|
| `camerawesome` | ✅ required | ❌ | ❌ |
| `camera` | alternative | ❌ | ❌ |
| `motion_sensors` | ✅ required | ❌ | ❌ |
| `sensors_plus` | ✅ required | ❌ | ❌ |
| `opencv_dart` | ✅ required | ✅ | ✅ (stitching only) |
| `panorama` / `panorama_viewer` | ✅ required | ✅ `panorama` | ✅ (2 files) |
| `ar_flutter_plugin` | alternative | ✅ | ✅ (3 files) |
| `supabase_flutter` | ✅ required | ❌ | ❌ |
| `webview_flutter` | optional | ❌ | ❌ |

Note `opencv_dart` is present and working — so the blur check (subsystem E) is
genuinely a small addition, not new infrastructure.

---

## Honest summary

**≈ 65 % of the brief**, and the 65 % that exists is the *right* 65 % — the
capture rig, the state machine, and the alignment maths are the parts that are
hard to get right and hard to retrofit. The remaining 35 % is mostly
well-understood, well-scoped work: swap the camera package, add a blur check,
move stitching to a backend, add stations and hotspots.

One caveat worth stating plainly: **I could not run any of this.** `flutter test`
and `flutter analyze` are blocked on this machine (Windows pipe pool), and
`dart compile js` cannot reach project files through the Flutter SDK. The 17
tests exist and read correctly, but I did not execute them — the scores above
reflect what the code *contains*, verified by reading it, not observed runtime
behaviour. In particular, whether ARCore's snapshot actually produces
stitchable frames with no exposure lock is an empirical question that only a
device can answer.
