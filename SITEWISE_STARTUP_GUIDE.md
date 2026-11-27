# SiteWise — Startup Guide

**Audience:** the repository owner, working without an AI agent.

**Scope:** how to start SiteWise with one command, and how to change its
configuration safely. Everything here describes the implementation as it exists
in this repository at the time of writing; line numbers are given so you can
find each setting without guessing.

> The launcher itself is self-documenting. `Get-Help .\run-sitewise.ps1 -Full`
> prints the same prerequisites, configuration, database-safety and
> troubleshooting material from inside the script. This guide adds the
> configuration reference table and the reasoning behind the safety checks.

---

## 1. What the launcher is, and what it is not

There is **one** application server: a single FastAPI process serving
`sitewise.main:app`. It serves the Jaspr web client and the JSON API that the
Flutter mobile app calls. There is no second application server for mobile.

`run-sitewise.ps1` starts that one server with a chosen environment, proves the
target is the right one, deploys the frontend when asked, reports what it
actually started, and cleans up after itself.

It is **not** a build system, a migration tool, or a process supervisor:

- It never runs a database migration. `DB_AUTO_CREATE` stays `false`.
- It never creates, deletes or modifies business records.
- It never stops a process it did not start.
- It does not enable governed features. The LLM provider and the CQ respondent
  runtime are properties of the environment profile, and the receipt reports
  their state rather than changing it.

---

## 2. Prerequisites

| Requirement | Why | If missing |
|---|---|---|
| `backend/.venv` with the project installed | the server runs from it | launcher stops and prints the exact `venv` + `pip install -e backend` commands |
| PostgreSQL 18 cluster on port 5544 | the default profile targets it | preflight refuses; nothing is started |
| `fyp_jaspr_web/build/jaspr` populated, **or** `-Rebuild` | the server serves a static bundle | preflight reports the frontend as missing |
| Node/npm (only for `-Rebuild`) | generates auth + map assets | rebuild warns and continues where it can |
| Dart SDK via FVM, or `dart` on `PATH` (only for `-Rebuild`) | compiles the Jaspr client | rebuild stops with a clear message |
| `adb` + a USB device (only for `-Mobile` / `-RunMobile`) | port forwarding to the phone | launcher stops and names the expected `adb.exe` path |

The backend virtual environment matters more than it looks: `backend/.venv`
contains `psycopg2`, not `psycopg`. Every DSN in the profiles uses the
`postgresql+psycopg2://` scheme. Installing `psycopg` instead will not work.

---

## 3. The one command

```powershell
.\run-sitewise.ps1
```

That is the whole thing. It starts the current implementation (PostgreSQL 18,
port 5544) on `http://127.0.0.1:8093`, verifies the target, and prints a
receipt. Press `Ctrl+C` to stop.

If PowerShell refuses to run the script because of execution policy:

```powershell
powershell -ExecutionPolicy Bypass -File .\run-sitewise.ps1
```

`run-sitewise.cmd` remains available and forwards its arguments to the script,
so `run-sitewise.cmd -Port 8095` behaves identically.

---

## 4. Common tasks

| I want to… | Command |
|---|---|
| start normally | `.\run-sitewise.ps1` |
| start on another port | `.\run-sitewise.ps1 -Port 8095` |
| rebuild the web client, then start | `.\run-sitewise.ps1 -Rebuild` |
| rebuild for mobile work | `.\run-sitewise.ps1 -Rebuild -Mobile` |
| let a USB phone reach the API | `.\run-sitewise.ps1 -Mobile` |
| build and launch the Flutter app too | `.\run-sitewise.ps1 -RunMobile` |
| pick a specific phone | `.\run-sitewise.ps1 -RunMobile -DeviceId R58M12ABCDE` |
| serve on the LAN | `.\run-sitewise.ps1 -AllowLan` |
| open the browser when ready | `.\run-sitewise.ps1 -OpenBrowser` |
| check the frontend checksum only | `.\run-sitewise.ps1 -VerifyFrontend` |
| see the embedded help | `Get-Help .\run-sitewise.ps1 -Full` |

`-Mobile` and `-RunMobile` are different things on purpose:

