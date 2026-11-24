# SiteWise remediation status

Branch `joel`. Scope is the approved SW-001 through SW-016 program. The working tree also contains Phase 2 work, archived-model removals, and changes made outside this remediation batch.

## Batch results

| Batch | Findings | Correction and verification | Deployment risk and remaining work |
|---|---|---|---|
| 1 | SW-001, SW-003, SW-005, SW-008, SW-015 | Draft and assignment share a transaction. A disposable PostgreSQL constraint failure rolled both back. A keyed retry and replay returned one draft and assignment. Evidence reads are scoped by dimension and current authorization, and the handler reads at most the configured limit plus one byte. Enrichment schema checks issue reads, and the prepared migration ran twice on a disposable PostgreSQL 18 fixture. Numeric and catchment decoding fixtures passed. The mobile manifest already declared the SDK integration test once. | Live schema approval is required before enabling clients to send draft request keys. The mobile wizard does not send a key yet. Shared private-file durability and live Admin queue rendering remain unverified. |
| 2 | SW-002, SW-009, SW-011 | Owner evidence and the dedicated Agent inspection endpoint submit their own review dimensions. Publication eligibility continues to require both approvals. Added a staff-MFA Owner association operation for an unowned assigned draft and a saved-address validation action. Moved shared enrichment submission guard and Flutter inspection transport out of the calling route and widget. | Admin Owner association has an API but no new Admin control. Legacy combined submission is still available for compatibility. Live Owner/Agent/Admin journeys, correction round trips and live address provider behavior were not run. |
| 3 | SW-004 | Added a backend-first capture mode with exact target paths and byte-level SHA-256 checks. The queue requires all 38 checksummed originals and reuses queued or completed jobs. Completed job responses include the panorama ID when the session panorama matches the job output. A disposable PostgreSQL fixture checked the manifest and queue transitions. | Flutter still uses the device-first flow. Supabase uploads, worker stitching, draft recovery, interactive preview, hardware and scene quality require an isolated capture setup. |
| 4 | SW-006, SW-007 | Retained the existing expanded64 coordinate collector, historical catalogue inference, SHAP and recommendation paths. Model file tests rechecked artifact order, parity, bridge resolution and SHAP reconstruction. | The latest validated live collector coverage is 35 of 64. The remaining 29 mandatory features prevent a valid new-property score, score persistence, model-aligned history and end-to-end ranking validation. |
| 5 | SW-010, SW-012, SW-013, SW-014, SW-016 | Hardened two Flutter assessment routes against malformed or missing arguments. Added inline retry for the web catalogue count. Corrected operator guidance to port 8090 and exposed database and worker thread status through API health. | Live OAuth, MFA and account changes, assessment-to-report navigation, and catalogue-versus-operational saved-property and compare behavior remain open. Worker thread status is not a measure of queue throughput. |
| 6 | Archive and submission | Verified all 11 hashes in the existing external archive manifest. The runtime expanded64 SHA-256 is unchanged. | No new deletion or archival was performed. Release build, historical-secret clearance and end-to-end acceptance remain open. |

## Resolution by finding

| Finding | Status |
|---|---|
| SW-001 | Atomic creation and keyed replay verified in disposable PostgreSQL. Mobile key emission is pending migration rollout. |
| SW-002 | Independent submissions implemented and fixture-tested. MFA Admin association has API support. Full live verification remains open. |
| SW-003 | Evidence access and bounded reads implemented. Private storage deployment and reassignment round trip remain open. |
| SW-004 | Backend capability and queue tests complete. Mobile cutover and hardware acceptance remain open. |
| SW-005 | Read-only runtime schema check and additive migration verified against disposable PostgreSQL. Live migration remains unapplied. |
| SW-006 | Prior collector retained at 35 eligible features. Live score and persistence remain open. |
| SW-007 | Expanded64 remains the recommendation scoring basis. Cross-screen model alignment and ranking parity remain open. |
| SW-008 | Exactly one Flutter SDK integration test declaration verified. Targeted analysis passed. Native probe execution requires Android hardware. |
| SW-009 | Shared guard and mobile transport consolidated. Full typed inspection response and end-to-end readiness verification remain open. |
| SW-010 | Domain authorization tests run. Production OAuth, session restoration and MFA acceptance remain open. |
| SW-011 | Saved-address verdict persistence and invalidation on address edits implemented. Live provider and photo recovery acceptance remain open. |
| SW-012 | Malformed and missing assessment arguments now open the assessment home. Report and draft-resume acceptance remain open. |
| SW-013 | Inline catalogue retry implemented. Live role and cache behavior remain open. |
| SW-014 | Open. Saved-properties and Compare still need a coordinated reference and display contract. |
| SW-015 | Numeric and exact cumulative-population decoding verified with Dart fixtures. Browser review acceptance remains open. |
| SW-016 | Port guidance and worker thread diagnostics updated. Queue-throughput and shutdown/restart acceptance remain open. |

