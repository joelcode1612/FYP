# Activity History — Metadata Projection Implementation (Stage B)

**Date:** 2026-11-25
**Contract:** `m2-activity/1` + `workflow-history-metadata/2` (**unchanged**)
**Scope:** additive metadata projection over existing owner-scoped sources.
**No migration, no new table, no new write path, no privilege change.**

## Design constraint that shaped everything

The envelope version was **not** bumped. Three consumers accept a closed set:

* `shared_logic/lib/src/data/repositories/api_m2_repository.dart:1051-1055`
* `fyp_jaspr_web/lib/features/assessment/presentation/components/m2_activity_panel.dart:211-213`
* `backend/scripts/cp03f_history_http_verify.py:107` (asserts equality)

A new `history_extension` value would make the client throw
`FormatException('Workflow history sources could not be verified.')` and blank
the page. Every change below is therefore **additive within `/2`**: new event
kinds, new per-event keys, and one new envelope key. An older consumer ignores
all of them and keeps its previous shape.

## Event kinds added

| Kind | Source | Identity | Status reported verbatim |
|---|---|---|---|
| `OBJECTIVE_PROPOSED` | `m2_bdj_objective_proposals` | `proposal_id` | `review_state` |
| `OBJECTIVE_DECIDED` | `m2_bdj_objective_decisions` | `decision_id` | `decision` |
| `OBJECTIVE_ADMITTED` | `m2_bdj_objective_admissions` | `admission_id` | `decision` |
| `QG_CANDIDATE_RECORDED` | `m2_qg_candidates` | `candidate_id` | `candidate_state` |
| `QG_REVIEW_RECORDED` | `m2_qg_candidate_reviews` | `uuid5(candidate_id, reviewer_id)` | `decision` |

## Per-event keys added (uniform)

* `event_type` — mirrors `kind`, so a consumer can branch on type without an
  exhaustive switch.
* `source_version` — coalesces **only** version-shaped columns
  (`evaluator_version` → `rule_version` → `builder_version` → `source_version`).
  A version is never placed in a reason slot.
* `reason_code` — null unless the source stores a real code. The prose `reason`
  field is **not** promoted. On this target `admission.policy_disposition` is
  null for every row, so `reason_code` is null everywhere in practice — which is
  the honest result, not a gap to fill.

## Envelope key added

`source_states` — a map of module → `{state, detail}`:

```
M2                  VERIFIED_AVAILABLE
BDJ_DETERMINISTIC   VERIFIED_AVAILABLE
BDJ_OBJECTIVES      VERIFIED_AVAILABLE
QG_QJ               VERIFIED_AVAILABLE
BCB                 VERIFIED_AVAILABLE | BLOCKED_SOURCE
CQ                  BLOCKED_AUTHORIZATION
EE01                BLOCKED_AUTHORIZATION
REPORTS             BLOCKED_AUTHORIZATION
CLOUD_BDJ           BLOCKED_AUTHORIZATION
```

The panel renders these instead of asserting coverage of its own. A module the
service cannot read now says so; previously the UI printed a hardcoded
`NOT_VERIFIED` sentence that could drift from the truth in either direction.

## Failure isolation

Each governance stream runs inside its own `begin_nested()` savepoint. A missing
or refused table rolls back to the savepoint and sets that stream's
`source_states` entry to `BLOCKED_SOURCE`; the M2 stream and the other
governance streams still return. This is what made the `UndefinedColumn` defect
invisible in the first draft — the isolation is correct, but it means a column
error is indistinguishable from a missing table unless the state is read. The
matrix records both possibilities for that reason.

## Deliberate exclusions

| Not projected | Why |
|---|---|
| `candidate_json`, `rationale`, `problem`, `research_objective` | Model output / entrepreneur wording. A history projection is not a content store. |
| `prompt_sha256`, `request_sha256`, `output_sha256` | Execution provenance with no reader-facing meaning; belongs to the ledger, not the timeline. |
| `reason` | Prose. Would be misread as a code. |
| `m2_qg_authorizations`, `m2_qg_consent_grants` | Authorization to act, not activity. The envelope declares `authorization_decisions_included: false`. |
| CQ / EE-01 / report tables | No privilege and no owner-keyed policy (Stage D). |

## A candidate is never an approved item

`QG_CANDIDATE_RECORDED` reports `candidate_state` verbatim — on this target
`VALIDATED`, which is a structural/semantic validation, not an approval. The
presentation layer appends the sentence *"Not an approved questionnaire item."*
and a test asserts a candidate is never rendered with an approval verb. Nothing
in the pipeline upgrades `candidate_state`.

## Digest projection (defect fixed in passing)

`m2_confirmation_snapshots.snapshot_digest` holds
`synthetic-snapshot-digest-stage5` for one assessment. The client requires
64-hex, so it rejected the **entire** response and the History page failed for
that assessment. The reader now emits `snapshot_digest` only when the stored
value really is a SHA-256; otherwise it emits `null`, a
`snapshot_digest_state = STORED_VALUE_IS_NOT_A_SHA256`, and the raw value under
`snapshot_digest_stored`. Nothing is invented and nothing is hidden. The
underlying fixture should still be corrected at source (DD-091).

## Files

| File | Change |
|---|---|
| `backend/src/sitewise/repositories/m2_repository.py` | Five event builders; `_read_governance_history`; `_digest_projection`; `source_states` in `read_activity_supplement`. |
| `backend/src/sitewise/services/m2_service.py` | Threads `source_states`; adds `event_type`/`source_version`/`reason_code` uniformly. |
| `fyp_jaspr_web/lib/features/assessment/data/activity_event_presentation.dart` | Titles and summaries for five kinds; `_currentness`; `_objective`; `source_version` in `_versionOf`. |
| `fyp_jaspr_web/lib/features/assessment/presentation/components/m2_activity_panel.dart` | `sourceCoverage` now derived from `source_states`, with the legacy literals retained as a fallback. |
| `fyp_jaspr_web/test/activity_event_presentation_test.dart` | 7 new cases. |
| `backend/tests/m2_bcb/test_activity_governance_history.py` | New, 9 DB-gated cases. |

## Backward compatibility

* `contract_version`, `history_extension`, `scope`, `assessment_id`,
  `assessment_revision`, `truncated`, `bcb_statuses`,
  `bcb_statuses_truncated`, `bcb_history_available`,
  `authorization_decisions_included` — unchanged names, types and values.
* Every pre-existing event kind keeps its existing keys and its existing
  summaries; the new keys are additive and the historical-revision suffix only
  appears when `source_is_current == false`.
* An older service that omits `source_states` still renders: the panel falls
  back to its previous literal coverage lines.