- **`-Mobile`** only makes the phone able to *reach* the running server
  (`adb reverse tcp:<port> tcp:<port>`) and rewrites the mobile configuration
  asset so the app and the server agree on the port. Nothing is compiled or
  launched.
- **`-RunMobile`** implies `-Mobile`, then builds and launches the Flutter app
  with `flutter run -d <device>`.

---

## 5. How startup works, step by step

The script is ten numbered sections. Reading them in order is the fastest way
to understand a failure.

| Section | Line | What it does |
|---|---|---|
| 1 — EDIT HERE | 229 | the only values an owner normally changes |
| 2 — Shell setup | 331 | resolves paths, sets error handling |
| 3 — Resolve configuration | 409 | one authoritative value each; parameters override defaults |
| 4 — Validate inputs | 432 | unknown profile, missing venv, port already in use |
| 5 — Preflight | 483 | proves database identity, schema, routes, dependencies |
| 6 — Rebuild + deploy | 538 | optional; compiles, copies `map-config.js`, deploys, verifies |
| 7 — Mobile connectivity | 657 | `adb reverse` and the mobile config asset |
| 8 — Start the server | 779 | starts uvicorn, waits for liveness |
| 9 — Receipt | 925 | prints what is actually running |
| 10 — Launch Flutter / wait | 975 | optional `flutter run`, otherwise wait |

Two details worth knowing because they cause most confusion:

**Preflight runs before a socket is bound.** If the database is wrong, the
launcher refuses *before* starting a server. That is deliberate: a server
started against a database without the required tables answers HTTP 500 on
every research route, which is much harder to diagnose than a refusal.

**Liveness and readiness are separate.** `/health` answers "the process is up".
`/api/v1/health` answers "the process can do its job" — it checks the database
and both workers. The launcher waits on liveness, then reports readiness. A
running server with a broken database is reported as `DEGRADED`, never as
`PASS`.

---

## 6. Configuration reference

`run-sitewise.ps1` is at the repository root. The profile file for the default
profile is `backend/var/e2e/pg18/app_pg18.env`.

