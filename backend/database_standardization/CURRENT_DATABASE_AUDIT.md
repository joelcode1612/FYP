# SiteWise — Current Database Audit (Phase 1)

Generated: 2026-11-22 · Branch `joel` @ `34382b8` · Read-only audit, no credentials included.

Machine-readable outputs: `audit/local_inventory.json`, `audit/supabase_inventory_rest.json` (regenerate with
`backend/.venv/Scripts/python.exe database_standardization/scripts/audit_database_schema.py --target both`).

## 1. Environments

| | Local PostgreSQL | Supabase PostgreSQL |
|---|---|---|
| Database | `Final_Location_Analysis` (PG 18.4, ::1:5432) | Supabase-managed PG (project ref withheld) |
| Backend access | `DATABASE_URL` (direct SQLAlchemy, user `postgres`) | REST only: `SUPABASE_URL` + `SUPABASE_SECRET_KEY` (PostgREST + Storage). **No direct DSN is configured in the environment** — DDL must be applied via the Supabase SQL editor or a user-provided DSN |
| `ANALYTICS_DATABASE_URL` | Same local database (research schemas co-located) | — |
| Auth | Supabase JWT verification (`SUPABASE_JWKS_URL`) | `auth.users` (managed, untouched) |

## 2. Local PostgreSQL — relation census

395 relations, 11 classified operational + 3 operational-adjacent + 1 identity table; ~90 research tables in
`demand_gen`/`fyp_features`; ~289 research/unknown (dominated by `fnb_a` OSM/PSense analytics and `public.*`
geo staging tables).

### 2.1 Operational `fyp` schema (authoritative property + capture domain)

| Table | Rows (exact) | Role |
|---|---:|---|
| `fyp.rental_properties` | 920 | **Canonical property master** — 916 published catalogue rows + 4 drafts (§2.4). 53 columns incl. `geom` (PostGIS), `catalogue_*` provenance |
| `fyp.property_photos` | 5,711 | Photo records (URLs into Supabase Storage) |
| `fyp.property_features` | 0 | Feature vectors (empty; refreshed on demand) |
| `fyp.property_enrichment_category` | 916 | Per-category enrichment state (FK→master, cascade) |
| `fyp.property_feature_freshness` | 2 | Feature refresh bookkeeping |
| `fyp.property_listing_sources` | 916 | Catalogue source provenance (EP-/MD- workbooks) |
| `fyp.property_listing_verification` | 0 | Listing verification state |
| `fyp.capture_sessions` / `fyp.capture_frames` | 0 / 0 | 360° capture pipeline (canonical) |
| `fyp.panorama_jobs` / `fyp.panoramas` | 0 / 0 | Stitching jobs + canonical panoramas |
| `fyp.catalogue_properties` (view) | 955 | Documented research read surface (EP-/MD- rows) |
| `fyp.property_subject_links` | 955 | Catalogue↔subject join keys (research infrastructure) |
| `fyp.property_geospatial_features` | 1 | Local-only analytical field carrier (`geom` pipeline) |
| `fyp.v_property_analysis` (view) | — | Analytical view |
| **Legacy duplicates (0–1 rows)** | | `fyp.users` (1 pre-auth demo owner `owner@fyp.demo` with local bcrypt hash — obsolete), `fyp.favourite_properties`, `fyp.recommendation_results`, `fyp.ai_explanations`, `fyp.virtual_tours`, `fyp.activity_log`, `fyp.ml_models` — all empty; superseded by `public.*` equivalents |

### 2.2 Operational `public` schema (identity + business entities, SQLModel-managed)

