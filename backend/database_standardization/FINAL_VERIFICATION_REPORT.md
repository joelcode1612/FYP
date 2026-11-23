# SiteWise Database Standardization — Final Verification Report

**Date:** 2026-11-22 · **Branch:** `joel` · **Baseline commit:** `34382b8`

## 1. Verdict

**PARTIAL — local canonical migration fully verified; Supabase-side migration
blocked pending `03_supabase_schema_migration.sql` execution** (the
environment holds REST credentials only; no direct Postgres DSN exists for
Supabase, so DDL must be applied via the project's SQL editor — see
`MIGRATION_INSTRUCTIONS.md` §2).

| Check | Result |
|---|---|
| Local canonical schema migration (02 + alembic `0014_canonical_fyp_schema`) | **APPLIED & VERIFIED** |
| All 18 business tables moved `public` → `fyp`, zero remaining in `public` | **VERIFIED** (05 validation passes) |
| Legacy duplicate tables retired (11 local + no cascade drops) | **VERIFIED** |
| `fyp.rental_properties` contract = 60 columns (53 + 7 provenance) | **VERIFIED** |
| Sequences synchronized; `sitewise_sync` outbox installed & seeded (2 events) | **VERIFIED** |
| Property data parity: 916/916 IDs, **0 missing, 0 extra, 0 value mismatches** (name/type/address/price/status/coords per record) | **VERIFIED** |
| Photo parity: 5,711 rows both sides (ID-set deltas from stale out-of-repo mirror — reconciliation script reports them) | **VERIFIED WITH DOCUMENTED DELTAS** |
| Users: local 124 (119 entrepreneur / 2 agent / 2 owner / 1 admin) vs Supabase 114 — UUID diff reported, never auto-merged | **REPORTED** |
| Drafts 9234/9235/9236/10120 preserved (`draft`, unpublished; 9236 keeps its real owner; others ownerless — nothing invented) | **VERIFIED** |
| Supabase `fyp` schema migration (03) + drafts sync (apply mode) | **BLOCKED — needs SQL-editor run or DSN** |
| Supabase REST/PostgREST surface after migration | **BLOCKED** (re-run `verify_database_consistency.py` after 03) |

## 2. Backend tests (live-database integration)

Full suite (`pytest tests -q`, excluding two pre-existing-broken files):

| | Before (baseline `34382b8`) | After standardization |
|---|---:|---:|
| Passed | 675 | **712** (+37) |
| Failed | 98 | **76** (−22) |
| Errors | 20 | **20** (=) |

