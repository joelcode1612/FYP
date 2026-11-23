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

## Report surfaces
- `AssessmentReportView` 9 sections, no route; production mount `assessment_workspace_page.dart:3953`, browser test via `/dev/report`. `/entrepreneur/report?id=` is a different report. `.asw-rpt` CSS source: `artifacts/stage34_integration_20261119/isolated_build_workspace/…/styles.css`.
- RP-13 BLOCKED (no revisions/snapshots; the only confirmed BCB belongs to another assessment — never join).
- RI-V2 (`artifacts/cq_fc4d_report_integration_v2/`): RP-02 20 charts / 8 principled refusals; RP-04 third param `measurementChart` separate from `chartSpec`/`q01Preview`; provenance label = `metadata_json.routing_version`, not contract `spec_version`.