| Table | Rows | Notes |
|---|---:|---|
| `public.users` | 128 | 123 entrepreneur, 2 agent, 2 owner, 1 admin. Columns identical to Supabase `users`. Canonical identity profile store |
| `public.user_tokens` | 0 | Token store |
| `public.assessment` | 2 | Entrepreneur assessments |
| `public.entrepreneur_preferences` | 1 | Preferences |
| `public.favorite_property` | 4 | Saved properties (note: singular spelling in code) |
| `public.recommendation_result` | 20 | Persisted recommendations |
| `public.ai_explanation` | 0 | SHAP explanations |
| `public.ml_explanation_cache` | 863 | Explanation cache (operational cache) |
| `public.virtual_tour` | 0 | Tour metadata |
| `public.property_verification` / `verification_document` / `verification_audit` | 0/0/0 | Verification workflow |
| `public.listing_change_request` / `listing_change_audit` | 0/0 | Listing-change workflow |
| `public.address` | 0 | Address cache (model-managed, unused so far) |
| `public.agent_listing_assignment` | 2 | Owner→agent assignment workflow |
| `public.provider_verification` | 1 | Provider verification (no SQLModel; raw SQL) |
| `public.property_enquiry` | 0 | (no SQLModel) |
| `public.property_photo` / `property_feature` / `property_geospatial_feature` | 0/0/0 | Legacy singular-spelling duplicates of the `fyp.*` tables |
| `public.district_demographic` | ~144 | Demographic reference (read by recommendation pipeline) |
| `public.alembic_version` | 1 | = `0013_panorama_review` |

**Intra-local duplication confirmed**: the same business entities exist BOTH in `fyp.*` (legacy, empty) and
`public.*` (live, SQLModel-managed), and photo/feature/geospatial entities exist BOTH in `fyp.*` (live) and
`public.*` (legacy, empty). Neither side has a complete contract — the split is by domain age, not by design.

### 2.3 `sitewise_sync` infrastructure

`backend/sql/20261122_assignment_sync_local.sql` defines a transactional outbox (`sitewise_sync.assignment_outbox`,
revision sequence, change-capture trigger) for the assignment mirror. **Status: staged, NOT yet applied** —
`sitewise_sync` has 0 relations locally and Supabase `agent_listing_assignment` has 0 rows. The worker
(`backend/src/sitewise/services/assignment_sync_worker.py`) is fully implemented with claim/retry/backoff and
mapping-blocked states (`mapping_required`, `property_missing`, …) keyed on `pano_listing_links`.

### 2.4 The four additional local drafts

| id | name | verification_status | is_published | owner |
|---:|---|---|---|---|
| 9234 | taman DESA JARUM | draft | false | none |
| 9235 | hehehe do | draft | false | none |
| 9236 | bjhhjj | draft | false | `f69be94e-fc0e-46ff-adc4-99567a5d916d` (real user) |
| 10120 | Corner shoplot, Section 13 | draft | false | none (created 2026-11-22) |

Published catalogue rows = 916 (matches Supabase exactly). Drafts 9234/9235/10120 have **no owner**; per the task
they are synchronized only if references validate, never published, never assigned an invented owner.

## 3. Supabase — relation census (REST-visible surface)

26 exposed tables + 4 RPCs. PostgREST does not expose constraints/RLS/grants; those are verified from the
project's Supabase SQL migrations (`backend/supabase/migrations/`) and must be re-confirmed in the SQL editor
when applying migrations.

### 3.1 Data mirrors of local entities (the inconsistency source)

| Table | Rows | Columns | Overlap with local |
|---|---:|---:|---|
| `public.property` | 916 | 30 | `fyp.rental_properties` under different names: `property_id`→`id`, `title`→`name`, `normalized_address`→`address`, `property_type_normalized`→`property_type`, `price`→`rental_price`, `built_up_area_sqft`→`built_up_sqft`, `bathroom_count`→`bathrooms`, `user_id`→`owner_user_id`. Supabase-only: `address_id`, `district_id`, `company_name`, `parking_spaces`, `bedrooms`, `year_built`, `status`, `local_source_data` (JSON provenance) |
| `public.addresses` | 916 | 18 | Normalized address records (`source_property_id` → `property`); local counterpart is inline columns + `public.address` (0 rows) |
| `public.property_photo` | 5,711 | 7 | Mirrors `fyp.property_photos` (`local_source_photo_id` provenance column) |
| `public.verification_audit` | 916 | 11 | Catalogue import audit rows; local `public.verification_audit` = 0 |
| `public.property_features` / `property_geospatial_features` / `property_source_mapping` / `property_verification` / `verification_document` / `listing_change_request` / `listing_change_audit` / `favorite_property` | 0 | — | Empty mirrors |
| `public.agent_listing_assignment` | 0 | 16 | Mirror target of the (staged) outbox worker |
| `public.pano_capture_sessions` / `pano_capture_frames` / `pano_jobs` | 0 | — | Legacy AR-source pipeline; read-only through `PublicPanoramaBridge` (PostgREST), never written by FYP |

