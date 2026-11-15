# FYP — Long-term project notes

## Brand assets
- Icon = rounded-square isometric tile (`tool/_src/sitewise_icon_source.jpg`); regen `tool/make_app_icon.py`. No glyph/inline-SVG logos. Web marks `assets/sitewise-mark-64.png`; signup hero photo `assets/signup-city.jpg`.

## Build / verify (fyp_jaspr_web)
- Build ONLY from `fyp_jaspr_web`: `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy dart run jaspr_cli:jaspr build` (proxy → daemon 502). Deletes `build/jaspr` — stop servers first. Auth-bridge edits: `cd tool && npm run build-auth` first.
- Client-rendered SPA; deep routes via `lib/app.dart` redirect. Serve `PORT=8090 node tool/dev_static_server.js`.
- Probes: NODE_PATH=C:/Users/Lenovo/.workbuddy-ai/binaries/node/workspace/node_modules; chromium `--no-proxy-server`; `tool/session_harness.js` = stand-in auth bridge + catalogue fixture for headless role routes.
- Stale build_runner blocks build: kill dart.exe + `rm .dart_tool/build/asset_graph.json`. ENOSPC: clear `.dart_tool/build` + `__pycache__` (~800 MB).

## Framework gotchas
- Never root a 3rd-party widget on a framework-owned element (Jaspr rewrites `class`; Leaflet mounts on `.swcx-map-mount` child).
- Component asset refs MUST be root-absolute `/assets/...` (no `<base href>`); CSS `url('assets/…')` ok.
- `main_()` renders `<main>`. Read whole CSS rule before editing. Can't view images — verify via headless DOM checks (naturalWidth, class/rect audits).

## Services
- Backend `FYP/backend` FastAPI port 8000 (`sitewise.main:app`); `FYP/test` (3001) is legacy, NEVER the API. Ports: 8090 web / 8000 API / 5567 dev proxy / 8181 VM / 5432 PG.
- `.\serve` → serve.cmd → serve.impl.ps1; NEVER create `serve.ps1` (AllSigned rejects unsigned .ps1).
- Supabase: admin create-user P0001 + signup SMTP 500 are live blockers, not integration faults; only 1 real auth user — never modify.

## Mobile (fyp_mobile_app)
- Auth screen: no back arrow, no top login/signup toggle (user request); mode via `/auth` args + inline link. `flutter test`: unset proxy envs. `dart analyze` clean (one pre-existing unused import).

## Role themes (2026-11-09)
- Shell classes: `app-shell--admin`, `app-shell--agent` (light #E8EEF6/#FFF/#E2E8F0/#1D4ED8/#0D9488), else shared dark. Append scoped tokens at END of styles.css; never retheme `:root`.
- Concurrent sessions edit repo live — `git status` + re-read files immediately before every Edit.

## Catalogue (2026-11-10)
- `sitewise_app.properties` = 955 U-class rows; `fyp.rental_properties` = same 955 (`owner_id IS NULL`) + 227 owner listings (never touch). Photos 5,979 URLs. `suitability_score` = uncalibrated P-vs-U index ×100, not a probability.

## Category-aware Stage 2 (2026-11-15)
- Artifact `sitewise_fnb_category_v2.joblib` (54 feats, research_only); contract `ml/category_aware.py`, orchestration `ml/fnb_category.py`; v1 preserved.
- `SITEWISE_PU_MODEL_VARIANT` default `expanded64` (896/955 resolve, 351 pass >50); legacy = 47 feats — never mix 47- and 64-feature scores.
- Selected business type drives Stage-2 SHAP target + rank tie-break. Insights cache keyed version+sha+feature-digest+type. `import shap` slow → lifespan warm-up thread in main.py.
- Model weak (macro-F1 ~0.29 vs 0.25 chance) ⇒ wording: "how well this location matches your selected business type". Verify: `backend/scripts/ml/verify_category_aware_integration.py`.
