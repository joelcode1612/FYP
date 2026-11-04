# 02 — Supabase Authentication Integration

## Verified configuration (2026-11-04, values never printed)

| Check | Result |
|---|---|
| `SUPABASE_URL` / publishable key / secret key / JWKS URL present in `backend/.env` | PASS |
| `GET /auth/v1/health` (publishable key) | 200 — GoTrue v2.197.0 |
| `GET /auth/v1/.well-known/jwks.json` | 1 key: `ES256`, EC, `use=sig`, `kid b4b6694b-…` |
| URL and JWKS belong to the same project | PASS (same host) |
| Secret key accepted by admin API (`GET /auth/v1/admin/users`) | 200 |
| Secret key rejected by the Express config loader if submitted as publishable | by design (`test/app-api.js` throws on `sb_secret_`) |

`SUPABASE_SECRET_KEY` is **not** used by token verification and is not needed
by this integration; it exists only for optional server-side admin operations.
It is stored only in the git-ignored `backend/.env`.

## Division of responsibility

| Flow | Owner |
|---|---|
| Registration (email/password, Google OAuth) | Frontend via Supabase SDK — **not duplicated in FastAPI** |
| Login / logout / token refresh / password recovery | Supabase Auth (frontend SDK) |
| Session storage | supabase-js (browser storage; no tokens in FastAPI) |
| Access-token verification | **FastAPI** — local JWKS verification per request |
| Profile provisioning / role / status | **FastAPI** against `sitesense.users` |

## JWT verification implementation (`core/security.py`)

`SupabaseJWTVerifier.verify(token)`:

1. Parse header — reject malformed tokens (401).
2. **Algorithm allow-list**: only `ES256` accepted (from the JWKS `alg`).
   `none`, `HS256` and any other algorithm are rejected before key lookup.
3. Resolve `kid` via `JWKSClient` — cached (600 s) and force-refreshed on an
   unknown `kid` (**rotation handling**); empty key sets fail closed (503).
4. `jwt.decode` with the resolved EC public key: signature, `iss`
   (`<url>/auth/v1`), `aud` (`authenticated`), `exp`/`nbf` (30 s leeway),
   required claims `sub`, `exp`, `iat`, `aud`, `iss`.
5. Return the claims; **fail closed** with 503 when the key service is
   unreachable (an unreachable verifier never becomes "no authentication").

A `SupabaseUserinfoVerifier` fallback (`GET /auth/v1/user`) is implemented for
projects still on legacy symmetric signing; this project does not need it.

## Session semantics (documented + tested)

* **Refresh-token revocation** (sign-out) takes effect immediately for new
  use of the session.
* An **already-issued access token remains valid until `exp`** — standard JWT
  behaviour. Short access-token lifetimes (Supabase default 3600 s) bound the
  exposure window. `onAuthStateChange` in the frontend reacts to
  `SIGNED_OUT` and clears local state; the API rejects the token the moment
  it expires. There is no server-side access-token denylist (by design; the
  `user_tokens` legacy table is not used for this).
