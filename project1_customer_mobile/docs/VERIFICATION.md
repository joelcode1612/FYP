# Delivery verification — 8 November 2026 (Asia/Kuala_Lumpur)

This records engineering checks for the synthetic UI prototype. It grants no scientific, ethical, translation, Owner or fielding approval.

## Workspace and isolation

- Verified the requested owning workspace before editing: `C:\Users\HP\OneDrive\Desktop\sport-marketplace\FYP`.
- Observed branch: `codex/cust03-backend-candidate-20261107`.
- Added `project1_customer_mobile/` as a standalone package. No hand edits were made to the existing Sitewise app, shared logic, backend, root workspace configuration or frozen questionnaire contract. The existing changed/untracked-file list was retained; the new project folder is the addition.
- Question IDs and all 13 option-code sets match the bundled documentary source excerpt in an automated test. Source contract SHA-256: `ec2b5494ecf82447076e0d7a2bfb57599a24f049bbcc925a9ecbea6e833bce59`.

## Completed checks

| Check | Result and scope |
| --- | --- |
| Flutter toolchain | Flutter 3.44.6 stable, Dart 3.12.2, Windows; flutter_riverpod 3.5.0 resolved in the lockfile |
| Static analysis | PASS, no issues (`artifacts/analysis-results.txt`) |
| Unit + widget tests in owning workspace | PASS, 41 tests (`artifacts/test-results.txt`) |
| Small-screen rendering | EN/BM welcome, Q05, review and matrix at 320×568 with 200% text; no overflow in the passing suite |
| Screenshot inspection | Welcome, Q05 selected-option treatment and route-aware review rendered at 390×844; PNGs in `artifacts/` |
| Android debug compilation | PASS; first build took 777.1 seconds on this host. No OpenCV or Sitewise native modules are dependencies of this package |
| Web release compilation | PASS, including Wasm dry run; 178.2 seconds (`artifacts/web-build-results.txt`) |
| Standalone dependency resolution | PASS, offline from a separate copy outside the monorepo |
| Tests in standalone copy | PASS, all 41 tests again; the 11 application source files were SHA-256 matched against the owning workspace (`artifacts/clean-package-test-results.txt`) |
| Native Android walkthrough | PASS, 1 integration test on emulator-5554 / Android API 36. Test APK compiled in 606.7 seconds, installed in 7.1 seconds, and the test run finished in 54 seconds (`artifacts/android-integration-results.txt`) |
| Native renderer inspection | PASS for the captured review screen (`artifacts/android_emulator.png`): 12 shown, 9 answered, 3 optional skipped. The pink cross is the test harness's touch marker |

Web build emitted an expected-font warning mentioning `packages/cupertino_icons/CupertinoIcons`. The custom UI uses Material icons, which were bundled and tree-shaken successfully. Browser runtime behavior and iOS fallback icons were not established by that build. This warning was not hidden or treated as a build failure.

## Test coverage

The 31 state/model tests cover consent and submission guards, unknown-code rejection, all 512 Q01 subset selection sequences, affiliation/terminal exclusivity, three short-screen routes, all four positive purchase bands and three non-positive/unknown/refusal bands, missing stimuli, disabled modules, Q02's non-use as an extra threshold, Q06 maximum selections, partial Q10 matrices, independent per-feature ratings, optional skips, actual shown/answered counts, hidden-answer clearing, route expansion after review, language/state preservation, welcome/resume, reset and immutable collections. The 10 widget tests cover working controls, route-aware screenshots and the eight small-screen/language/page combinations.

The additional native integration test taps the consent, question options, language controls and all three matrix dropdowns; skips Q11–Q13; verifies the 9-answered/12-shown review; edits Q01 to produce a two-question route; verifies 2 answered/2 shown; and submits to the local-only confirmation. It uses the actual Android renderer and a fresh Riverpod session, not a mocked backend.

Progress counts resolved route items (answers plus optional skips), not 13 mandatory completions. Refusal and uncertainty selections count as response events; they do not become substantive valid responses or demand estimates. No analysis denominator, report graph, composite importance score, business-suitability score or research conclusion is produced.

## Remaining boundaries

- Scientific acceptance, Owner adoption, authorized stimuli and feature banks, bilingual respondent pretests and live backend integration remain outside this delivery.
- All routing is MOCK-UI-1. Synthetic-fixture switches cannot authorize real respondent use.
- iOS has project scaffolding only; no macOS/Xcode build or physical-device test was performed.
- Visual resemblance is an adaptation, not a pixel-for-pixel reproduction. Longer correct wording and refusal/uncertainty choices require scrolling.
- Closing the app process/resetting clears the session. No upload or persistent save is implemented.

## Packaging

The delivery script excludes build folders, local SDK paths, IDE state, ephemeral platform files and caches. The ZIP is integrity-tested and every archived file is checked against its source SHA-256. The separate package manifest records those hashes. Platform files needed to rebuild, the dependency lockfile, README, tests, reference image, licences and rendered evidence are included.

A clean-copy test attempt on C: initially stopped because the disk filled while copying Flutter compiler output. Generated build files from this task were cleared with Flutter's own clean command, and verification was relocated to a temporary D: copy. All 41 tests passed in that standalone copy. The original C: attempt was a host resource failure and was not counted as a pass.
