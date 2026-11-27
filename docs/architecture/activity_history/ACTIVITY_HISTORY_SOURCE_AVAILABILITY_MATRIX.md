# Activity History — Source Availability Matrix

**Stage A deliverable.** Read-only audit of every candidate history source.
**Date:** 2026-11-25
**Target:** `project1_pg18_migrated_tests` @ `127.0.0.1:5544` (PG18)
**Principals examined:** `p1_m2_runtime` (M2 engine), `p1_ee01_runtime` (CQ runtime), `postgres` (catalogue only)
**Nothing was modified.** Every statement ran under `SET default_transaction_read_only = on`
or inside a `begin_nested()` savepoint that was rolled back.

## Classification vocabulary

| Class | Meaning |
|---|---|
| `VERIFIED_AVAILABLE` | Table exists, holds rows for the owner, every row carries a historical timestamp, and ownership is verifiable in SQL. |
| `IMPLEMENTED_NOT_VERIFIED` | Structure exists and a projection is written, but no row proves it works end-to-end. |
| `IMPLICIT_EMPTY` | Table exists and is readable, but holds zero rows. Empty means "no such record", never "the module did not run". |
| `LATEST_STATE_ONLY` | The source keeps one mutable row per subject. Earlier attempts, retries and recoveries are **not** preserved. |
| `BLOCKED_AUTHORIZATION` | The runtime principal holds no privilege, or holds the privilege but no policy grants it a row. |
| `BLOCKED_SOURCE` | The table is absent, refused, or reachable only through a restricted ledger with no owner-scoped contract. |
| `NOT_IMPLEMENTED` | No table and no write path exist. |

## Matrix

| Module | Source | Rows | Historical timestamp | Ownership verifiable | Version / source ref | Entrepreneur-authorized | Class |
|---|---|---|---|---|---|---|---|
| M2 core | `m2_assessments` | 11 | `created_at` | `owner_user_id` | — | yes | `VERIFIED_AVAILABLE` |
| M2 core | `m2_answer_revisions` | 129 | `created_at` | via assessment join | — | yes | `VERIFIED_AVAILABLE` |
| M2 core | `m2_review_events` | 13 | `created_at` | via assessment join | — | yes | `VERIFIED_AVAILABLE` |
| M2 core | `m2_confirmation_snapshots` | 15 | `created_at` | `actor_user_id` | `snapshot_digest` | yes | `VERIFIED_AVAILABLE` (digest defect → DD-091) |
| M2 core | `m2_confirmed_uncertainties` | 1 | `created_at` | `actor_user_id` | `confirmation_id` | yes | `VERIFIED_AVAILABLE` |
| BDJ deterministic | `m2_bdj_evaluations` | 0 | — | — | — | — | `IMPLICIT_EMPTY` |
| BDJ deterministic | `m2_bdj_findings` | 0 | — | — | — | — | `IMPLICIT_EMPTY` |
| BDJ deterministic | `m2_clarification_events` | 0 | — | — | — | — | `IMPLICIT_EMPTY` |
| BDJ objectives | `m2_bdj_objective_proposals` | 10 | `created_at` | `owner_user_id` | `contract_version`, `prompt_version` | yes | `VERIFIED_AVAILABLE` |
| BDJ objectives | `m2_bdj_objective_decisions` | 6 | `decided_at` | `decided_by` | via proposal | yes | `VERIFIED_AVAILABLE` |
| BDJ objectives | `m2_bdj_objective_admissions` | 2 | `created_at` | `actor_user_id` | `policy_version` | yes | `VERIFIED_AVAILABLE` |
| BCB | `m2_business_contexts` | 14 | `created_at` | `owner_user_id` | `builder_version` | yes | `VERIFIED_AVAILABLE` |
| BCB | `m2_business_context_builds` | 15 | `created_at`, `updated_at` | `owner_user_id` | — | yes | **`LATEST_STATE_ONLY`** |
| QG / QJ | `m2_qg_candidates` | 7 | `created_at` | `owner_user_id` | `contract_version`, `adapter_version`, `measurement_version` | yes | `VERIFIED_AVAILABLE` |
| QG / QJ | `m2_qg_candidate_reviews` | 5 | `recorded_at` | `owner_user_id`, `reviewer_id` | — | yes | `VERIFIED_AVAILABLE` |
| QG / QJ | `m2_qg_authorizations` | 73 | `created_at` | `owner_user_id` | — | yes | `VERIFIED_AVAILABLE` (not projected — see below) |
| QG / QJ | `m2_qg_consent_grants` | 7 | `created_at` | `owner_user_id` | — | yes | `VERIFIED_AVAILABLE` (not projected — see below) |
| EE-01 | `m2_measurement_decisions` | 2 | `created_at` | via assessment join | — | yes | `VERIFIED_AVAILABLE` (M2-side only) |
| EE-01 | `m2_measurement_specs` | 1 | `created_at` | via assessment join | `spec_version` | yes | `VERIFIED_AVAILABLE` (M2-side only) |
| EE-01 | `m2_research_objective_sources` | 1 | `created_at` | via assessment join | — | yes | `VERIFIED_AVAILABLE` (M2-side only) |
| EE-01 runtime | `ee01_measurement_snapshots` | 0 | — | — | — | no grant | `BLOCKED_AUTHORIZATION` |
| EE-01 runtime | `ee01_source_units`, `ee01_category_cells` | 0 | — | — | — | no grant | `BLOCKED_AUTHORIZATION` |
| EE-01 runtime | `ee01_report_readbacks` | 0 | — | — | — | no grant | `BLOCKED_AUTHORIZATION` |
| CQ | `cq_campaigns` | 1 | `created_at` | `owner_user_id` | — | SELECT held by M2 but **no M2 policy grants a row**; read via the owner-scoped CQ interface (as `p1_ee01_runtime`) | `VERIFIED_AVAILABLE` |
| CQ | `cq_manifest_releases` | 1 | `created_at` | via campaign | `manifest_hash`, `policy_hash` | same interface | `VERIFIED_AVAILABLE` |
| CQ | `cq_question_assignments` | 13 | `created_at` | via campaign | `bank_version` | same interface (count only) | `VERIFIED_AVAILABLE` |
| CQ | `cq_participants`, `cq_sessions` | — | — | — | — | **never read** — respondent-scoped | `BLOCKED_AUTHORIZATION` (by design) |

