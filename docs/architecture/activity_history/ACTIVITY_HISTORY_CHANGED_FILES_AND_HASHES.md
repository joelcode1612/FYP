# Activity History — Changed Files and Source Hashes

**Date:** 2026-11-25
**Base commit:** `0529a0b5` ("web completed on stage 3")

Hashes are SHA-256 of the file content **after** this work. Only files listed
here were changed by this work; the repository has other unrelated
modifications from concurrent sessions (`assessment_api.dart`,
`stage_four_five_api.dart`, `m2_workflow_panel.dart`, and others) which are
**not** part of this change.

## Modified

| File | SHA-256 | Change |
|---|---|---|
| `backend/src/sitewise/repositories/m2_repository.py` | `8b0ba805cca9fcc4c11381380bed9a22828f5925e92acf1b0f1588dbf067eb9d` | Five governance event builders; `_read_governance_history`; `_digest_projection`; `source_states`; reviews query joins `c.objective_id` |
| `backend/src/sitewise/services/m2_service.py` | `eaffb9a99849115269b85598223b647c6ade6f92c9c13b7f744723d1f3e847bb` | Threads `source_states`; adds `event_type`, `source_version`, `reason_code` uniformly |
| `fyp_jaspr_web/lib/features/assessment/data/activity_event_presentation.dart` | `b6916bb802cccfde9ba4c63d4b2c0c6bf9b6d5c418a46886e33cfc909194de62` | Titles/summaries for five kinds; `_currentness`; `_objective`; `source_version` fallback |
| `fyp_jaspr_web/lib/features/assessment/presentation/components/m2_activity_panel.dart` | `e92d2d0118a2a070a711d0bd9a652f58c8c9276f8ceab64cbdd726d11f547381` | `sourceCoverage` derived from `source_states`; legacy literals kept as fallback |
| `fyp_jaspr_web/test/activity_event_presentation_test.dart` | `225004ff163ab41ca5f72953a58b24ceded291dd8c1f962bcc818d9762bf0b56` | 7 new cases (9 → 16) |

## New

| File | SHA-256 | Purpose |
|---|---|---|
| `backend/tests/m2_bcb/test_activity_governance_history.py` | `77ece2fcd6cc6bf49db38e3aa590b50adba8428c536adfba3654851b095b4673` | 9 DB-gated tests. **Note: `backend/tests/` is gitignored (`.gitignore:131`), so this file is on disk but untracked.** |
| `backend/var/e2e/pg18/activity_history_20261125/probe_activity_projection.py` | `1410fff6c471297fedb0001693a8142bbba0a4fa17e80f800fd350ea63bc75f6` | Read-only service-path probe under `p1_m2_runtime` |
| `backend/var/e2e/pg18/activity_history_20261125/validate_http_activity.py` | `e1cd15c43dec278fe831eccadd3024808f7a4b8738ae4ee62828abf09416110b` | Live HTTP payload validator mirroring the Dart client rules |

## New documentation

| File |
|---|
| `docs/architecture/activity_history/ACTIVITY_HISTORY_SOURCE_AVAILABILITY_MATRIX.md` |
| `docs/architecture/activity_history/ACTIVITY_HISTORY_METADATA_PROJECTION_IMPLEMENTATION.md` |
| `docs/architecture/activity_history/BCB_APPEND_ONLY_ATTEMPT_HISTORY_PROPOSAL.md` |
| `docs/architecture/activity_history/ACTIVITY_HISTORY_MODULE_INTEGRATION_REPORT.md` |
| `docs/architecture/activity_history/ACTIVITY_HISTORY_SECURITY_PRIVACY_VERIFICATION.md` |
| `docs/architecture/activity_history/ACTIVITY_HISTORY_TEST_EVIDENCE.md` |
| `docs/architecture/activity_history/ACTIVITY_HISTORY_CHANGED_FILES_AND_HASHES.md` |
| `docs/architecture/activity_history/ACTIVITY_HISTORY_COMPLETION_AND_NEXT_PROPOSAL.md` |

## Generated evidence

| File | Content |
|---|---|
| `backend/var/e2e/pg18/activity_history_20261125/probe_activity_projection.json` | Full `activity()` bodies for three assessments, from the service path |
| `backend/var/e2e/pg18/activity_history_20261125/http_activity_verified.json` | Live HTTP payloads after restart, validated |
| `backend/var/e2e/pg18/activity_history_20261125/http_activity_stale.json` | The pre-restart payload, kept as proof the server was stale |

## Not changed (deliberately)

| File / object | Why |
|---|---|
| Any `migrations/**` | No schema change is authorized. |
| `m2_business_context_builds` and any BCB write path | Stage C is a proposal only. |
| `cq_*` privileges, policies, RLS flags | DD-086 remains open and unauthorized. |
| `m2_qg_authorizations`, `m2_qg_consent_grants` projection | Authorization, not activity. |
| `shared_logic/lib/src/data/repositories/api_m2_repository.dart` | The client already accepts `/2`; no change needed. |
| `backend/scripts/cp03f_history_http_verify.py` | Still asserts `/2`, which is still correct. |
