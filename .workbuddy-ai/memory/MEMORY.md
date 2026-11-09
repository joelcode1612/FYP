# FYP — Long-term project notes

## Brand assets (since 2026-10-26)

- The app icon is the user-uploaded rounded-square isometric map tile. Source of
  truth: `fyp_jaspr_web/tool/_src/sitewise_icon_source.jpg`; regeneration script:
  `fyp_jaspr_web/tool/make_app_icon.py` (emits web `sitewise-icon*`/`sitewise-mark-64`
  + Android/iOS/macOS launcher icons). Do NOT reintroduce glyph/inline-SVG logos.
- Web brand marks reference `assets/sitewise-mark-64.png` (floating rounded tile):
  `lib/components/ui.dart` (Brand), `landing_page.dart` nav, `auth_icons.dart`,
  `signup_page._brandMark`. Favicon/touch icon: `sitewise-icon-32.png` /
  `sitewise-icon-180.png` in `main.server.dart`. Mobile launchers use the square
  master (`square_master` fills outside-of-squircle corners via cv2.inpaint).
- Signup hero uses the photographic backdrop `assets/signup-city.jpg`
  (cleaned by `tool/extract_signup_bg.py`), rendered as `<img class="su-hero__art">`,
  NOT an inline SVG.

## Build / verify workflow

- Build: `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy dart run
  jaspr_cli:jaspr build` in `fyp_jaspr_web` (proxy intercepts the build daemon's
  websocket -> 502). `jaspr build` deletes `build/jaspr` — stop any server serving it first.
- **Auth bridge change**: after editing `tool/auth_client.js`, rebuild the bundle
  FIRST with `cd fyp_jaspr_web/tool && npm run build-auth` (esbuild ->
  `web/auth_bundle.js`); otherwise the old bundle ships. Then `jaspr build`
  copies `web/` into `build/jaspr`.
- Verify (2026-11-09 CORRECTION — the app is now CLIENT-rendered): pubspec has
  `jaspr: mode: client` (since commit "joel9"), so `jaspr build` emits static
  files and NO `build/jaspr/app.exe`. Deep routes resolve client-side
  (`lib/app.dart` Router.redirect: anonymous /agent -> /login?next=…); the
  old SSR guidance (app.exe, mode: server) is obsolete. To verify the build,
  serve it with SPA fallback: `PORT=8090 node tool/dev_static_server.js`,
  then run probes with
  NODE_PATH=C:/Users/Lenovo/.workbuddy-ai/binaries/node/workspace/node_modules
  (playwright-core lives in the managed node workspace, NOT fyp_jaspr_web/
  node_modules which only has esbuild). Launch chromium with
  `args: ['--no-proxy-server']` or page.goto to 127.0.0.1 times out (proxy
  intercepts loopback). Playwright chromium at
  `C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/...`.