| Setting | File | Variable or parameter | Default | How to change | Safety checks |
|---|---|---|---|---|---|
| Runtime profile | `run-sitewise.ps1` | `$DefaultProfile` (L242) / `-Profile` (L213) | `pg18` | edit L242, or pass `-Profile` | unknown profile refused (L437); `dev` refused unless `-AllowLegacyDatabase` |
| Application port | `run-sitewise.ps1` | `$DefaultPort` (L249) / `-Port` (L214) | `8093` | edit L249, or pass `-Port` | port-in-use check (L454); does **not** change the PostgreSQL port |
| Bind host | `run-sitewise.ps1` | `$DefaultBindHost` (L293) / `-BindHost` (L215) / `-AllowLan` (L219) | `127.0.0.1` | edit L293, or pass either parameter | a LAN bind is a deliberate, visible choice |
| Startup timeout | `run-sitewise.ps1` | `$DefaultStartupTimeoutSeconds` (L298) / `-StartupTimeoutSeconds` (L225) | `90` s | edit L298, or pass the parameter | a server that exits during startup is reported with its exit code (L813) |
| Jaspr project directory | `run-sitewise.ps1` | `$WebDir` (L305) | `fyp_jaspr_web` | edit L305 | missing `pubspec.yaml` refused (L585) |
| Build output subdirectory | `run-sitewise.ps1` | `$BuildSubDir` (L306) | `build\jaspr` | edit L306 | build must produce `index.html` (L628) |
| Frontend deploy directory | `app_pg18.env` | `SITEWISE_FRONTEND_DIST` (L138) | `backend\var\e2e\frontend` | edit L138 | deploy verifies the deployed copy against the build; a referenced-but-absent asset fails the deploy |
| Mobile connectivity mode | `run-sitewise.ps1` | `$MobileHostMode` (L314) | `adb-reverse` | edit L314 | `lan` requires `-AllowLan`; `adb` required for `-Mobile` |
| Android device | `run-sitewise.ps1` | `$DefaultDeviceId` (L319) / `-DeviceId` (L218) | empty | edit L319, or pass `-DeviceId` | several devices attached without a choice is refused |
| Application database | `app_pg18.env` | `DATABASE_URL` (L110) | `project1_pg18_migrated_tests` @ 5544 | edit L110 | protected name, superuser/BYPASSRLS login, wrong PostgreSQL major → refused |
| Analytics database | `app_pg18.env` | `ANALYTICS_DATABASE_URL` (L111) | same database | edit L111 with L110 | must point at the same target as `DATABASE_URL` |
| M2 (read-only) database | `app_pg18.env` | `M2_DATABASE_URL` (L112) | same database, `p1_m2_runtime` | edit L112 | must agree with the application database |
| AI execution database | `app_pg18.env` | `PROJECT1_RUNTIME_DATABASE_URL` (L113) | same database, `p1ai_engine` | edit L113 | least-privilege principal, not a superuser |
| AI audit database | `app_pg18.env` | `PROJECT1_AUDIT_DATABASE_URL` (L114) | same database, `p1ai_engine` | edit L114 | as above |
| EE-01 explanation store | `app_pg18.env` | `EXPLANATION_STORE_DATABASE_URL` (L120) | same database, `p1ai_engine` | **inert — see §8** | guarded by `ee01_explanation_enabled`, which is `False` |
| CQ respondent writes | `app_pg18.env` | `EE01_DATABASE_URL` (L121) | `p1_ee01_runtime` | edit L121 | must match `EE01_EXPECTED_DATABASE` |
| CQ publication | `app_pg18.env` | `CQ_PUBLICATION_DATABASE_URL` (L228) | `p1_cq_publisher` | edit L228 | must match `CQ_PUBLICATION_EXPECTED_DATABASE` (L229); no fallback |
| Declared M2 target | `app_pg18.env` | `M2_EXPECTED_DATABASE` (L124) | `project1_pg18_migrated_tests` | edit with L112 | mismatch → `M2_DATABASE_TARGET_UNVERIFIED` |
| Declared EE-01 target | `app_pg18.env` | `EE01_EXPECTED_DATABASE` (L125) | same | edit with L121 | mismatch → `EE01_DATABASE_TARGET_UNVERIFIED` |
| Declared publication target | `app_pg18.env` | `CQ_PUBLICATION_EXPECTED_DATABASE` (L229) | same | edit with L228 | mismatch → `CQ_PUBLICATION_TARGET_UNVERIFIED` |
| Declared AI proposal target | `app_pg18.env` | `PROJECT1_ISOLATED_DATABASE_NAME` (L128), `_PORT` (L129) | `project1_pg18_migrated_tests`, `5544` | edit with L113 | also constrained by a code allowlist (§8) |
| Schema auto-create | `app_pg18.env` | `DB_AUTO_CREATE` (L137) | `false` | leave `false` | the launcher never migrates |
| M2 routes | `app_pg18.env` | `M2_UPSTREAM_ENABLED` (L141) | `true` | edit L141 | receipt reports the registered route count |
| Workflow routes | `app_pg18.env` | `PROJECT1_WORKFLOW_ENABLED` (L153) | `true` | edit L153 | receipt reports the registered route count |
| LLM provider | `app_pg18.env` | `TOKENHARBOR_ENABLED` (L166) | `true` (armed) | edit L166; `false` disarms every live route | a call additionally needs a per-attempt authorization receipt; receipt reports `ARMED` |
| CQ respondent runtime | `app_pg18.env` | `CQ_RUNTIME_ENABLED` (**absent**) | unset = disabled | add only with owner authorisation | absence keeps the respondent route on its fielding hold |
| Supabase identity | `app_pg18.env` | `SUPABASE_URL` (L176), `SUPABASE_PUBLISHABLE_KEY` (L177), `SUPABASE_SECRET_KEY` (L178), `SUPABASE_JWKS_URL` (L179) | real project | edit together | must agree with the frontend's `auth-config.json`, or every authenticated call 401s |
| Log level | `app_pg18.env` | `LOG_LEVEL` (L183) | `info` | edit L183 | — |
| CORS origins | derived | `CORS_ORIGINS`, set by `apply_runtime_origin` (`serve_profile.py:200`) | from the resolved port | **do not set in the profile** | derived so it cannot drift from the port in use |
| Auth redirect | derived | `SUPABASE_STAFF_INVITE_REDIRECT_URL` (`serve_profile.py:204`) | from the resolved port | **do not set in the profile** | Supabase's own allowlist must be updated separately (§7) |
| Public origin override | `serve_profile.py` | `SITEWISE_PUBLIC_ORIGIN` (L180) | unset | set only behind a reverse proxy | overrides the port-derived origin |
| Extra CORS origins | `serve_profile.py` | `SITEWISE_CORS_EXTRA` (L192) | unset | comma-separated list | additive only |