## Module completion matrix

| Module | Implemented or verified here | Open |
|---|---|---|
| Authentication and roles | Backend role fixtures, existing MFA guards preserved | Live auth scenarios |
| Property management | Atomic draft, keyed replay, saved-address validation | Mobile key rollout, failed photo recovery |
| Ownership verification | Explicit submit, evidence access, bounded reads | Private storage durability and live decisions |
| Agent inspection | Independent submit, shared guard and API transport | End-to-end corrections |
| 360° panorama | Backend-first integrity and job wiring | Mobile cutover, preview, hardware quality |
| Geospatial enrichment | Read-only schema prerequisite | Full validated operational inputs |
| PU model | Expanded64 artifact and historical model regression | New-property score persistence and SHAP |
| Recommendations | Existing expanded64 flow retained | Cross-screen and stale-rank acceptance |
| Assessment | Route argument guard | Draft resume and report round trip |
| Dashboards | Catalogue retry | Role and account-switch acceptance |
| Saved and Compare | Existing behavior preserved | Identifier and rendering alignment |
| Admin workspace | Exact numeric and catchment decoding, Owner association API | UI association control and evidence review acceptance |
| Database/API | Disposable migration and transaction checks, worker diagnostics | Live rollout approval and acceptance |

## Changed source paths for this remediation

- `backend/alembic/versions/20261124_0001_enrichment_schema.py`
- `backend/src/sitewise/api/v1/agent_only_flow.py`, `capture_360.py`, `properties.py`, `property_verification.py`, `staff_listings.py`
- `backend/src/sitewise/main.py`
- `backend/src/sitewise/repositories/agent_assignment_repository.py`, `fyp_property_repository.py`
- `backend/src/sitewise/services/agent_inspection_policy.py`, `capture_session_service.py`, `enrichment_schema.py`, `explanation_worker.py`, `panorama_worker.py`, `property_enrichment_service.py`, `property_verification_service.py`
- `backend/tests/test_agent_inspection_entry.py`, `test_verification_foundation.py`, `test_rbac_domain.py`
- `fyp_mobile_app/lib/core/routing/app_routes.dart`
- `fyp_mobile_app/lib/features/property_management/data/provider_workspace_service.dart`
- `fyp_mobile_app/lib/features/property_management/presentation/pages/provider_owner_requests_mobile_page.dart`, `sitewise_add_property_mobile_page.dart`
- `fyp_mobile_app/lib/features/property_management/presentation/widgets/provider_agent_inspection_panel.dart`
- `fyp_jaspr_web/lib/core/routing/api_proxy.dart`
- `fyp_jaspr_web/lib/features/dashboard/presentation/pages/entrepreneur_dashboard_page.dart`
- `shared_logic/lib/src/data/repositories/api_owner_listing_repository.dart`
- `shared_logic/lib/src/domain/entities/property_verification.dart`
- `shared_logic/lib/src/domain/repositories/owner_listing_repository.dart`
- `shared_logic/test/property_verification_numeric_wire_test.dart`

## Remaining acceptance and release gates

- Apply the migration to the live database only after separate approval. Then deploy a stable draft request key from mobile and verify lost-response replay.
- Exercise Owner, Agent and Admin accounts on an isolated environment, including evidence access after reassignment, photo failures, verification corrections and publication gates.
- Connect the Flutter backend-first capture flow and verify original uploads, app restart, worker restart, interactive preview and exact panorama submission on Android. Keep device-first compatibility until accepted.
- Validate the blocked sources in `docs/expanded64-live-feature-mapping.csv`. Verify an actual new listing score, its persisted provenance and matching SHAP, then measure explanation retrieval latency and cross-screen ranking parity.
- Align Saved and Compare property identifiers before end-to-end Entrepreneur acceptance.
- The existing archive is in the sibling `FYP_MODEL_BACKUP` directory. Its manifest records repository-relative paths and SHA-256 values. To restore an authorized item, copy the corresponding file under `files/` back to that relative path and compare SHA-256 before use.
- Complete release builds and a tracked-files plus Git-history secrets audit. No submission-ready claim is made.

## Verification totals

- 61 isolated Python tests passed across remediation fixtures, model and domain authorization. After moving the shared readiness function, 45 affected verification and authorization tests passed again.
- 5 shared Dart verification decoding tests passed. Targeted Flutter and Jaspr analysis reported no issues.
- Disposable PostgreSQL checks passed for repeated migration application, SELECT-only schema readiness, actual rollback plus keyed replay, and a 38-frame job gate with queued and completed job replay.
- No Android device was attached. The disposable PostgreSQL server was stopped after testing. No live migration, production writes or archive removals were performed.
