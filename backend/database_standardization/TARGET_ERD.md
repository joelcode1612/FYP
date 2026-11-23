# Target ERD (post-standardization)

One contract, two databases. `fyp` = all business entities (identical both
sides), `public` = identity/security, `sitewise_sync` = outbox, `public.pano_*`
= read-only legacy bridge.

```mermaid
erDiagram
    public_users ||--o{ fyp_rental_properties : "owner_user_id FK ON DELETE SET NULL"
    fyp_rental_properties ||--o{ fyp_property_photos : "FK ON DELETE CASCADE"
    fyp_rental_properties ||--o{ fyp_property_features : "FK ON DELETE CASCADE"
    fyp_rental_properties ||--o| fyp_addresses : "address_id FK (provenance)"
    fyp_rental_properties ||--o{ fyp_property_verification : "property_id (workflow)"
    fyp_property_verification ||--o{ fyp_verification_document : "verification_id"
    fyp_property_verification ||--o{ fyp_verification_audit : "verification_id / property_id"
    fyp_rental_properties ||--o{ fyp_listing_change_request : "listing_id"
    fyp_listing_change_request ||--o{ fyp_listing_change_audit : "change_request_id"
    fyp_rental_properties ||--o{ fyp_agent_listing_assignment : "listing_id (mirror + workflow)"
    fyp_rental_properties ||--o{ fyp_virtual_tour : "property_id"
    fyp_rental_properties ||--o{ fyp_property_enquiry : "property ref"
    fyp_rental_properties ||--o{ fyp_ml_explanation_cache : "property_id (cache)"

    public_users ||--o{ fyp_assessment : "user_id"
    public_users ||--o{ fyp_favorite_property : "user_id"
    public_users ||--o{ fyp_recommendation_result : "user_id"
    public_users ||--o{ fyp_entrepreneur_preferences : "user_id"

    fyp_assessment }o..o| fyp_rental_properties : "property_id varchar SOFT (numeric | MD-/EP- via property_subject_links)"
    fyp_favorite_property }o..o| fyp_rental_properties : "property_id text SOFT"
    fyp_recommendation_result }o..o| fyp_rental_properties : "property_id text SOFT"
    fyp_entrepreneur_preferences }o..o| fyp_rental_properties : "preferences (no ref)"

    fyp_recommendation_result ||--o{ fyp_ai_explanation : "result_id"
    fyp_district_demographic }o..o| fyp_rental_properties : "district reference (read)"

    sitewise_sync_assignment_outbox }o..|| fyp_agent_listing_assignment : "outbox (local writes)"
    assignment_sync_receipts }o..|| fyp_agent_listing_assignment : "receipts (Supabase side)"

    public_pano_listing_links }o--|| fyp_rental_properties : "listing_id -> id (admin-verified, after rename FK follows)"
    public_pano_jobs ||--o{ public_pano_capture_sessions : "LEGACY bridge (read-only)"
```

Notes:

- `fyp_rental_properties` = 60-column contract (local 53 + 7 provenance).
  On Supabase the same table results from rename-in-place of `public.property`
  — no second writable copy exists anywhere.
- `fyp.capture_sessions/frames`, `fyp.panorama_jobs/panoramas` remain
  local-operational (documented intentional difference) and join the canonical
  contract at cutover via alembic.
- Research schemas (`fnb_a`, `demand_gen`, `fyp_features`, `popfeat`, geo
  staging) remain local-only and appear nowhere in the operational ERD except
  `demand_gen.subjects` referenced by `fyp.property_subject_links`
  (research linkage, local-only).
- All entrepreneur-facing relationships stay **soft** on `property_id`
  (varchar/text) to support both numeric ids and MD-/EP- catalogue refs;
  user identity relationships are hard FKs to `public.users`.