> **Updated 2026-11-25.** The three CQ rows above were `BLOCKED_AUTHORIZATION` in
> the original audit, correctly: `p1_m2_runtime` holds `SELECT` but no policy
> grants it a row. They are now `VERIFIED_AVAILABLE` **without any privilege or
> RLS change** — the metadata is read as `p1_ee01_runtime` in a read-only
> transaction with the actor bound, so the existing `ee01_owner_read` policies
> scope it. The respondent tables stay unreachable and are never queried.
> See `ACTIVITY_HISTORY_CQ_INTEGRATION_20261125.md`.
| Cloud BDJ | `project1_ai.runs` | 8 | `created_at` | `actor_id` | model/provider columns | restricted ledger | `BLOCKED_SOURCE` |
| Cloud BDJ | `project1_ai.attempts`, `attempt_receipts` | 6 / 6 | `created_at` | `actor_id` | `receipt` | restricted ledger | `BLOCKED_SOURCE` |
| Cloud BDJ | `bdj_results`, `bdj_result_findings`, `bdj_result_validations` | 0 | — | — | — | — | `IMPLICIT_EMPTY` |
| Reports | report snapshot / `ReportAdmission` | — | — | — | — | — | `NOT_IMPLEMENTED` |
| Reports | `ee01_measurement_sources`, `ee01_category_records` | — | — | — | — | — | `NOT_IMPLEMENTED` (tables absent) |

## Findings that changed the implementation

**1. `m2_bdj_objective_proposals` does not store an objective id.** The table has
`problem_type`, `recommendation_status`, `validation_status`, `review_state`,
`contract_version`, `prompt_version`, `execution_mode`, `reason` — but **no
`objective_id`**, and **no** `policy_version` / `policy_disposition` /
`policy_classification` / `decision`. Objective identity is established only at
admission. An earlier draft selected those columns; the query failed with
`UndefinedColumn`, and the per-stream savepoint converted the failure into
`BLOCKED_SOURCE` — which in the UI reads as "this module has no history". The
projection now reports `objective_id = null` for a proposal and resolves it for
a decision from the admission (`uq_admission_once` makes that 1:1).

**2. `reason` is prose, not a code.** Sample values are full sentences ("The
declaration for the area under consideration is recorded as undecided, which
leaves the location basis of the concept open…"). It is therefore **not**
selected and never mapped to `reason_code`. The existing M2 `reason` field
("Persisted assessment creation; creating actor not separately recorded.") is
operator prose and stays where it is.

**3. `m2_qg_candidate_reviews` has a composite primary key.** `PRIMARY KEY
(candidate_id, reviewer_id)` with no surrogate key. Using `candidate_id` as the
event identity would silently merge two reviewers' decisions on one candidate
into a single event under the service's `(kind, event_id)` de-duplication. The
projected identity is a deterministic namespace UUIDv5 over the real composite
key; `source_id` keeps the stored candidate id.

**4. `m2_business_context_builds` is `LATEST_STATE_ONLY`.** `PRIMARY KEY
(confirmation_id)` — exactly one row per confirmation (15 rows, 15
confirmations) carrying mutable `status`, `last_code`, `attempt_count`,
`updated_at`. A retry overwrites the previous attempt. `attempt_count` is a
counter, not a history: **attempts must not be synthesised from it.** See
`BCB_APPEND_ONLY_ATTEMPT_HISTORY_PROPOSAL.md`.

**5. CQ is blocked by policy, not privilege.** `p1_m2_runtime` holds `SELECT` on
`cq_campaigns`, `cq_manifest_releases` and `cq_sessions`, but the only `SELECT`
policy on those tables is `ee01_owner_read`, keyed on campaign ownership or
participation. Under the M2 principal's actor binding no row is granted. This is
a policy boundary, so it cannot be worked around by a grant and must not be
worked around by a policy change without separate authorization.

**6. Two owner-scoped governance sources were readable and unprojected.** The
objective and QG tables carry a `TO PUBLIC` `owner_scope` policy reading
`project1.actor_id`, so `p1_m2_runtime` reads them today with no new grant. They
were simply never projected. These are the only sources added in Stage B.

**7. `m2_qg_authorizations` (73) and `m2_qg_consent_grants` (7) are available but
deliberately not projected.** Both describe *authorization to act*, which the
envelope already declares out of scope via
`authorization_decisions_included: false`. Projecting them would contradict that
declaration and invite the reader to treat a grant as an approval.

## What this matrix does not claim

* Row counts are point-in-time and drift as harnesses legitimately write to
  append-only tables. They are not invariants.
* "0 rows" is never evidence that a module did not run. `m2_bdj_evaluations`
  being empty is why the pre-existing
  `test_evaluation_version_is_not_reported_as_a_reason` cannot pass on this
  target — an environment gap, not a code regression.
* Availability is not correctness. A readable table can still hold a
  non-conforming value; DD-091 is exactly that case.
