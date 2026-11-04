# 05 — Backend API Reference (implemented state)

Base URL: `http://localhost:8000`. All authenticated calls:
`Authorization: Bearer <Supabase access token>`.

Auth errors: `401` (missing/invalid/expired token), `403` (forbidden or
suspended), `404` (hidden/absent), `503` (auth/analytics service unavailable),
`410` (disabled legacy endpoint). All errors: `{"detail": "..."}`.

## Auth

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/api/v1/auth/me` | Bearer | Verifies token, provisions local profile on first call. Returns identity + role + status + email_verified. |
| GET | `/api/v1/auth/session` | Bearer + active | Lightweight role/status probe for post-OAuth redirects. |

## Users

| Method | Path | Auth | Body / notes |
|---|---|---|---|
| GET | `/api/v1/users/me` | Bearer | Own profile. |
| GET | `/api/v1/users/me/status` | Bearer + active | `{role, account_status, email_verified}`. |
| PATCH | `/api/v1/users/me` | Bearer | `{full_name?, phone_number?, profile_picture_url?}` — attempts on `role`/`account_status`/`email_verified`/`email`/`user_id` → **403**. |
| GET | `/api/v1/users/` | admin | Paginated (`offset`, `limit≤200`). |
| GET | `/api/v1/users/{user_id}` | admin | Any profile. |
| PATCH | `/api/v1/users/{user_id}` | admin | Role/status changes; validated against domain vocabularies (422 on unknown values). |
| DELETE | `/api/v1/users/{user_id}` | admin | 422 on self-deletion. |
| POST | `/api/v1/users/` | — | **410 Gone** — identity creation is Supabase's. |

## Properties

| Method | Path | Auth |
|---|---|---|
| GET | `/api/v1/properties/` · `/{id}` | public |
| GET | `/api/v1/properties/mine` | property_owner/admin |
| POST | `/api/v1/properties/` | property_owner/admin — `user_id` stamped from token |
| PATCH / DELETE | `/api/v1/properties/{id}` | property_owner/admin — **ownership check**: another owner's listing → 403; ownerless legacy row → admin only; `user_id` in body ignored |

## Saved properties

| Method | Path | Auth |
|---|---|---|
| GET | `/api/v1/saved-properties/me` | active |
| GET | `/api/v1/saved-properties/user/{user_id}` | active — self only, else 403 (admin: any) |
| POST | `/api/v1/saved-properties/` | active — `user_id` forced to token identity; unknown property → 404 |
| DELETE | `/api/v1/saved-properties/{favorite_id}` | active — owner or admin, else 403 |

## Recommendations

| Method | Path | Auth |
|---|---|---|
| GET | `/api/v1/recommendations/` | admin (overview) |
| GET | `/api/v1/recommendations/me` · `/user/{user_id}` | active (self; admin any) |
| POST | `/api/v1/recommendations/` | active — `user_id` forced to token identity |
| DELETE | `/api/v1/recommendations/{result_id}` | active — owner or admin |

## Suitability / reports

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `/api/v1/suitability/` | active | `{property_id, preferences?}` → 404 unknown property; 200 with `{"available": false, "score": null, ...}` until a validated scoring path exists |
| GET | `/api/v1/reports/property/{id}` | active | Report depends on analysis modules; surfaces their unavailable state |

## Public reads (unauthenticated, by design)

`GET /api/v1/geospatial/*`, `GET /api/v1/virtual-tours/*` reads,
`GET /api/v1/statistics/*` (read-only DOSM analytics),
`GET /api/v1/health`, `GET /health`. Virtual-tour writes require
property_owner/admin.

## Example: authenticated request lifecycle

```
1. Frontend signs in with Supabase (Google or email/password) → access token
2. GET /api/v1/auth/me            Authorization: Bearer <token>
   → 200 {"user_id": "<uuid>", "role": "user", "account_status": "active", ...}
   (first call provisions the local profile)
3. PATCH /api/v1/users/me  {"full_name": "..."}  → 200 updated
4. GET  /api/v1/saved-properties/me               → own list
```