### 3.2 Identity / security (stay in `public` per policy §5A)

`users` (114 rows — **14 fewer than local 128; divergence documented, reconciliation in Phase 5**), `agent` (2),
`company` (3), `staff_invitations` (2), `role_change_audit` (223), `user_tokens` (0). RPCs: `is_active_user`,
`is_admin`, `sitewise_is_active_admin`, `sitewise_is_active_staff` (MFA-gated staff checks).

**Local gap**: `public.agent` and `public.company` do not exist locally (agent identity lives only in
`public.users.role` locally; Supabase additionally has `agent`/`company` rows).

### 3.3 Managed (untouched)

`auth`, `storage`, `extensions`, `graphql`, `graphql_public` + system schemas. Auth triggers for user
provisioning are present per migrations and must be preserved verbatim.

## 4. Who reads what (backend verification)

- All SQLModel models declare `public` schema by default EXCEPT `fyp.rental_properties` (fyp_research.py,
  `externally_managed`) and `capture_360` tables (`fyp` schema). `fyp.property_photos` / `property_features` /
  `property_enrichment_category` are raw-SQL managed (no SQLModel).
- `public.property` is **not read or written by any backend code path** — every reference in
  `properties.py`, `virtual_tours.py`, `rbac.py`, `suitability_service.py`, `property_verification_service.py`,
  `generated_recommendation_store.py` is a historical comment documenting its retirement (migration
  `20261110_0002_drop_legacy_property` dropped the local copy; the Supabase mirror continued to exist and be
  populated externally).
- `public.pano_*` are read **only** through `PublicPanoramaBridge` (PostgREST, service key, signed URLs).
- The property mirror is populated by an out-of-repo process (no script in this repository writes
  `normalized_address`/`local_source_photo_id`). This undocumented pipeline is the root cause of the sync
  failures and is codified for the first time by this standardization effort.

## 5. Classification summary (all 395 local relations)

| Class | Count | Action |
|---|---:|---|
| Shared operational application | 11 | Canonical contract; synchronize to Supabase `fyp` schema |
| Identity/security | 1 (`public.users`) | Stay in `public` both sides |
| Operational-schema research/state | 3 + enrichment tables | Local-only; documented |
| Legacy duplicates | ~10 | Retire after dependency verification (0–1 rows) |
| Local-only research/analytics | ~100+ (`fnb_a`, `demand_gen`, `fyp_features`, `popfeat`, geo staging in `public`) | **Preserve unchanged, never synchronized** |
| Views | 5 | Recreate where operational |

## 6. Risks / findings requiring decisions

1. **User count divergence** (local 128 vs Supabase 114) — Phase 5 reconciliation lists the 14 missing UUIDs
   rather than guessing; only records with a Supabase `auth.users` origin are considered canonical for Supabase.
2. **No direct Supabase DSN** — `03_supabase_schema_migration.sql` is delivered as an idempotent script for the
   Supabase SQL editor; the verification tool falls back to REST parity checks until a DSN is provided.
3. **`verification_audit` on Supabase holds 916 catalogue-import rows** while the local operational
   `public.verification_audit` is empty — these are different lifecycles (catalogue provenance vs. listing
   verification); mapping treats them as distinct records under one canonical table, not as a merge.
4. **`fyp.users` demo row** (owner@fyp.demo, local bcrypt) — pre-auth artifact; retired, not migrated (it has no
   Supabase auth identity; creating one would fabricate an account).
5. **PostGIS on Supabase** — `fyp.rental_properties.geom` requires `postgis` + `postgis_topology` (usually
   pre-installed on Supabase; migration includes an existence check and skips `geom` only if unavailable,
   reporting it explicitly).
6. **Supabase-only columns** (`address_id`, `district_id`, `company_name`, `parking_spaces`, `bedrooms`,
   `year_built`, `status`, `local_source_data`) — preserved as provenance columns on the canonical table rather
   than discarded (§7 of the task). `addresses` (916 rows) becomes `fyp.addresses` with `source_property_id` FK.
