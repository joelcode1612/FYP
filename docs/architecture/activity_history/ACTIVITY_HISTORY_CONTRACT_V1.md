# ACTIVITY_HISTORY_CONTRACT_V1

**Status:** `CONTRACT_DEFINED` · **Verified against:** live `Dss` database and a real
uvicorn process on 2026-11-17 · **Owner approval:** not yet sought for V1.1+ sections.

This document freezes the wire contract that the Activity History page consumes.
It describes what the backend actually emits today, not what it was intended to
emit. Where a field is described as *absent*, it is absent because the source
table has no such column — not because it was overlooked.

---

## 1. Envelope

Endpoint: `GET /api/v1/m2/assessments/{assessment_id}/activity?limit=1..100`
(default 50). Owner-scoped: a non-owner receives `404`, identical to a missing
record, so the endpoint cannot be used to probe for existence.

| Field | Type | Meaning |
|---|---|---|
| `contract_version` | `"m2-activity/1"` | Envelope version. Changes only on a breaking change. |
| `assessment_id` | UUID | Echoes the path parameter. The client rejects a mismatch. |
| `assessment_revision` | int ≥ 0 | The assessment revision at read time. Every event revision is ≤ this. |
| `scope` | `"PERSISTED_M2_ACTIVITY"` | Declares that this is persisted receipts, not a live view. |
| `events` | array | Event records, newest first. |
| `truncated` | bool | True when more events exist than `limit`. |
| `history_extension` | `"workflow-history-metadata/2"` | Per-kind enrichment version. `…/1` is the legacy shape and is still accepted by the client. |
| `bcb_statuses` | array | **Latest build snapshots**, not an attempt history. See §5. |
| `bcb_statuses_truncated` | bool | True when the bounded window dropped older snapshots. |
| `bcb_history_available` | bool | False when the BCB store is absent or unreadable. |
| `authorization_decisions_included` | `false` | Constant. This source does not supply scientific, Owner or fielding authorization. |

`authorization_decisions_included` is a constant rather than an omission on
purpose: a client that renders "no decisions" can tell the difference between
*this source does not carry them* and *none were made*.

---

## 2. Event envelope

Every element of `events` carries these fields.

| Field | Type | Notes |
|---|---|---|
| `event_id` | UUID | Primary key of the source row. Unique per table, not globally — see §6. |
| `kind` | enum | See §3. |
| `assessment_revision` | int ≥ 0 | Revision the row was written against. |
| `occurred_at` | ISO 8601 with offset | `created_at` of the source row, normalised to UTC by the service. |
| `actor_id` | UUID \| null | Null means the source row stores no actor. |
| `module` | string | `M2`, `BDJ`, `Business Understanding`, `BCB`. |
| `source_is_current` | bool | `event.assessment_revision == assessment.revision`. **This is a revision equality test, not a statement that the answer is still in force.** See §7. |
| `status` | string \| null | The stored outcome, where one exists. Null is honest, not missing. |
| `source_id` | UUID \| null | The related record this event is about. |

### Per-kind fields (history-metadata/2)

| Kind | Additional fields |
|---|---|
| `ANSWER_SAVED` | `status` = `answer_state`; `item_key` (e.g. `M2V1-11`) |
| `BDJ_EVALUATED` | `evaluator_version` |
| `CANDIDATE_FINDING_RECORDED` | `status` = `review_state`; `rule_id`; `rule_version` |
| `REVIEW_RECORDED` | — (actor is present) |
| `CONTEXT_CONFIRMED` | `snapshot_digest` (64 hex) |
| `UNCERTAINTY_CONFIRMED` | `source_id` = confirmation id |
| `CLARIFICATION_RECORDED` | `status` = `decision`; `source_id` = finding id |
| `CONTEXT_PERSISTED` | `status` = lifecycle status; `builder_version`; `source_id` = confirmation id |
| `ASSESSMENT_CREATED` | `reason` (a sentence explaining what is not recorded) |

`reason` is reserved for human-readable explanation. It must never carry a
version or an identifier — that was the defect this contract version corrects
(see `ACTIVITY_HISTORY_DECISION_REGISTER.md` AH-D-04).

---

## 3. Event kinds and their sources

| Kind | Source table | Actor stored? | Outcome stored? |
|---|---|---|---|
| `ANSWER_SAVED` | `m2_answer_revisions` | **no** | `answer_state` |
| `BDJ_EVALUATED` | `m2_bdj_evaluations` | no | no (receipt only) |
| `REVIEW_RECORDED` | `m2_review_events` | yes | no |
| `CONTEXT_CONFIRMED` | `m2_confirmation_snapshots` | yes | digest only |
| `CLARIFICATION_RECORDED` | `m2_clarification_events` | yes | `decision` |
| `CANDIDATE_FINDING_RECORDED` | `m2_bdj_findings` | no | `review_state` |
| `UNCERTAINTY_CONFIRMED` | `m2_confirmed_uncertainties` | yes | no |
| `CONTEXT_PERSISTED` | `business_context_*` | no | `lifecycle_status` |
| `ASSESSMENT_CREATED` | `m2_assessments` | no | no |

