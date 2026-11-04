# 06 — Database Integration

## Three datastores, three responsibilities

| Store | Role | Engine |
|---|---|---|
| **Supabase** (project `lzdpjwmcjbhtkzkqudyt`) | Identity provider only: `auth.users`, sessions, tokens. Verified live: GoTrue healthy, ES256 JWKS published. | Not connected from FastAPI (HTTP Auth APIs only) |
| **Local PostgreSQL `sitesense`** | Application data: `users` (15 tables total incl. property, favorite_property, recommendation_result, …) | `db/session.py` — migrations/`create_all` allowed here only |
| **Local PostgreSQL `Final_Location_Analysis`** | Analytics: DOSM population/income tables, `vw_latest_district_statistics`, OSM/PostGIS layers | `db/analytics_session.py` — **read-only in practice**, never touched by `create_all` or migrations |

Verified live on 2026-11-04 (table lists in `08_BACKEND_TEST_RESULTS.md`).

## Identity mapping

```
Supabase auth.users.id (UUID, from verified JWT "sub")
        ==  sitesense.users.user_id  (PRIMARY KEY)
```

* Mapping is 1:1 by construction (PK), so duplicate local profiles for one
  identity are impossible; `get_or_create_from_supabase` additionally handles
  the insert race via PK/unique-constraint re-read.
* `sitesense.users` predates Supabase and has no password column — confirmed
  by an `information_schema` check in the test suite.
* Legacy identities in the analytics DB (`fyp.users`,
  `sitewise_app.profiles` — used by the Express API and the research stack)
  are **not** authoritative for FastAPI auth and are not imported.

## Non-destructive migration proposal (NOT executed — requires approval)

`alembic/versions/` is currently empty; the schema is `create_all`-managed.
Two minimal migrations are proposed for the next step:

1. `0001_initial` — baseline the existing 15-table schema (autogenerate, no
   changes), so future diffs are reviewable.
2. `0002_agent_verification` — only if agent verification is approved:

```sql
CREATE TABLE agent_verification (
    verification_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          uuid NOT NULL REFERENCES users(user_id),
    status           varchar(20) NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','approved','rejected')),
    submitted_at     timestamptz NOT NULL DEFAULT now(),
    decided_at       timestamptz,
    decided_by       uuid REFERENCES users(user_id),
    documents_url    text,
    notes            text,
    CONSTRAINT uq_agent_verification_user UNIQUE (user_id)
);
```

Until that table exists, agents hold the role but receive no listing-management
powers (RBAC matrix), and the API reports the gap honestly.

## Connection hygiene

* Credentials only via `backend/.env` (git-ignored) — `DATABASE_URL`,
  `ANALYTICS_DATABASE_URL`; `.env.example` contains placeholders only.
* Pools: `pool_pre_ping=True`; analytics engine is separate so an analytics
  outage cannot break profile CRUD, and vice versa.
* No cross-database foreign keys (PostgreSQL cannot enforce them across
  databases); identity linkage is by UUID value, not FK.
* Analytics access is SELECT-only in all repository code; no ORM metadata is
  registered against the analytics engine.
