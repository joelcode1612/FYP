# Activity History — Module Integration Report (Stage D)

**Date:** 2026-11-25
**Rule applied:** integrate only sources that are both *available* and
*authorized*. Everything else is shown as unavailable, with the reason.

## Integrated (available + authorized + owner-scoped)

| Module | Events | Distinctions preserved |
|---|---|---|
| M2 core | `ASSESSMENT_CREATED`, `ANSWER_SAVED`, `REVIEW_RECORDED`, `CONTEXT_CONFIRMED`, `UNCERTAINTY_CONFIRMED` | Answer outcome is the stored `answer_state`; a confirmation shows its digest, never a "confirmed successfully" claim. |
| BDJ deterministic | `BDJ_EVALUATED`, `CANDIDATE_FINDING_RECORDED`, `CLARIFICATION_RECORDED` | Evaluation, finding and decision are three separate events with three separate identities. A finding is not an admission. |
| BDJ objectives | `OBJECTIVE_PROPOSED`, `OBJECTIVE_DECIDED`, `OBJECTIVE_ADMITTED` | A proposal says an objective is only established once an admission is recorded. Decision and admission are distinct events. |
| QG / QJ | `QG_CANDIDATE_RECORDED`, `QG_REVIEW_RECORDED` | A candidate is recorded material under review. Its `candidate_state` is shown verbatim (`VALIDATED` on this target) and the UI states "Not an approved questionnaire item." A QG candidate is never displayed as approved. |
| BCB | `CONTEXT_PERSISTED`, `bcb_statuses` | The context record and the build snapshot are separate: `CONTEXT_PERSISTED` is history, `bcb_statuses` is current state and is labelled as such. |
| EE-01 (M2 side) | via measurement tables | Present in the matrix as `VERIFIED_AVAILABLE` but **not projected**: the M2-side measurement rows are the input to EE-01, not EE-01 output. Projecting them would imply measurement ran. |

## Not integrated, and why

| Module | State | Reason shown to the user |
|---|---|---|
| CQ (Customer Questionnaire) | `BLOCKED_AUTHORIZATION` | `p1_m2_runtime` holds `SELECT` on `cq_campaigns`/`cq_manifest_releases`/`cq_sessions`, but the only `SELECT` policy is `ee01_owner_read`, keyed on campaign ownership or participation. Under the M2 actor binding no row is granted. Assessment-level campaign metadata is therefore not exposed by this endpoint. |
| EE-01 runtime | `BLOCKED_AUTHORIZATION` | No `SELECT` on the EE-01 tables. |
| Reports | `BLOCKED_AUTHORIZATION` | No `SELECT` on the report readback tables. There is also no report-snapshot or `ReportAdmission` table to read (`NOT_IMPLEMENTED`). |
| Cloud BDJ | `BLOCKED_AUTHORIZATION` | `project1_ai` is a restricted execution ledger with no owner-scoped history contract for this endpoint. **The endpoint does not query it.** |

## CQ: what is deliberately absent

CP-CQ-100 constrains what a questionnaire surface may reveal. This endpoint
exposes **no** respondent identity, **no** answer, **no** session history and
**no** per-respondent activity. The only CQ fact that would ever be in scope is
assessment-level campaign/release metadata, and that is currently blocked by
policy. No synthetic lifecycle was executed and no fielding was activated as
part of this work.

## EE-01 and reports: what is deliberately not claimed

The directive requires that measurement created/withheld and report
generation/admission/invalidation/revision stay distinct **only when persisted
records exist**. On this target:

* `ee01_measurement_snapshots`, `ee01_report_readbacks`, `ee01_source_units`,
  `ee01_category_cells` — all 0 rows.
* `ee01_measurement_sources`, `ee01_category_records` — tables do not exist.

There are therefore no persisted records from which to derive those
distinctions, and the panel states the source is unavailable rather than
rendering an empty timeline that would read as "nothing happened".

## Status semantics kept separate

| Current state | Historical state | Rule |
|---|---|---|
| `bcb_statuses[*].status` | `CONTEXT_PERSISTED` events | Current state is a read-time revision check, not an invalidation event. `source_is_current` is `assessment_revision == envelope revision == confirmed_revision`. |
| `candidate_state` | `QG_REVIEW_RECORDED` | A review does not rewrite the candidate's stored state. |
| `review_state` on a proposal | `OBJECTIVE_ADMITTED` | A proposal in state `APPROVED` is not an admitted objective; admission is its own row. |
| `PERSISTED` | — | Never relabelled `COMPLETED`. |

## Filtering, pagination and ordering

The panel keeps its existing behaviour: newest first by
`(occurred_at, kind, event_id)`, bounded by `limit` (route maximum 50), with
`truncated` set when the merged set exceeds the bound. De-duplication is on
`(kind, event_id)`, which is exactly the client's own identity rule. Distinct
attempts and decisions are preserved because each source row has a distinct
identity — including the composite-key case for reviews.

## Optional-source failure handling

Each optional source is read inside its own savepoint. A failure marks that
source `BLOCKED_SOURCE` and the rest of the timeline still renders. A missing
source is never rendered as success, and an empty source is never rendered as
"the module did not run" — the copy distinguishes them.
