# FYP — long-term notes (condensed 2026-11-23)

**PROJECT1 deliverables → `deliverables/`** (not repo root).

## Build/run
- Build only from `fyp_jaspr_web`: `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy dart run jaspr_cli:jaspr build`; stop servers first (deletes `build/jaspr`). Stale build_runner: kill `dart.exe`, delete `.dart_tool/build/asset_graph.json`. Auth-bridge: `cd tool && npm run build-auth`.
- SPA client-rendered; serve `PORT=8090 node tool/dev_static_server.js` as its own background task (`node … &` dies with the shell). Probes: chromium `C:/Users/HP/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe`, `--no-proxy-server`, playwright-core from `fyp_jaspr_web/tool/node_modules`.
- Ports 8090 web / 8000 API / 5567 proxy / 8181 VM / 5432 PG. `FYP/test` (3001) legacy. Never create `serve.ps1` (AllSigned); use `.\serve`.

## Hard rules
- Never direct pytest (guard refuses): `tools/p2_isolated_test_runner_20261122.py --db project1_disposable_app`; JUnit = runner inline + `--junitxml`.
- Authenticated `/auth/me` on :8090 writes `public.users` in the protected DB — verify DB identity before the first request.
- 18 Supabase auth users: never modify existing ones; signup 200 w/o token; admin-confirm + password grant; DELETE fails FK → ban. `full_name: ""` breaks `??` fallbacks.
- Explanation registry is generated (`backend/scripts/build_explanation_registry.py`) into `deliverables/` + `src/sitewise/project1/data/`; never hand-edit; update `EXPECTED_REGISTRY_SHA256` pin on regeneration. Chart `percentage` is a JSON string; bars gated on `RENDERABLE` (A10 adapter missing).
- Concurrent sessions edit this repo live: `git status` + re-read files immediately before every Edit.

## Data & tests
- 955 U-rows = `fyp.rental_properties` 955 (`owner_id IS NULL`) + 227 owner listings (never touch). `suitability_score` is an uncalibrated ×100 index, not a probability. `expanded64` (64 feats) vs legacy 47 — never mix; macro-F1 ~0.29 vs 0.25 chance → phrase as "match to business type".
- Baseline commit `33f2005`: 25 pre-existing failures / 1280 pass / 3 skip; compare node-id sets, never counts. Dart 120 pass / 1 LOAD_ERROR from an uncommitted artifact.

## Adaptive routing (evidence `New_Goal/artifacts/adaptive_routing_v15/`)
- FC2/FC3 DB integration BLOCKED, scientific HOLD, NO-GO; no DDL. Dss CQ tables empty; Dss_test lacks CQ tables (migration blocked on missing `users`, `m2_assessments`, `refresh_m2_workflow(uuid)`, `m2_workflow_cq_change()` md5 `24c80efe…`). Order `20261113_01` → `16_01..04`.
- `p1_ee01_runtime` (`EE01_DATABASE_URL`) read-only needs per-session `default_transaction_read_only=on`.
- Q01 NEVER/NOT_SURE `can_submit=true` = CUST03 routing exhaustion, not scientific completion. V2 geo JSON is UNTRACKED / not in manifest / fielding off; activation gated.
- FC4-A 87/87, FC4 V1.1 169/169 PASS and reproducible; engineering PASS, scientific HOLD, NO-GO; no codebook change.
- FC4-D (`artifacts/cq_fc4d_50_real_service_replay_v1/`): staging in schema `synthetic_lab`; SQL readback is release-scoped, digest is not (compare values, not totals). 35/35 SQL + 1762/1762 digest, 0 routing mismatches; report 403 is PASS. New fixtures need their own release tag.
- Mobile: `assets/config/sitewise_dev.json` overrides `--dart-define`; bypass needs kDebugMode + asset edit + loopback `CQ_TEST_BASE` port >1023 not in {3080,5432,8000,8090}; `adb reverse tcp:18090 tcp:18090`; UI text in `content-desc`; unlock before launch.

