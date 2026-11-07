# Sitewise web app — Jaspr client + Unified FastAPI server + Supabase Auth

The Jaspr app runs in **client mode** (`jaspr: mode: client`). `jaspr build`
compiles the router and every page into `build/jaspr/` (entry document
`web/index.html`, bundle `main.client.dart.js`), and the unified FastAPI
server (repo-root `run-sitewise.cmd`) serves those static assets together
with the REST API on port 8090. There is no SSR process.

## Services, ports and data flow

```text
Browser / Flutter mobile (http://localhost:8090)
  |  compiled frontend  +  same-origin /api/v1/* and /health
  v
Unified FastAPI server  (FYP/backend, uvicorn sitewise.main:app, port 8090)
  |  static hosting + SPA fallback  (src/sitewise/frontend.py)
  |  /api/v1/*, /health, /docs — verifies Supabase ES256 access tokens via JWKS
  |  app database: PostgreSQL `sitesense`
  |  analytics/catalogue database: PostgreSQL `Final_Location_Analysis`
  v
Existing Supabase project (Auth + public.users) — https://lzdpjwmcjbhtkzkqudyt.supabase.co
```

| Port | Service | Owner |
| --- | --- | --- |
| 8090 | Unified FastAPI: compiled frontend + `/api/v1/*` | `..\run-sitewise.cmd` |
| 5432 | PostgreSQL (`sitesense`, `Final_Location_Analysis`) | local Postgres |

`FYP/test` is **not** an application API or a configuration source. Its Express
server (port 3001) and `test/.env` are legacy research/import tooling only. The
two remaining references are test-time fixtures for browser probes
(`test/.data/*.json`) and the one-off workbook import scripts listed below.

Browser requests never contain a hardcoded host or port: `<meta
name="sitewise-api">` ships in `web/index.html` (empty = same-origin) and
`tool/auth_client.js` reads it, so the browser talks to the same FastAPI
origin. Set `SITEWISE_PUBLIC_API_BASE`… only via the meta tag if the API is
deliberately cross-origin.

> LEGACY (superseded): the retired SSR flow served documents from a Jaspr
> process on :8090 and proxied `/api/*` to FastAPI on :8000
> (`lib/main.server.dart`, `api_proxy.dart`, `auth_stub.dart`, `serve.cmd`).
> Those files are dormant but retained; `backend/src/sitewise/main.py` now
> hosts the frontend itself and no second server exists.

## Authentication configuration

Configuration lives in **`FYP/backend/.env`** (see `FYP/backend/.env.example`):

```dotenv
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
SUPABASE_JWKS_URL=https://your-project.supabase.co/auth/v1/.well-known/jwks.json
SUPABASE_SECRET_KEY=sb_secret_...        # SERVER ONLY - never in web assets
DATABASE_URL=postgresql+psycopg2://.../sitesense
ANALYTICS_DATABASE_URL=postgresql+psycopg2://.../Final_Location_Analysis
CORS_ORIGINS=http://localhost:8090,http://127.0.0.1:8090
```

`npm run gen-auth-config` reads that file and writes
`web/auth-config.json` with **only** `supabaseUrl` +
`supabasePublishableKey`. It refuses to emit a `sb_secret_` / service-role key.
`npm run build-auth` bundles `tool/auth_client.js` into
`web/auth_bundle.js`. Both outputs are git-ignored and are regenerated
automatically by `.\serve` when their sources change.

In Supabase Authentication:

1. Enable Google under Sign In / Providers and configure the Google OAuth client.
2. Google Cloud's authorized redirect URI is your Supabase project's
   `https://your-project.supabase.co/auth/v1/callback`.
3. Allow these Redirect URLs (both hostnames have separate browser storage):
   - `http://localhost:8090/auth/callback`
   - `http://127.0.0.1:8090/auth/callback`

Sign-in uses PKCE. `redirectTo` is `location.origin + '/auth/callback'`; the
callback page is server-rendered, loads the deferred auth bundle, waits for the
code exchange, then calls `window.sitewiseAuth.complete()`. That validates the
bearer token against `GET /api/v1/auth/me` before routing by server-assigned
role. `pending` and `suspended` accounts are refused. Staff accounts without a
verified TOTP factor go to `/staff/mfa`. Remember me selects localStorage vs
sessionStorage; the SSR session mirror is kept in `sitewise_session` /
`sitewise_token` cookies and refreshed on `SIGNED_IN` / `TOKEN_REFRESHED`.