### Profile registry

Profiles are declared in `backend/tools/serve_profile.py:111`. Each maps to an
env file, a default port, an expected PostgreSQL major version and whether it is
a legacy target.

| Profile | Env file | Port | PostgreSQL major | Legacy |
|---|---|---|---|---|
| `pg18` | `app_pg18.env` | 8093 | 18 | no |
| `pg18-demo` | `app_pg18_demo.env` | 8093 | 18 | no |
| `pg18-preview` | `app_pg18_preview.env` | 8093 | 18 | no |
| `pg18-prod-rt24` | `app_pg18_prod_rt24.env` | 8093 | 18 | no |
| `dev` | `backend/.env` | 8090 | not asserted | **yes — refused** |

---

## 7. Changing the application port

Change **one** value: `$DefaultPort` at `run-sitewise.ps1:237`, or pass
`-Port` for a single run.

Everything port-dependent is derived from it:

- the uvicorn bind (`--port`, L793)
- the browser URL and the liveness URL (L422–374)
- the frontend checksum URL
- `adb reverse` for mobile (L997)
- the mobile asset's `API_BASE_URL`
- `CORS_ORIGINS` (`serve_profile.py:200`)
- the staff invite redirect (`serve_profile.py:204`)

The PostgreSQL port is **not** affected. It lives inside each DSN and must not
follow the application port.

### One manual step Supabase cannot do for you

Supabase Auth only redirects to URLs on its own allowlist. If you change the
application port, the invite and password-reset flow will fail at the redirect
even though CORS is correct.

1. Open the Supabase dashboard for the project named by `SUPABASE_URL`.
2. Go to **Authentication → URL Configuration**.
3. Add `http://localhost:<newport>/auth/callback` (and
   `http://127.0.0.1:<newport>/auth/callback`) to **Redirect URLs**.
4. Keep the old entries if other environments still use them.

The launcher cannot verify this: it requires dashboard access. It is the one
part of a port change that must be done by hand.

### Port restrictions worth knowing

The CQ private-experiment client path (`cq_development_access.dart:43`)
excludes ports `3080`, `5432`, `8000` and `8090`. Mobile CQ work therefore
needs a port outside that set — which is why the default is 8093 and not 8090.

---

## 8. Changing the database