## 360 capture plan (2026-11-27, joel uncommitted)
- **Current plan is version 11 = exactly 44 targets** (`sphere_plan_v11.dart` / `plan_v11.py`), restoring plan 4's adaptive five-ring layout with repositioned caps: 12/12/12 at pitch 0/±30 (upper+lower staggered +15°) plus 4 ceiling @ +60° yaw 0/90/180/270 and 4 floor @ −60° yaw 30/120/210/300. Every cap sits *between* two ring targets, never above one.
- **Cap pitch is 60°, not 62°**: the binding transition is the cap→upper *exit*, which projects to 1.012 of the half-frame at 62° (outside), 0.976 at 61° (0.8° margin, inside the 2° cone) and 0.938 at 60°. Plan 4's +65° aligned caps were the mechanical cause of 0/4 ceiling registration.
- **4 of 43 transitions cannot be visible** and are provable, not a bug: edge count demands `e(M-U)+e(M-L)=24` but 4+4 caps consume 8 upper + 8 lower slots, so 4 upper→lower steps (66.5° apart) fall outside. Exempt ids `{11,22,33,44}` are computed by the plan (`previousVisibilityExempt`) and read by `_previousTargetInFrame`; never hard-code them in the gate. Worst visible transition 0.9382 (2.0° margin), coverage 100% single / 97.4% double.
- Plans 4 (44), 5 (48), 7 (80), 8 (126), 9 (48) and 10 (48) stay readable; 44 is claimed by 4 and 11, so the version must come from the session. `sitewisePlanVersionForCount(44)` → 11, `planVersionMatchesCount(4, 44)` stays true.
- Visibility rule is geometric: `x = tan(Δyaw)/cos(Δpitch)/tan(hH)` with `tan(hH)=0.4774 < tan(hV)=0.6371` (portrait 3072×4096, 65° vFOV). Max safe yaw step 25.5°, pitch 32.5°; the shutter also projects the previous target instead of trusting the cone.
- `_pole_frames(frame_records, plan_version)` in `stitcher.py` derives poles from recorded pitch (≥80°), never from an id set; oblique-only versions {4,5,6,7,8,9,10,11} get no pole ids at all.
- `flutter test` and `dart run` are **blocked by the sandbox** (they shell out to `reg.exe`); only `flutter analyze` runs. Geometry parity is therefore checked by `backend/scripts/validate_capture_plan_44.py` plus a text diff of the Dart and Python tables.

## Report surfaces
- `AssessmentReportView` 9 sections, no route; production mount `assessment_workspace_page.dart:3953`, browser test via `/dev/report`. `/entrepreneur/report?id=` is a different report. `.asw-rpt` CSS source: `artifacts/stage34_integration_20261119/isolated_build_workspace/…/styles.css`.
- RP-13 BLOCKED (no revisions/snapshots; the only confirmed BCB belongs to another assessment — never join).
- RI-V2 (`artifacts/cq_fc4d_report_integration_v2/`): RP-02 20 charts / 8 principled refusals; RP-04 third param `measurementChart` separate from `chartSpec`/`q01Preview`; provenance label = `metadata_json.routing_version`, not contract `spec_version`.

## Location Intelligence (informational measurements)
- Valid lat/long is the ONLY precondition to queue measurements. The address verdict is reported (`address_validation_status`) but never a gate — requiring it left all 944 catalogue properties (verdict NULL) permanently unmeasured.
- `informational_measurements()` is the measurement-only projection (no score/SHAP). Model eligibility lives in `VALIDATED_COORDINATE_INPUTS*`; the 18 diagnostic features are measured and shown as `calculated_unvalidated`, never scored.
- `enqueue()`'s in-flight guard is scoped to the categories being queued, not all of them.
- `network` category needs `STATEMENT_TIMEOUTS['network']=180s` (pgRouting reach + hull + WorldPop overlay); everything else 25s. `Connection.exec_driver_sql` needs positional `%s`, not `:named`.
- Entry points: `scripts/backfill_location_intelligence.py` (enqueue all), `scripts/drain_location_intelligence.py` (parallel drain). `GET /explore/analysis` returns `data.location_measurements`.


## Agent dashboard integration (Task E, 20261127, joel uncommitted)
`GET /staff/me/listings` now returns enriched rows + `counts`: repo `_LIST_SELECT`
carries all assignment workflow cols; `staff.py` `_enrich_agent_rows` reuses
`agent_submission_readiness` (it also returns `ownership_submission_status` now);
`_next_agent_action` → (action, owner∈agent|owner|admin|system); `_agent_counts`
rules: declined ≠ active, drafts count only when workflow accepted, approved ≠
published. Flutter: `ProviderListing` workflow fields + `buildAgentTasks`
workflow-first with `responsibility`; overview metrics New Requests/Inspections
in Progress/Pending Admin Review/Published; mutations bump `listingsRevision`
(inspectCommand/saveInspection/details sheet/proof upload/panorama confirm).