## Start on your laptop

```powershell
cd C:\Users\Lenovo\AndroidStudioProjects\FYP\fyp_jaspr_web
.\serve
```

`.\serve` resolves to `serve.cmd`, which invokes `serve.impl.ps1` with a
process-scoped `-ExecutionPolicy Bypass` (PowerShell 5.1 compatible):

1. Frees the Jaspr ports 8090 / 5567 — **only** for Dart-owned processes.
2. Health-checks `http://127.0.0.1:8000/health`; starts
   `FYP/backend/start-api.ps1` in its own window only when unhealthy, and never
   starts a duplicate if the port is occupied.
3. Regenerates `web/auth-config.json` / `web/auth_bundle.js` if stale.
4. Sets `NO_PROXY` for localhost and starts Jaspr SSR on 8090.

> There is deliberately **no `serve.ps1`**: PowerShell resolves a bare
> `.\serve` to `serve.ps1` before it checks `serve.cmd`, and this machine's
> `AllSigned` policy rejects the unsigned script. The PowerShell implementation
> is named `serve.impl.ps1` so `.\serve` reaches the `.cmd` wrapper.

The root-level `start-sitewise.ps1` is a convenience wrapper around the same
script. To run the backend by itself:

```powershell
cd FYP\backend
.\start-api.ps1
```

Open `http://localhost:8090/login`. For a production build:

```powershell
npm run build-auth --prefix tool
jaspr build
cd ..\..\
.\run-sitewise.cmd
```

> The SSR flow above is DEPRECATED since the unified-server migration: Jaspr
> now compiles in client mode and `run-sitewise.cmd` starts ONE FastAPI server
> that serves both the compiled frontend (`build/jaspr`, including
> `web/index.html`) and the REST API on :8090 — no `app.exe`, no proxy, no
> second server. `serve.cmd` / `serve.impl.ps1` are retained only until the
> unified flow is fully validated.

## Property dataset

The workbook's `Filtered_Data` sheet contains **2,126 accepted records** stored
in `sitewise_app.properties` in `Final_Location_Analysis`. The intended backend
serves them read-only at `GET /api/v1/catalog/properties` (bearer token required,
`{data, meta:{total,limit,offset}}`), which is what
`lib/data/api_property_repository.dart` consumes. No analytics/scoring tables
are modified. A workbook quality PASS is not administrator verification, and the
source suitability index is not a trained prediction.

One-off import tooling still lives in `FYP/test/scripts/` (not a runtime
service): `prepare-property-workbook.py` and `import-properties.js`.

## Files to change

| Concern | Location |
| --- | --- |
| Browser auth + API requests | `tool/auth_client.js` → `web/auth_bundle.js` |
| Public Supabase config generation | `tool/gen_auth_config.js` (reads `../backend/.env`) |
| Browser document shell + API base | `web/index.html` (`sitewise-api` meta = same-origin) |
| Browser entrypoint (router + guard) | `lib/main.client.dart`, `lib/app.dart` |
| Client-side API client | `lib/data/auth_browser.dart`, `web_api_client.dart` |
| Protected routes and role redirects | `lib/app.dart` (router redirect) |
| Frontend hosting / SPA fallback | `../backend/src/sitewise/frontend.py`, wired in `../backend/src/sitewise/main.py` |
| Catalogue / source-index ranking | `lib/data/api_property_repository.dart` |
| Repository wiring | `lib/data/app_locator.dart` |
| Backend routes, token verification | `../backend/src/sitewise/api/v1/`, `dependencies.py` |
| Backend startup / env | `../backend/start-api.ps1`, `../backend/.env.example` |
| Launchers | `..\run-sitewise.cmd` (unified), legacy: `serve.cmd`, `serve.impl.ps1`, `../start-sitewise.ps1` |

## Verification

```powershell
# Backend (from FYP/backend)
.\.venv\Scripts\python.exe -m pytest -q
# Frontend (from FYP/fyp_jaspr_web)
dart analyze lib
jaspr build
node tool/probe_ssr_mpa.js
```

Browser probes use explicitly labelled fixtures; they do not create or modify
real user records. Complete one real sign-in yourself to verify live OAuth
consent, `/auth/callback`, session restoration on refresh and logout.