Every residual failure/error is the **pre-existing RBAC test drift** (user-authored
"Only a Property Owner / Only the assigned Agent" guards vs. older test
expectations — the "property-draft RBAC 403" class recorded in the previous
session's report). **Zero UndefinedTable / schema faults remain**; all schema
faults introduced by the move were found and fixed during verification.

Test files updated for the canonical schema (fixture SQL now `fyp.`-qualified):
`test_assessments_api`, `test_auth_api`, `test_preferences_api`,
`test_saved_properties_api`, `test_recommendation_persistence`,
`test_personalised_recommendations`, `test_pu47_experimental_and_v3`,
`test_layer2_reuse_and_gate`, `test_enrichment_api`,
`test_virtual_tours_authorization`, `test_assessment_explanation_read`,
`test_explanation_cache`, `test_staff_listing_delete`,
`test_property_verification_api`, `test_agent_listing_assignments`,
`test_provider_workspace_api`, `test_staff_admin_api`,
`test_staff_authorization`, `test_recommendation_search_media`,
`test_metadata_startup` (convention flip: identity explicitly
`public.users`), `test_owner_listing_drafts`, `test_location_analysis_api`.

## 3. Flutter / Jaspr

- `flutter analyze`: **No issues found** (mobile untouched by this task).
- `jaspr build`: **Success** (`build/jaspr` produced).

## 4. What changed (summary — full detail in CANONICAL_SCHEMA.md / TABLE_MAPPING.csv)

**Database (local, applied):**
- 17 `ALTER TABLE public.x SET SCHEMA fyp` moves (atomic, zero data movement)
  + `entrepreneur_preferences` legacy drop before move.
- 7 provenance columns added to `fyp.rental_properties` (`address_id`,
  `district_id`, `company_name`, `parking_spaces`, `bedrooms`, `year_built`,
  `status`); `local_source_photo_id` added to `fyp.property_photos`.
- Type normalizations: `verification_audit.created_at`→timestamptz,
  `+actor_user_id`; `listing_change_request.changes`→jsonb;
  `verification_document.storage_key`→text;
  `property_listing_verification.reviewer_user_id` bigint→uuid (0-row table)
  repointed to `public.users`.
- Retired (verified empty; demo user row archived to
  `rollback/fyp_users_demo_archive.sql`): `fyp.users`, `fyp.favourite_properties`,
  `fyp.recommendation_results`, `fyp.ai_explanations`, `fyp.virtual_tours`,
  `fyp.activity_log`, `fyp.ml_models`, legacy `fyp.entrepreneur_preferences`,
  `public.property_photo`, `public.property_feature`,
  `public.property_geospatial_feature`.
- `fyp.addresses` created (Supabase contract); `sitewise_sync` outbox +
  trigger installed on `fyp.agent_listing_assignment` and seeded.
- Leaked test artifacts from the suite runs purged (355 `@jwks-test.example`
  users + their child rows; the 100 `@example.com` accounts left untouched).

**Backend code:** SQLModel models declare `{"schema": "fyp"}` +
`externally_managed` for all moved entities; identity models explicitly
`public`; all FK strings schema-qualified (`public.users.user_id`,
`fyp.property_verification.verification_id`, …); legacy
`FypRecommendationResult` mirror class retired; raw SQL canonicalized in
`agent_only_flow`, `properties`, `property_verification`, `virtual_tours`,
`agent_assignment_repository`, `agent_inspection_policy`,
`property_management_service`, `provider_scope`, `provider_verification_service`,
`enquiry_service`, `explanation_cache`, `property_insights_service`,
`location_analysis_service`, `recommendation_management_service`,
`fyp_property_repository`, `supabase_admin`, `assignment_sync_worker`
(`Accept-Profile: fyp`); staged Supabase sync SQL re-pointed to `fyp`.

**Deliverables produced** under `backend/database_standardization/`:
`CURRENT_DATABASE_AUDIT.md`, `CANONICAL_SCHEMA.md`, `TABLE_MAPPING.csv`,
`COLUMN_MAPPING.csv`, `CURRENT_ERD.md`, `TARGET_ERD.md`,
`LOCAL_ONLY_ANALYSIS_TABLES.csv` (347 research relations classified),
`MIGRATION_INSTRUCTIONS.md`, `migrations/01…05` (guarded, idempotent),
`rollback/fyp_users_demo_archive.sql`, `scripts/audit_database_schema.py`,
`scripts/apply_migration.py`, `scripts/reconcile_application_data.py`,
`scripts/verify_database_consistency.py`, `scripts/_supabase_rest.py`,
`audit/` (local + Supabase inventories, reconciliation + consistency reports).

## 5. Source-of-truth & synchronization strategy (implemented)

- Local PostgreSQL = operational source of truth for business entities until a
  verified cutover; Supabase holds auth identities, `fyp`-schema mirrors
  (transactional outbox worker — claim/retry/backoff/mapping-guards, already
  implemented pre-standardization), and Storage objects.
- After migration 03 there is **exactly one writable copy** of every entity in
  each database; the legacy `public.property` mirror ceases to exist as a
  separate writable table (it becomes the canonical table itself).
- Sync failure handling demonstrated by the existing worker design
  (outbox with attempts/backoff; `assignment_sync_receipts` on the Supabase
  side; mapping-blocked states instead of silent data loss).

## 6. Honest gaps (not claimed as done)

1. **Supabase DDL not executed** — blocked on credentials; script + instructions
   delivered and idempotent. Re-run verification after applying.
2. **Draft sync apply-mode** — implemented, waits for 03; dry-run verified.
3. **Full ERD regenerate on Supabase post-03** — via
   `audit_database_schema.py --target supabase --supabase-dsn …`.
4. Residual RBAC test drift (user-authored) — reported, not "fixed" by
   silently changing role rules (that would alter permissions).
5. The out-of-repo property-mirror writer is replaced by the documented
   reconciliation script going forward; historical photo ID-set deltas are
   reported by `reconcile_application_data.py` rather than force-copied.
