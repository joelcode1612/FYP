# SiteWise — Canonical Schema Contract (Phase 2)

Authoritative decision record for the unified database contract. The **local
`fyp.rental_properties` table is the starting contract** for the property entity
(task §7); every other canonical table adopts its live local contract with the
explicit normalizations below.

## 1. Schema policy

| Schema | Contents | Synced to Supabase |
|---|---|---|
| `fyp` | All shared application/business entities | **Yes — identical contract both sides** |
| `public` | Identity & security only: `users`, `user_tokens`, (Supabase-side: `agent`, `company`, `staff_invitations`, `role_change_audit`, auth-provisioning RPCs) | Identity reconciled by UUID; Supabase-side staff tables not replicated locally |
| `sitewise_sync` | Transactional outbox + revision sequence (assignment mirror) | Mirror infrastructure, local-side writes / Supabase-side receipts |
| `public.pano_*` | Legacy AR-source capture tables — **read-only adapter via `PublicPanoramaBridge`** | Kept as-is |
| `fnb_a`, `demand_gen`, `fyp_features`, `popfeat`, geo staging in `public` | Local-only research/analytics (see `LOCAL_ONLY_ANALYSIS_TABLES.csv`) | **Never synchronized** |
| `auth`, `storage`, `extensions`, … | Supabase-managed | Untouched |

## 2. Canonical `fyp` tables (both databases)

`fyp.rental_properties` (60 columns = local 53 + 7 Supabase provenance columns),
`fyp.property_photos` (7), `fyp.property_features`, `fyp.addresses` (18),
`fyp.assessment`, `fyp.favorite_property`, `fyp.entrepreneur_preferences`,
`fyp.recommendation_result`, `fyp.ai_explanation`, `fyp.ml_explanation_cache`,
`fyp.virtual_tour`, `fyp.property_verification`, `fyp.verification_document`,
`fyp.verification_audit` (11 incl. `actor_user_id`), `fyp.listing_change_request`,
`fyp.listing_change_audit`, `fyp.agent_listing_assignment` (16),
`fyp.provider_verification`, `fyp.property_enquiry`, `fyp.district_demographic`,
`fyp.nearby_competitor`, `fyp.property_foot_traffic`,
`fyp.property_source_mapping` (Supabase sync infra).

Local-operational only (documented intentional difference — created on Supabase
only at a future cutover by alembic): `fyp.capture_sessions`, `fyp.capture_frames`,
`fyp.panorama_jobs`, `fyp.panoramas`, `fyp.property_enrichment_category`,
`fyp.property_feature_freshness`, `fyp.property_listing_sources`,
`fyp.property_listing_verification`, `fyp.property_geospatial_features`,
`fyp.property_subject_links`, `fyp.catalogue_properties`, `fyp.v_property_analysis`.

## 3. `fyp.rental_properties` — canonical columns

Base = local live contract (53 columns, verbatim) plus:

| Added column | Type | Source | Notes |
|---|---|---|---|
| `address_id` | uuid NULL | Supabase `property.address_id` | FK → `fyp.addresses(address_uuid)` when populated |
| `district_id` | varchar NULL | Supabase | provenance |
| `company_name` | varchar NULL | Supabase | provenance |
| `parking_spaces` | integer NULL | Supabase | distinct from `has_parking` boolean — both kept |
| `bedrooms` | smallint NULL | Supabase | provenance |
| `year_built` | smallint NULL | Supabase | provenance |
| `status` | varchar NULL | Supabase | legacy mirror value; all 916 rows = `approved`; non-authoritative |

Renames applied on Supabase: `property_id→id`, `title→name`,
`normalized_address→address`, `property_type_normalized→property_type`,
`price→rental_price`, `built_up_area_sqft→built_up_sqft`,
`bathroom_count→bathrooms`, `user_id→owner_user_id` (+FK to
`public.users(user_id)`; all 916 values verified NULL — data-safe),
`local_source_data→catalogue_source_data` (JSONB provenance preserved whole).

Explicit non-merges (task §7): `size_sqft` ≠ `built_up_sqft` (kept independent);
`has_parking` (bool) ≠ `parking_spaces` (count); `geom` is a local-only
analytical field — created on Supabase only if PostGIS is available, otherwise
documented and excluded from the shared contract.

## 4. Type normalizations (lossless)

| Column | From | To | Where |
|---|---|---|---|
| `fyp.listing_change_request.changes` | json | jsonb | local (empty table) |
| `fyp.verification_document.storage_key` | varchar | text | local |
| `fyp.favorite_property.property_id` | int64 → text | text | Supabase (empty) |
| `fyp.verification_audit.actor_user_id` | — | uuid NULL | local addition |

## 5. Keys, constraints, indexes

- PKs and existing local constraints are preserved verbatim by `SET SCHEMA` /
  `RENAME` (OID-level operations, zero data movement).
- Soft-reference policy: `assessment.user_id`, `favorite_property.user_id`,
  `recommendation_result.user_id` are uuid; their `property_id` columns are
  varchar/text **by design** (they carry numeric ids or MD-/EP- catalogue
  references resolved through `fyp.property_subject_links`). No hard FK is
  added; integrity is enforced by the reconcile script (§5 checks) instead.
- `fyp.rental_properties.owner_user_id` FK → `public.users(user_id)`
  `ON DELETE SET NULL` (existing locally; added on Supabase).
- Sequences: `setval(max(id))` executed for every renamed/created table with an
  identity column (no future-insert collisions).

## 6. Supabase security model (Phase 8 SQL)

- `fyp` schema: **no grants** to `anon`/`authenticated` (locked by default);
  `GRANT USAGE ON SCHEMA fyp TO service_role` + table-level grants to
  `service_role` only. RLS enabled on all `fyp` tables (defense in depth; the
  service role bypasses RLS, clients cannot reach the schema at all).
- Direct Data API exposure of `fyp` is enabled **only** for the assignment
  mirror worker (`Accept-Profile: fyp`), matching the existing public-schema
  mirror pattern; everything else is FastAPI-mediated.
- `public.pano_listing_links`, `assignment_sync_receipts`: service_role-only
  (already revoked from clients).
- Identity tables keep their existing policies/auth triggers untouched; staff
  MFA RPCs preserved.

## 7. Source-of-truth policy (Phase 7)

`fyp.rental_properties` and all business entities: **local PostgreSQL is the
operational source of truth** until an explicit, verified cutover; Supabase
holds (a) auth identities, (b) `fyp`-schema mirrors written only by the
transactional-outbox worker + reconciliation runs, (c) Storage objects.
Supabase `public.property` (legacy mirror) is retired as a *writable* copy by
becoming the canonical `fyp.rental_properties` itself — after migration 03
there is exactly one writable copy of every entity in each database, and
exactly one cross-database authority per entity.

## 8. Retirement list (drop after verification — all verified 0 rows except noted)

Local: `fyp.users` (1 pre-auth demo row → archived to `rollback/` first),
`fyp.favourite_properties`, `fyp.recommendation_results`, `fyp.ai_explanations`,
`fyp.virtual_tours`, `fyp.activity_log`, `fyp.ml_models`,
`fyp.entrepreneur_preferences` (legacy shape, 0 rows),
`public.property_photo`, `public.property_feature`,
`public.property_geospatial_feature`.
Supabase: `public.property_geospatial_features` (empty mirror of local-only
research), legacy `public.property` name (renamed away, not dropped).