A database switch is never one edit. The full explanation is embedded at the top
of `app_pg18.env` (the block starting at L22, "HOW TO POINT THIS PROFILE AT A
DIFFERENT DATABASE"). The summary:

1. **The DSNs move together** — `DATABASE_URL` (L110), `M2_DATABASE_URL`
   (L112), `PROJECT1_RUNTIME_DATABASE_URL` (L113), `PROJECT1_AUDIT_DATABASE_URL`
   (L114), `EE01_DATABASE_URL` (L121), `CQ_PUBLICATION_DATABASE_URL` (L228).
   Each keeps its own least-privilege principal. Collapsing them onto one
   superuser removes the separation they exist to provide and makes every
   row-level security policy decorative.
2. **The declarations move with them** — `M2_EXPECTED_DATABASE` (L124),
   `EE01_EXPECTED_DATABASE` (L125), `CQ_PUBLICATION_EXPECTED_DATABASE` (L229),
   `PROJECT1_ISOLATED_DATABASE_NAME`/`_PORT` (L128–129). These are not optional:
   the code compares each DSN against its declaration and refuses on
   disagreement. Fix the DSN, never the declaration.
3. **Nothing else.** The application port, CORS and the auth redirects are
   independent of the database.

Confirm a switch read-only before starting anything:

```powershell
backend\.venv\Scripts\python.exe backend\tools\serve_profile.py --profile pg18 --check
```

It prints the database, principal, PostgreSQL major and port it actually
reached, and exits non-zero when the target is protected, is a superuser or
`BYPASSRLS` login, has the wrong major version, or when the M2 DSN disagrees
with the application DSN.

### Three keys that do not do what their names suggest

These are documented rather than changed, because making them effective would
alter behaviour that needs owner authorisation. They are recorded as **DD-181**.

| Key | Reality |
|---|---|
| `M2_DEFAULT_INSTRUMENT_CODE` (L152) | **Inert.** `Settings` declares no such field, and `assessment_link_service.default_instrument_code()` reads it via `getattr(settings, …, "")`, so it always resolves to `M2V1`. Setting `M2V2` does not change which instrument a new marketplace link is bound to. |
| `PROJECT1_PROPOSAL_DB_ALLOWLIST` (L134) | **Inert.** `proposal_target_policy.py` pins `APPROVED_TARGETS` in code and states the allowlist cannot be widened from the environment. A new proposal target needs a reviewed code change. |
| `EXPLANATION_STORE_*` (L120, L126–127) | **Guarded and ineffective.** The code reads them, but their `Settings` fields are absent, so enabling `ee01_explanation_enabled` would raise `AttributeError`. That gate is `False` today, so nothing fails. |

`SUPABASE_INVITE_REDIRECT_URL` in `backend/.env:14` is also inert — the
application reads `SUPABASE_STAFF_INVITE_REDIRECT_URL` only. Do not edit it
expecting an effect.

---

## 9. Mobile connectivity

```powershell
.\run-sitewise.ps1 -Mobile              # phone can reach the API; nothing is built
.\run-sitewise.ps1 -RunMobile           # also build and launch the Flutter app
```

With `adb-reverse` (the default), the phone reaches this PC at
`127.0.0.1:<port>` over USB. The launcher installs `adb reverse tcp:<port>
tcp:<port>` and **removes it on exit**, so a stale rule does not survive a run.

The launcher also rewrites `fyp_mobile_app/assets/config/sitewise_dev.json` so
`API_BASE_URL` names the port actually in use. That file is written without a
BOM on purpose: the mobile asset reader rejects a BOM-prefixed file.

`-RunMobile` prefers FVM (`fvm flutter run`) when available and falls back to
`flutter run`. The Dart SDK used for `-Rebuild` is resolved in the same order:
`fvm dart`, then `.fvm/flutter_sdk/.../dart.exe`, then `dart` on `PATH`.

---

## 10. Reading the receipt

Every successful start ends with a block like this. Each line states something
that was actually measured. This is the real output for the `pg18` profile on
2026-11-26:

```
Profile        : pg18
Application    : http://127.0.0.1:8095
Database       : project1_pg18_migrated_tests
Database port  : 5544
DB principal   : sitewise_e2e
Frontend       : ...\backend\var\e2e\frontend
Frontend SHA   : 0d0fca1c240b1070
API readiness  : DEGRADED
                 database=ok, panorama=unavailable, explanation=unavailable,
                 queue_missing[panorama_worker=fyp.panorama_jobs; explanation_worker=public.ml_explanation_cache]
M2 routes      : Available (auth enforced, HTTP 401)
Workflow routes: Available (29 routes)
LLM provider   : ARMED (a call still needs its own authorization receipt)
CQ respondent  : Disabled (respondent route holds)
Mobile         : Not requested
```

`DEGRADED` here is the **correct** answer, not a failure: the web app and every
API route work, but the two background workers have no queue table in this
database, so they cannot do any work. The receipt names the missing tables
rather than claiming health the deployment does not have.

How to read it:

- **`API readiness: PASS`** means `/api/v1/health` returned `status: ok` with
  the database reachable and both workers actually able to work. `DEGRADED`
  names the part that is unavailable on the line beneath it, including
  `queue_missing` when a worker's table is absent. `DEGRADED` is not a launcher
  failure — web and mobile keep working.
- **`M2 routes: Available (auth enforced, HTTP 401)`** means the route exists
  and rejects an unauthenticated request, which is the correct behaviour. A
  route that returned `200` would mean authentication is bypassed; the launcher
  reports that as a problem.
- **`Frontend SHA`** is the checksum of the bundle the server actually served,
  compared against both the build output and the deployed directory.
- **`LLM provider: ARMED`** is reported, not changed. It means the live routes
  are reachable; each call still needs its own authorization receipt.

The launcher never prints `PASS` for a check it did not run.

---

## 11. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `unknown profile 'x'` | typo, or a profile not in the registry | use one of the five names in §6 |
| `port 8093 is held … by <process>` | something already listening | stop it yourself, or `-Port 8095`. The launcher will not kill it |
| `REFUSED: the target did not pass verification` | database identity, schema or dependency problem | read the listed problems; the launcher prints them individually |
| server exits during startup | Python exception in the output above the error | read that traceback; the launcher reports the exit code, not a guess |
| `API readiness: DEGRADED` with `worker_error` | a worker could not start | the detail names the exception class; `ModuleNotFoundError` means a missing dependency |
| page loads but API calls 401 | `SUPABASE_URL` disagrees with the frontend's `auth-config.json` | make them name the same project |
| page loads but assets 404 | `index.html` references an asset the deploy does not contain (commonly `/map-config.js`) | run `-Rebuild`; the deploy step now fails loudly on this |
| invite / reset email links land on the wrong port | Supabase redirect allowlist | §7 |
| `Item has already been added. Key in dictionary: 'HTTPS_PROXY'` | an old launcher used `Start-Process`, which rebuilds the child environment case-sensitively | this launcher uses `ProcessStartInfo` instead; if you see it, you are running the old script |
| `jaspr build` fails with a bare "Compilation failed" | a loopback proxy interceptor, or a stale build daemon | the launcher clears the proxy variables for the build; if it persists, stop the Dart daemons and retry |

---

## 12. Shutdown and cleanup

Press `Ctrl+C`. The `finally` block:

- stops **only** the server process this launcher started (by PID)
- removes **only** the `adb reverse` rule it installed
- prints `Server stopped.`

It does not stop other servers, other Python processes, or build daemons you
started elsewhere.

---

## 13. Rollback and what was preserved

Nothing was deleted. The pre-change files are in
`backups/launcher_pre_unified_20261126/`:

| File | Purpose |
|---|---|
| `run-sitewise.ps1` | the previous launcher (port 8090, legacy database) |
| `run-sitewise.cmd` | the previous wrapper |
| `deploy_frontend_dist.py` | before the asset-resolution check was added |
| `main.py` | before `/api/v1/health` stopped returning 500 |
| `app_pg18.env` | before the configuration comments were added |

To roll back, copy the file you want to restore back over its current location.
`run-sitewise.cmd` was kept working throughout, and the profile files were only
annotated with comments — no key or value changed (verified by parsing both
versions and comparing all 48 keys).

The profile annotation backup is also at
`backend/var/e2e/pg18/app_pg18.env.bak.cp_launch_04`.

---

## Known limitations

This appendix is not one of the thirteen numbered sections; it is required
separately as the "remaining limitations" deliverable.

1. **Supabase redirect allowlist is manual.** The launcher cannot verify or
   change it (§7).
2. **DD-181: three inert configuration keys.** `M2_DEFAULT_INSTRUMENT_CODE`,
   `PROJECT1_PROPOSAL_DB_ALLOWLIST` and `EXPLANATION_STORE_*` do not have the
   effect their names imply (§8). Making them effective changes binding and
   explanation behaviour, so it needs owner authorisation.
3. **`-Rebuild` needs network access** for `npm` and the Dart package cache.
   Without it, use the existing `build/jaspr` output.
4. **Mobile verification requires a device.** `adb reverse` and the Flutter
   launch were verified statically and by tool availability, not on hardware in
   this session.
5. **Authenticated click-through is not automated.** Signing in as a real user
   is an owner action; the launcher verifies that authentication is *enforced*
   (HTTP 401), not that a specific account works.
6. **One server, one port.** Running two profiles simultaneously requires two
   ports and two frontend directories; the launcher does not coordinate that.