An "outcome stored? = no" row renders `Recorded — outcome not supplied`. That
sentence is a statement about the source, and the contract requires it to stay
literal: no kind may be given a synthetic success status.

---

## 4. Status vocabulary

| Source column | Values observed in this database |
|---|---|
| `answer_state` | `ANSWERED`, `NOT_PROVIDED`, `SKIPPED_OPTIONAL`, `UNDECIDED` |
| `review_state` (findings) | `UNREVIEWED`, `ACKNOWLEDGED`, `DEFERRED`, `REJECTED` |
| `decision` (clarifications) | `KEEP_ORIGINAL`, `REVISE_ANSWER`, `DEFER`, `DISMISS` |
| BCB `builds.status` | `PENDING`, `PERSISTED`, `HELD`, `FAILED` |
| BCB `contexts.lifecycle_status` | `PERSISTED`, `HELD`, … |

The client validates `answer_state` only for presence, not against a closed set,
so a new state does not break the page. The BCB status set **is** closed in the
client: an unrecognised BCB status is a format failure, because BCB statuses
drive the "current snapshot" block where a wrong value would misstate authority.

---

## 5. `bcb_statuses` is not an event stream

`bcb_statuses[]` entries are the **latest mutable build rows**, one per
confirmation, not an append-only history:

| Field | Type |
|---|---|
| `confirmation_id` | UUID |
| `assessment_revision` | int |
| `status` | enum (§4) |
| `last_code` | string \| null |
| `context_id` | UUID \| null |
| `attempt_count` | int |
| `updated_at` | ISO 8601 |
| `source_is_current` | bool |

A recovered build overwrites the failed attempt. The UI must therefore present
these as *current state*, never as a sequence of attempts, and must not infer
that an absent failure never happened.

---

## 6. Identity

`event_id` is unique within its source table. Two different kinds can share a
UUID only by coincidence, so the composite identity used by the client is
`kind:event_id`. Any consumer that keys on `event_id` alone is wrong.

`ASSESSMENT_CREATED` uses the assessment id as its `event_id`, because the
assessment row is the event.

---

## 7. `source_is_current` is narrower than it reads

The flag compares the event's revision to the assessment's current revision.

* It **is** correct for: "this record was written against the revision that is
  current now".
* It is **not** a statement that an answer is still in force. An answer written
  at revision 3 and never superseded will report `source_is_current = false`
  once the assessment reaches revision 13.

This is a known limitation, recorded as `AH-D-07`. Resolving it requires
comparing against the latest answer per item, which changes what the flag means
and therefore needs an owner decision.

---

## 8. Immutability

Every M2 history table is append-only at the database level (a `BEFORE ROW`
trigger raises `55000` on update; delete is refused `42501`). The read path
performs no writes and always `rollback()`s.

Consequence for consumers: a historical event's meaning may not change. A
correction is a new event, never an edit.

---

## 9. Compatibility rules

1. **Additive fields do not bump `contract_version`.** A consumer must ignore
   unknown keys. The Dart client validates only fields it uses.
2. **A removed or retyped field bumps `contract_version`.** No such change has
   been made; `m2-activity/1` remains correct.
3. **Per-kind enrichment is versioned separately** by `history_extension`, so a
   reader can tell the legacy shape (`/1`, `status` always null for answers)
   from the enriched one (`/2`).
4. **A field that is present but wrongly typed is a format failure**, not a
   missing value. The client throws rather than coercing.
5. **No fallback records.** An empty or failed source renders its own message.

### Version history

| Version | Change | Evidence |
|---|---|---|
| `m2-activity/1` + `workflow-history-metadata/1` | Original shape. `status` populated only for clarifications; `reason` carried `evaluator_version`. | superseded |
| `m2-activity/1` + `workflow-history-metadata/2` | Per-kind projection. `answer_state`, `item_key`, `evaluator_version`, `rule_id`, `rule_version`, `snapshot_digest`, `builder_version` added; `reason` no longer overloaded. Envelope unchanged. | `backend/var/activity_history/activity_http.json` |

---

## 10. Deliberately excluded from V1

These exist in the product but are **not** in this contract, and no consumer may
infer them:

| Excluded | Why |
|---|---|
| Cloud BDJ execution, attempt, receipt, validation outcome | No owner-scoped durable read API; `project1_ai` is frozen against application principals (`MIG-AUTH-01`). |
| BCB attempt history | The store keeps latest state only. |
| QJ / QG processing and review history | No version-bound history API exists. |
| Scientific, Owner, fielding authorization | Not supplied by this source; declared by `authorization_decisions_included: false`. |
| Respondent/campaign history | Contains private answers; no authorized assessment-level binding. |
| Report admission, R01–R12 versions | Reporting is not implemented. |

Each of these is rendered in the UI as an explicit `NOT_VERIFIED` coverage line
rather than an empty section, so absence is legible.
