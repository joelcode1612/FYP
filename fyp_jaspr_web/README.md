# Sitewise web app — Jaspr SSR + FastAPI backend + Supabase Auth

The Jaspr app runs in **server rendering mode** (`jaspr: mode: server`, port
8090). Every route returns a complete HTML document; only interactive leaves are
hydrated in the browser. There is no SPA `#app` shell.

## Services, ports and data flow

```text
Browser (http://localhost:8090)
  |  HTML / CSS / JS / same-origin /api/* and /health
  v
Jaspr SSR frontend  (fyp_jaspr_web, port 8090)
  |  same-origin reverse proxy (lib/data/api_proxy.dart)
  |  + SSR-side HTTP client (lib/data/auth_stub.dart)
  v
Intended backend    (FYP/backend, FastAPI/uvicorn, port 8000)
  |  GET /health, /api/v1/auth/me, /api/v1/catalog/properties, ...
  |  verifies Supabase ES256 access tokens via JWKS
  |  app database: PostgreSQL `sitesense`
  |  analytics/catalogue database: PostgreSQL `Final_Location_Analysis`
  v
Existing Supabase project (Auth + public.users) — https://lzdpjwmcjbhtkzkqudyt.supabase.co
```

| Port | Service | Owner |
| --- | --- | --- |
| 8090 | Jaspr SSR frontend + `/api/*` proxy | `.\serve` |
| 8000 | FastAPI backend (`sitewise.main:app`) | `backend\start-api.ps1` |
| 5567 | Jaspr internal dev/build proxy | Jaspr CLI (framework-managed) |
| 8181 | Dart VM service (dev only) | Dart CLI — **not** the API |
| 5432 | PostgreSQL (`sitesense`, `Final_Location_Analysis`) | local Postgres |

`FYP/test` is **not** an application API or a configuration source. Its Express
server (port 3001) and `test/.env` are legacy research/import tooling only. The
two remaining references are test-time fixtures for browser probes
(`test/.data/*.json`) and the one-off workbook import scripts listed below.

Browser requests never contain a hardcoded host or port: `<meta
name="sitewise-api">` is emitted by `lib/main.server.dart` (empty = same-origin)
and `tool/auth_client.js` reads it. The SSR process forwards `/api/*` and
`/health` to `SITEWISE_API_BASE` (default `http://127.0.0.1:8000`), so no CORS
preflight is needed. Set `SITEWISE_PUBLIC_API_BASE` only if the API is
deliberately cross-origin.

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
cd build\jaspr && PORT=8090 .\app.exe
```

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
| SSR API base + same-origin proxy | `lib/data/api_config.dart`, `lib/data/api_proxy.dart`, `lib/main.server.dart` |
| SSR-side API client | `lib/data/auth_stub.dart` |
| Dart/browser bridge | `lib/data/auth_service.dart`, `auth_browser.dart` |
| Protected routes and role redirects | `lib/app.dart` |
| Catalogue / source-index ranking | `lib/data/api_property_repository.dart` |
| Repository wiring | `lib/data/app_locator.dart` |
| Backend routes, token verification | `../backend/src/sitewise/api/v1/`, `dependencies.py` |
| Backend startup / env | `../backend/start-api.ps1`, `../backend/.env.example` |
| Launchers | `serve.cmd` (`.\serve`), `serve.impl.ps1`, `../start-sitewise.ps1` |

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