- Verification probes (BASE=http://127.0.0.1:8090):
  `tool/probe_backend_integration.js` (43 checks: same-origin proxy, no
  :8000/:3001 browser calls, PKCE redirect, callback hydration),
  `tool/probe_ssr_mpa.js` (27 SSR/MPA checks), `tool/probe_social_final.js`,
  `tool/probe_staff.js`, `tool/probe_auth_flows.js`, `tool/probe_login.js`.
  `probe_login.js` click waits can flake on the entrance animation — use a
  forced click. `probe_auth_e2e.js` needs a creatable Supabase test identity.

## Gotchas

- `<base href="/">` in built HTML: asset refs in Dart must be root-relative
  (`assets/...`), not `../assets`.
- `main_()` is used for the `<main>` element (`main` is a Dart reserved word).
- Read an entire CSS rule before editing — some rules (`.brand-icon`) have
  properties continuing past what a grep -A8 snippet shows.
- The model in this environment cannot view images; verify visual work with
  numeric pixel probes or headless-browser DOM checks (`naturalWidth`, class audits).
- **`jaspr build` / `dart pub get` MUST run from `fyp_jaspr_web`, never the
  workspace root (`FYP`).** The shell's persistent CWD defaults to `FYP`; running
  `jaspr build` there fails with a misleading "Missing dependency on jaspr in
  pubspec.yaml" (the root pubspec lacks `jaspr`). Always `cd` explicitly.
- **`tool/auth_client.js` `announceReady()` previously blanket-set
  `aria-label="Continue with Google"` and removed `disabled` on EVERY `.lp-social`
  element** — this leaked the Google label onto the disabled Apple button and
  re-enabled it. Scope all social DOM fixes to `.lp-social[data-provider="google"]`
  and tag each social control with `data-provider` (google/apple) in the Dart.
  Jaspr's SSR/client renderer is NOT the culprit for attribute aliasing.
- A stale `build_runner` daemon with different options blocks `jaspr build`
  ("Incompatible options with current running build daemon"). Kill the
  `build_runner daemon` dart.exe process (find via `Get-CimInstance Win32_Process`)
  and `rm -f .dart_tool/build/asset_graph.json`, then rebuild.

## Service architecture (verified 2026-11-05)

- Intended backend is `FYP/backend` — FastAPI/uvicorn **port 8000**
  (`sitewise.main:app`, `/health`, `/api/v1/*`). `FYP/test` (Express 3001) is
  legacy research/import tooling, NEVER the application API. The browser error
  `localhost:8000/api/v1/auth/me ERR_CONNECTION_REFUSED` meant the correct
  backend was simply never started; port 8000 is correct, do NOT switch to 3001.
- Jaspr SSR on 8090 proxies same-origin `/api/*` + `/health` to the backend
  via `lib/data/api_proxy.dart` (`ServerApp.addMiddleware` in main.server.dart).
  Config: `lib/data/api_config.dart` — `SITEWISE_API_BASE` (default
  http://127.0.0.1:8000) + `SITEWISE_PUBLIC_API_BASE` (empty = same-origin).
  `<meta name="sitewise-api">` is EMPTY; `auth_client.js` has NO hardcoded
  localhost:8000 fallback; `/auth-config.json` must be root-relative.
- `web/auth-config.json` is generated from `FYP/backend/.env` (public URL +
  publishable key ONLY) via `npm run gen-auth-config`; `auth_bundle.js` via
  `npm run build-auth`. Both git-ignored, auto-regenerated by `.\serve`.
- **NEVER create `fyp_jaspr_web/serve.ps1`**: PowerShell resolves bare
  `.\serve` to `.ps1` before `serve.cmd`, and this machine's `AllSigned`
  policy rejects unsigned scripts. Implementation is `serve.impl.ps1`;
  `.\serve` -> `serve.cmd` -> `powershell -ExecutionPolicy Bypass -File
  serve.impl.ps1`. Ports: 8090 SSR, 8000 API, 5567 Jaspr dev proxy,
  8181 Dart VM service (unrelated), 5432 Postgres.
- Live Supabase blockers (NOT integration faults): admin/create user fails
  `P0001` (public.users trigger rejects auth.users provisioning insert; repo
  migration §4/§5 has the SECURITY DEFINER fix, live DB differs), and public
  signup fails 500 "Error sending confirmation email" (SMTP unconfigured).
  Only 1 real auth user exists — never modify it for tests.

## Mobile auth screen (since 2026-11-09)

- `fyp_mobile_app/lib/presentation/mobile/auth/pages/mobile_auth_page.dart` is
  brand-only at the top: NO back arrow and NO top `Log In / Sign Up` switch
  (explicit user request). Mode still lives in `_tab` / `AuthTab` (enum defined
  in `widgets/auth_tabs.dart`, which also still exports the now-unused
  `AuthTabs` widget). Mode is selected by `/auth` route arguments
  (`'login' | 'signUp'`, see `core/routing/app_routes.dart`) and by the inline
  account link at the foot of the form. Do not reintroduce the top toggle
  without asking.
- `test/widget_test.dart` TEST 10 reaches registration via the inline
  `find.text('Sign up')` link (with `ensureVisible`), not `find.text('Sign Up')`.

## Flutter verification (2026-11-09)

- `flutter test` in `fyp_mobile_app` fails with "Unable to connect to
  flutter_tester process: WebSocketException: Invalid WebSocket upgrade
  request" when proxy env vars are set. Run with
  `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY
  -u all_proxy flutter test test/widget_test.dart` (23 tests pass, ~26s).
- `dart analyze` works without the proxy workaround; the only warning is a
  pre-existing unused import in `lib/core/routing/auth_route_guard.dart`.

## Jaspr web role-scoped themes (2026-11-09)

- `AppLayout` (fyp_jaspr_web/lib/layouts/app_layout.dart) tags the shell per
  role: `app-shell--admin` (navy/charcoal Blue Accent, a parallel session's
  work), `app-shell--agent` (light DESIGN.md palette), else shared dark
  `.app-shell`. NEVER retheme by editing the shared `:root`/`.app-shell`
  blocks — add a scoped `.app-shell.app-shell--<role>` token re-scope at the
  END of web/styles.css (precedent: admin block at ~11933, `.app-shell:has(.sw-reg)`).
- Agent tokens: #E8EEF6 canvas / #F4F7FB paper / #FFF surfaces / #E2E8F0+
  #CBD5E1 borders / #0B0F19 ink / #1E293B text / #64748B muted / #1D4ED8
  action / #3B82F6 accent; teal #0D9488 only for favourable status. Agent
  active nav pill = royal blue (override of the shared near-black chip);
  inputs need `color-scheme: light` (shared shell forces dark UA controls);
  `.btn--primary` flips automatically via `--contrast-surface: #0b0f19`.
- Agent scope decisions: Enquiries + Performance removed from nav and from
  dashboard (KPI replaced by "Draft or suspended"; performance/enquiries/task
  cards replaced by a real "Pending verification" panel). Routes stay
  registered; `demoEnquiries`/`demoTasks` stay in agent_records.dart (used by
  the still-routed pages / no business-logic deletion).
- Verify with `tool/probe_agent_theme.js` (BASE=http://127.0.0.1:8090, static
  server via `tool/dev_static_server.js`): 22 checks — client guard redirect,
  landing isolation, and computed styles of a fixture
  (`tool/agent_theme_fixture.html`) against the BUILT styles.css. Wait ≥600ms
  after injecting the 330KB stylesheet or computed colors race mid-parse.
- Concurrent sessions edit this repo live — re-read (git status + sed/grep)
  immediately before every Edit; a mid-task commit once changed app_layout.dart
  under me.

